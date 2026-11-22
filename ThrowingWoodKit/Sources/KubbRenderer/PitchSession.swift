import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch

public struct DialState: Decodable, Equatable, Sendable {
  public let phase: String
  public let arm, crank, back, deadDeg, overDeg: Double
  public let powerLo, powerHi, releaseLo, releaseHi, lastBack, lastStop: Double?
  public struct Crossing: Decodable, Equatable, Sendable {
    public let band, edge: String
  }
  public let crossings: [Crossing]?
  public let prompt: String?
}

/// A control gets samples in dial-local units and returns a session frame on demand.
/// Unit (0,0) is the centre. Lifting during a flick sends the engine a frame without an arm.
public protocol ThrowInput {
  mutating func sample(_ point: CGPoint?)
  mutating func frame(after dt: Double) -> String?
  mutating func reset()
  func feedback(crossings: [DialState.Crossing], released: Bool) -> [PitchFeedback]
}

extension ThrowInput {
  public func feedback(crossings: [DialState.Crossing], released: Bool) -> [PitchFeedback] {
    var events = crossings.map { _ in PitchFeedback(haptic: .band) }
    if released { events.append(PitchFeedback(haptic: .release)) }
    return events
  }
}

public struct PointerDial: ThrowInput {
  private struct Contact {
    var arm: Double, fresh = true, lifted = false
  }
  // Coalesce motion within one contact, preserve up/down boundaries across display ticks.
  private var contacts: [Contact] = []
  private var elapsed = 0.0
  public init() {}
  public mutating func sample(_ point: CGPoint?) {
    if let point {
      let arm = atan2(point.x, point.y) * 180 / .pi
      if contacts.last?.lifted == false {
        contacts[contacts.count - 1].arm = arm
        contacts[contacts.count - 1].fresh = true
      } else {
        contacts.append(Contact(arm: arm))
      }
    } else if !contacts.isEmpty {
      contacts[contacts.count - 1].lifted = true
    }
  }
  public mutating func frame(after dt: Double) -> String? {
    guard let contact = contacts.first else { return nil }
    elapsed += dt
    if !contact.fresh && contact.lifted {
      contacts.removeFirst()
      elapsed = 0
      return #"{"dt":\#(dt)}"#
    }
    guard contact.fresh || elapsed >= 1.0 / 30 - 0.002 else { return nil }
    contacts[0].fresh = false
    defer { elapsed = 0 }
    return #"{"dt":\#(elapsed),"arm":\#(contact.arm)}"#
  }
  public mutating func reset() { self = Self() }
}

struct Aim: Decodable {
  // tilt and spin are any value on 0.9 (whole steps before it)
  struct Plan: Decodable { let loft, release, tilt, spin, dist: Double? }
  /// The engine's rail (session.lua aimView): r1 "FIELD 2", "BASE 5", "KING" or a
  /// drilled kubb's "2.3 M".
  struct Rail: Decodable { let r1, r2: String? }
  /// The sliders' numbers (since 0.9; absent on an older engine).
  struct Controls: Decodable { let arc, tilt, spin: PlanControl? }
  struct Wind: Decodable { let text: String }
  let wind: Wind?, advText: String?
  let plan: Plan?, mix: Double?, projectile: String?
  let controls: Controls?
  let marker, thrower: GroundMark?
  let arc: [WorldPoint]?, advY: Double?
  /// The Kid line in a Kid match (engine 0.15), the view frame's y; nil in any other.
  let kidY: Double?
  let lineY, forwardY, halfWidth, backMax: Double?
  let rail: Rail?
}
struct AimOutput: Decodable {
  let aim: Aim, camera: Camera
  let dial: DialState?, recording: Recording?, event: String?
}
struct ViewOutput: Decodable {
  let need: MatchNeed
  let aim: Aim, camera: Camera, items: [Piece], surface: Surface, set: String, dial: DialState
  /// The match's scene (0.9 on; absent before), carried untouched.
  let scene: String?
}
private struct Shown: Decodable {
  let camera: Camera, speed: Double, done: Bool, dial: DialState
  /// The pieces at that moment, un-turned into the world frame while the wide view is on.
  let items: [Piece]?
}
/// The engine's `setWide` answer: the wide camera and its smallest base kubb (frame px).
struct WideOutput: Decodable {
  let camera: Camera, kind: String, farPx: Double
}

public struct HitBurst {
  public let kind: String, age: Double
  let anchor: V3, focusX: Double?
  /// Drawn in the watcher's wide view (the letterbox fit).
  var wide = false
  /// The far baseline's frame y the pitch is fitted by (PitchScene.farFrameY).
  var anchorY: Double? = nil
  public func point(size: CGSize, camera: Camera) -> CGPoint? {
    PitchProjection(size: size, camera: camera, focusX: focusX ?? 200, letterbox: wide, anchorY: anchorY).project(anchor)
  }
}

public typealias PracticePitch = PitchSession

@MainActor
public final class PitchSession {
  let appVersion: String
  var trail = ReportTrail() {
    // the match's clock is its start's (MatchClock), read again only for another match
    didSet { if trail.start != oldValue.start { clockStart = MatchClock.Start(snapshot: trail.start) } }
  }
  /// The match's start as its clock reads it (its snapshot's `opts.start`, with the
  /// starting host's `utcOffset`), nil outside a match or for a start with no fields.
  private(set) var clockStart: MatchClock.Start?
  /// The device's clock, which a test may set.
  var clockNow: () -> Date = Date.init
  /// An action's `at` now on the match's clock (engine 0.18.0, docs/MATCH.md "A match's
  /// length"): nil outside a match and for a start with no offset.
  func stamp() -> JS? { need == nil ? nil : MatchClock.stamp(on: clockStart, now: clockNow()) }
  /// An action this device makes (a raise, a punishment kubb, a resignation), or a `frame`
  /// call's input, with the match's stamp: every one goes through here.
  func stamped(_ json: String) -> String { MatchClock.adding(stamp(), to: json) }
  /// The engine this session runs on now: the newest, or the one a match belongs to
  /// (`useEngine(minor:)`).
  public private(set) var engine: Engine
  /// The newest engine's full version (its `engineVersion`), whatever this session runs now.
  public let newestVersion: String
  /// One Lua state per major.minor this session has run, made the first time.
  private var engines: [String: Engine] = [:]
  /// The engine's `names.*` door, on the newest engine (names are the newest's words).
  public private(set) lazy var names = Names(engine: engines[Engine.newest] ?? engine)
  private let decoder = JSONDecoder()
  var input: any ThrowInput
  private(set) var playback: Playback?
  public internal(set) var scene: PitchScene, camera: Camera, dial: DialState
  public private(set) var result: ThrowResult?, bursts: [HitBurst] = []
  private var resultAge = 0.0
  /// The coach line's slow flick (Coach.swift): this player's own last throw was SLOW.
  public internal(set) var coachSlow = false
  /// ... and this player's own last throw was a drive that fell SHORT (Coach.swift).
  public internal(set) var coachShort = false
  private var playbackLocal = false
  /// The throw playing was planned as a drive (engine 0.16, ARC under its knee).
  private var playbackDrive = false
  /// The shown scene's effects (`useLook`): fed by the playback, drawn after the pieces.
  public private(set) var effects: SceneEffects?
  /// Seconds since this session began, for the night's twinkling stars.
  public private(set) var lookTime = 0.0
  public let options: SoloOptions
  public internal(set) var need: MatchNeed?, handoff: MatchNeed.Handoff?, placement: PlacementCheck?
  public internal(set) var revision = 0
  public internal(set) var plan = false
  /// The loft (ARC's words) and the side: a baton's tilt in degrees or a kubb's spin
  /// in taps, any value on 0.9.
  public private(set) var arcDegrees: Int?, sideStep: Double?
  /// The planned launch loft in degrees, as the engine gives it (under 0 for a drive that
  /// leaves the hand going down, engine 0.16).
  public private(set) var loft: Double?
  /// The engine's numbers for ARC and for TILT or SPIN (`aim.controls`, since 0.9);
  /// nil on an older engine, whose sliders keep their fixed scale and steps.
  public private(set) var arcControl: PlanControl?, sideControl: PlanControl?
  /// The planned release on the clock (degrees) and the side in the engine's steps.
  public private(set) var release: Double?, sideSteps = 0, projectile: String?
  /// The plan slider a finger holds, where it is (0...1), and the place not yet sent.
  public internal(set) var held: PlanSlider?, heldFraction: Double?
  var pendingSlide: (PlanSlider, Double)?
  /// A slider let go by `cancelHeld` (the screen turned under the finger): the
  /// rest of that drag is ignored until the finger lifts or presses again.
  var slideLetGo = false
  var peekLeft = 0.0
  /// STAND held (StandPad.swift), and its caption's second after it is let go.
  var standDrag: StandDrag?
  var standPeekLeft = 0.0
  public internal(set) var standAim = StandAim()
  var autoRaise = AutoRaise()
  /// A watched raise of the need on the screen (AutoRaise.swift), and the kubbs the engine
  /// stood up with the last throw being watched before the next view.
  var raiseShow: RaiseShow?
  var stoodShow: StoodShow?
  /// Reduce Motion (the app sets it): a watched raise stands each kubb with no tip.
  public var reduceMotion = false
  /// A line for VoiceOver to say once (a watched raise's summary), numbered so the same
  /// words twice are said twice.
  public internal(set) var raiseNews: (id: Int, text: String)?
  var raiseNewsCount = 0
  /// The turn and side whose automatic raising has begun (its first kubb lay a moment and
  /// its one line was said).
  var raiseRun: String?
  /// Actions waiting behind a watched raise (OnlinePitch.actionsWaiting).
  var raiseCatchUp = 0
  /// The raise screen's touch (RaiseTouch.swift): the kubb being tipped up, the end lit
  /// past half way, and the allowed end lit (for `left` seconds) after a refused one.
  public internal(set) var raiseDragging: RaiseTouch.Drag?
  var raiseSelected: Int?
  var raiseHint: (i: Int, left: Double)?
  /// On a phone on its side, the raise and punishment bar's top in pt above the
  /// screen's foot, as the app measured it; nil while no bar shows. The scene
  /// moves up only if its lowest point would come within 8 pt of it.
  public var stillFloor: Double? {
    didSet {
      guard stillFloor != oldValue else { return }
      scene.stillFloor = stillFloor
      revision += 1
    }
  }
  var mix = 0.0
  var save: MatchSave?
  /// This solo match's actions are being kept on disk (SoloTrail.swift).
  var trailKept = false
  /// The kept trail begins at this match's first snapshot, so it could be replayed.
  public internal(set) var trailComplete = false
  var cursor: GroundMark?
  var onlineAction: ((JSONText) throws -> Void)?
  public internal(set) var acceptsInput = true
  var runsComputer = true
  var playerSide: () -> String? = { "A" } // solo seat; online asks pitch.playingSide at the win
  public var onFeedback: ((PitchFeedback) -> Void)?
  /// s of display time since this board's own last knock (the neighbours keep quiet round
  /// it, NeighbourSounds.ownGap).
  var knockAge = Double.infinity
  public var cancelFeedback: (() -> Void)?
  public var canAim: Bool {
    acceptsInput && !playing && handoff == nil && !raiseShowing
      && (need == nil || (need?.kind == "throw" && need?.cpu == false))
  }
  public private(set) var windText: String?, advantageText: String?, slow = false
  /// What the thrower aims at, the engine's rail (`rail.r1`: "FIELD 2", "BASE 5", "KING").
  public private(set) var railAt: String?
  /// The throw's distance in m, stance to target (the engine's plan `dist`), for the
  /// meter's distance tab.
  public private(set) var distance: Double?
  /// The set-up tray's open plate (TrayLayout.swift), one at a time; nil: all closed.
  /// ARC open shows the side view (`plan`).
  public internal(set) var openPlate: TrayPlate?
  public var playing: Bool { playback != nil }
  /// The watcher's free camera (FreeCamera.swift), its lens the wide camera while the
  /// wide view is on.
  public let freeCamera = FreeCamera()
  /// The `setWide` box this session's engine has (nil: the wide view is off), re-sent
  /// to another engine's Lua state when the match moves to it.
  private var wideBox: String?
  /// The watcher's wide view is on (`watchWide`).
  public var wideOn: Bool { scene.wide }
  /// The free camera takes the pitch: the wide view, and not a raise or punishment
  /// scene (those keep their own close look, as the thrower's view does).
  public var freeOn: Bool { scene.wide && scene.stillZoom == nil && freeCamera.lens != nil }
  /// The camera the pitch is drawn through: the free camera's in the wide view.
  public var shownCamera: Camera { freeOn ? freeCamera.camera(camera) : camera }
  /// This board shows a match it has no side in (OnlinePitch sets it): it watches, in
  /// the watcher's wide view where the screen allows (`watchWide`).
  public var watching = false

  /// A move of the free camera from the app's gestures. The screen's RESET VIEW
  /// follows `freeCamera.moved` through `revision`.
  public func moveFree(_ body: (FreeCamera) -> Void) {
    guard freeOn else { return }
    let was = freeCamera.moved
    body(freeCamera)
    if was != freeCamera.moved { revision += 1 }
  }

  /// RESET VIEW: back to the wide view's own camera, eased over 0.45 s or at once with
  /// Reduce Motion.
  public func resetView(reduced: Bool) {
    guard freeCamera.moved else { return }
    freeCamera.reset(reduced: reduced)
    revision += 1
  }

  public init(appVersion: String, input: any ThrowInput = PointerDial()) throws {
    self.appVersion = appVersion
    self.input = input
    engine = try Engine(appVersion: appVersion)
    Self.askForImpacts(engine)
    newestVersion = engine.engineVersion
    engines[engine.minor] = engine
    options = try SoloOptions(engine: engine)
    let v = try decoder.decode(
      ViewOutput.self,
      from: Data(
        engine.call(
          "new",
          json:
            #"{"mode":"practice","drill":false,"surface":"grass"}"#
        ).utf8))
    scene = PitchScene(surface: v.surface, set: v.set, items: v.items, look: v.scene)
    scene.farFrameY = PitchProjection.farFrame(v.camera)
    camera = v.camera
    dial = v.dial
    aim(v.aim, camera: v.camera)
  }

  /// Run on the engine of major.minor `minor` (nil: the newest) from the next call on:
  /// a match plays, replays and is checked only on its own engine (kubb-engine
  /// docs/VERSIONING.md "Playing together"). Its Lua state is made the first time and
  /// kept. The caller then restores or starts a match on it. Throws
  /// `EngineError.notCarried` for a minor this build does not carry, changing nothing.
  public func useEngine(minor: String?) throws {
    let mm = minor ?? Engine.newest
    if engine.minor == mm { return }
    defer { try? carryWide() }
    if let e = engines[mm] {
      engine = e
      return
    }
    let e = try Engine(minor: mm, appVersion: appVersion)
    Self.askForImpacts(e)
    engines[mm] = e
    engine = e
  }

  /// The review tools' spin picture: the practice pitch drilling a kubb (`setDrill`) at
  /// SPIN's most (`setSpin`, the engine's `controls.spin.max`). Review only.
  public func reviewDrill() throws {
    _ = try engine.call("setDrill", json: #"{"on":true}"#)
    try adopt(read("view"))
    let most = sideControl?.max ?? 1
    let a: AimOutput = try read("setSpin", #"{"spin":\#(most)}"#)
    aim(a.aim, camera: a.camera)
    struct DialView: Decodable { let dial: DialState }
    dial = (try read("view") as DialView).dial
    revision += 1
  }
  /// The review tools' and tests' close throw (engine 0.16's drive; the web's tests'
  /// standAt): the thrower stands `d` m short of the nearest of the throw's targets (a far
  /// standing base kubb from 7.5 m), aimed at it, as far forward as the rules let them.
  /// Review only.
  public func reviewStand(short d: Double) throws {
    struct V: Decodable {
      struct N: Decodable {
        struct S: Decodable { let targets: [String]? }
        let setup: S?
      }
      struct A: Decodable { let forwardY: Double? }
      let need: N, aim: A, items: [Piece]
    }
    let v: V = try read("view")
    let target: Piece? =
      d >= 7.5
      ? v.items.first { $0.kind == "kubb" && $0.y > 7.5 && $0.z > 0.07 }
      : (v.need.setup?.targets ?? []).compactMap { id in v.items.first { $0.id == id } }.min { $0.y < $1.y }
    guard let t = target else { return }
    let y = max(0, min(v.aim.forwardY ?? 0, t.y - d))
    try replan("setStance", #"{"x":\#(t.x),"y":\#(y)}"#)
    try replan("setTarget", #"{"x":\#(t.x),"y":\#(t.y),"snap":true}"#)
  }

  /// The seed the Tournament's neighbours open with (TournamentNeighbours): the match's
  /// own (its snapshot's `opts.seed`, so two phones in one match can show the same
  /// tournament), or for a practice one of this session's, kept while it lasts.
  public var neighbourSeed: Int {
    guard need != nil, let start = trail.start else { return practiceSeed }
    if let c = seedCache, c.start == start { return c.seed }
    struct Snap: Decodable {
      struct Opts: Decodable { let seed: Int? }
      let opts: Opts?
    }
    let seed = (try? decoder.decode(Snap.self, from: Data(start.utf8)))?.opts?.seed ?? 1
    seedCache = (start, seed)
    return seed
  }
  private var seedCache: (start: String, seed: Int)?
  private let practiceSeed = Int.random(in: 1..<2_147_483_648)

  /// The Kid line's distance in front of the thrower's own line (m), in a Kid match.
  public var kidLineOut: Double? { scene.kidY.map { $0 - standAim.lineY } }
  /// The live rings' ages (s), for the review tools' ring picture.
  public var ringAges: [Double] { effects?.impacts?.live.map(\.age) ?? [] }
  /// A piece is drawn as a spin this frame (Spin.swift), most of the way.
  public var spinsFast: Bool { scene.spins?.values.contains { $0.u > 0.8 } == true }

  /// Ground impacts on (`setImpacts`, engine 0.14), once per Lua state: each recording's
  /// `timeline.impacts` from the next throw, for the scenes that ring or puff
  /// (Impacts.swift). Presentation only, in no snapshot, action or hash; an engine before
  /// 0.14 answers an unknown call, which changes nothing.
  static func askForImpacts(_ e: Engine) {
    _ = try? e.call("setImpacts", json: #"{"on":true}"#)
  }

  /// The watcher's wide view on a screen of `size` (WatchView): the engine frames the
  /// whole pitch in the box and gives everything in the world frame. True when it is
  /// on; off (false) when the smallest base kubb would be under 2 pt. The view is read
  /// again at once unless a throw is playing (its next moment brings the camera).
  @discardableResult public func watchWide(size: CGSize, safe: ScreenInsets) throws -> Bool {
    guard size.width > 0, size.height > 0 else { return false }
    let b = WatchView.box(size: size, safe: safe)
    let box = JS.object([
      ("box", .object([("left", .number(b.left)), ("top", .number(b.top)), ("right", .number(b.right)), ("bottom", .number(b.bottom))]))
    ]).ascii
    let k = WatchView.scale(size)
    freeCamera.k = k
    if box == wideBox, scene.wide { return true }
    let out: WideOutput = try read("setWide", box)
    guard out.farPx * k >= WatchView.observeMinPx else {
      // the engine took the box to answer: put its thrower's view back, whatever this
      // session was showing (a first look that does not fit has no wide view to end)
      freeCamera.setLens(nil)
      try clearWide()
      return false
    }
    wideBox = box
    freeCamera.setLens(out.camera)
    scene.wide = true
    revision += 1
    try reread()
    return true
  }

  /// The wide view off: the thrower's view again, the free camera let go.
  public func endWide() throws {
    freeCamera.setLens(nil)
    guard wideBox != nil || scene.wide else { return }
    try clearWide()
  }

  /// The engine's wide view off and this session's with it.
  private func clearWide() throws {
    wideBox = nil
    scene.wide = false
    revision += 1
    _ = try engine.call("setWide", json: "{}")
    try reread()
  }

  /// The current engine's Lua state has the wide view this session shows (after
  /// `useEngine` moved it to another).
  func carryWide() throws {
    guard let box = wideBox else { return }
    let out: WideOutput = try read("setWide", box)
    freeCamera.setLens(out.camera)
  }

  private func reread() throws {
    guard playback == nil, need != nil else { return }
    try adopt(read("view"))
  }

  /// The major.minors this session has a Lua state for (a test sees the lazy one).
  public var loadedEngines: [String] { Engine.carried.filter { engines[$0] != nil } }

  func read<T: Decodable>(_ method: String, _ args: String = "") throws -> T {
    try decoder.decode(T.self, from: Data(engine.call(method, json: args).utf8))
  }
  func aim(_ a: Aim, camera c: Camera) {
    windText = a.wind?.text
    advantageText = a.advText
    railAt = a.rail?.r1
    distance = a.plan?.dist
    camera = c
    mix = a.mix ?? 0
    loft = a.plan?.loft
    arcDegrees = a.plan?.loft.map { PlanScale.whole($0) }
    sideStep = a.projectile == "kubb" ? a.plan?.spin : a.plan?.tilt
    release = a.plan?.release
    projectile = a.projectile
    arcControl = a.controls?.arc
    sideControl = a.projectile == "kubb" ? a.controls?.spin : a.controls?.tilt
    standAim = StandAim(
      projectile: a.projectile, lineY: a.lineY ?? 0, forwardY: a.forwardY,
      halfWidth: a.halfWidth ?? 2.5, backMax: a.backMax ?? 3, kidY: a.kidY)
    sideSteps = PlanScale.steps(of: sideStep ?? 0, kubb: a.projectile == "kubb")
    scene.advantageY = a.advY
    scene.kidY = a.kidY
    scene.marker = a.marker
    let reference = PitchProjection(size: CGSize(width: 400, height: 240), camera: c)
    if let marker = a.marker, marker.shown != false, let p = reference.project(marker.point) {
      scene.focusX = Double(p.x)
    } else {
      scene.focusX = nil
    }
    scene.thrower = a.thrower
    scene.arc = a.arc?.map(\.vector)
    if scene.wide {
      // the wide view draws no aim: the marker, the arc and the thrower's spot are the
      // thrower's (the web's wide view leaves them out)
      scene.marker = nil
      scene.arc = nil
      scene.thrower = nil
      scene.focusX = nil
    }
  }
  /// The side whose view frame the board draws now, decided here and nowhere else (the
  /// live neighbours turn with it, `PitchScene.neighboursTurned`): the need's side while it
  /// has one (the thrower's for an aim and its throw, the defender's for a raise or a
  /// punishment kubb, whose poses the engine gives in that side's frame); otherwise (a
  /// finished match, live, resumed or reopened, or a match adopted from a pitch) the frame
  /// the engine holds the match's pitch in, the session's `frameSide`, which is the
  /// snapshot's `side` (session.restore sets it from there, and a live session's is the
  /// last throw's, the same side). A practice has no side: Team A's. A throw's recording
  /// plays in the frame of the need it was thrown under, which stays until the next adopt.
  /// In every view: the engine's wide view re-frames the items and the playback but never
  /// a need, so a watcher's raise or punishment scene is the defender's frame too
  /// (`PitchScene.neighboursTurned` leaves the rest of the wide view unturned).
  func viewFrame(of n: MatchNeed) -> String? {
    if ["throw", "raise", "punish"].contains(n.kind) { return n.side }
    struct Snap: Decodable { let side: String? }
    guard let text = try? engine.call("snapshot") else { return nil }
    return (try? decoder.decode(Snap.self, from: Data(text.utf8)))?.side
  }

  func adopt(_ v: ViewOutput) throws {
    let wide = scene.wide, far = scene.farFrameY
    scene = PitchScene(surface: v.surface, set: v.set, items: v.items, look: v.scene)
    scene.wide = wide
    // a throw's aim camera fits the tall screen by its far baseline until the next throw
    scene.farFrameY = v.need.kind == "throw" ? (PitchProjection.farFrame(v.camera) ?? far) : far
    scene.frameSide = viewFrame(of: v.need)
    dial = v.dial
    aim(v.aim, camera: v.camera)
    if need != nil {
      let previous = need
      let previousHandoff = handoff
      need = v.need
      // A resignation can retain the preceding informative card in the engine view.
      handoff = v.need.kind == "throw" ? v.need.card?.handoff : nil
      if let handoff, handoff.turn != previousHandoff?.turn || handoff.toName != previousHandoff?.toName {
        onFeedback?(PitchFeedback(haptic: .handoff))
      }
      if v.need.kind == "over", previous?.kind != "over",
        let winner = v.need.winner?.winner, winner == playerSide() {
        onFeedback?(PitchFeedback(haptic: .win))
      }
      placement = nil
      cursor = v.need.cursor
      if previous?.kind != v.need.kind || previous?.kubb != v.need.kubb || previous?.n != v.need.n {
        resetRaiseTouch()
      }
      try settleScene()
      revision += 1
    }
  }

  /// This board's own knock sounded within `half` s, or is due within `half` s of the
  /// recording's clock (the web's ownKnockNear): the neighbours keep quiet round it.
  public func ownKnockNear(_ half: Double) -> Bool {
    if knockAge < half { return true }
    guard let p = playback, !p.finished else { return false }
    let next = p.feedback[p.nextCue...].first { $0.cue.sound != nil }
    return next.map { $0.time - p.nextTime < half } ?? false
  }

  /// The verdict goes the moment the player starts to aim (a press on the pitch, the
  /// target, the stance, a tray plate or the meter): it is never in the way of the next
  /// throw (the owner, 2026-11-22: "the display stays on the screen for a while keeping the
  /// player from being able to aim at times"). VoiceOver has said it once already.
  public func verdictAway() {
    guard result != nil, playback == nil else { return }
    result = nil
    revision += 1
  }

  func resetPresentation() {
    cancelFeedback?()
    raiseShow = nil
    stoodShow = nil
    raiseCatchUp = 0
    input.reset()
    resetRaiseTouch()
    playback = nil
    result = nil
    bursts = []
    plan = false
    openPlate = nil
    endSlide()
    endStand()
    mix = 0
    slow = false
    handoff = nil
    placement = nil
    cursor = nil
    revision += 1
  }

  public func surface(_ s: Surface) throws {
    guard !playing else { return }
    try adopt(read("setSurface", #"{"surface":"\#(s.rawValue)"}"#))
    trail.append(JS.object([("type", .string("surface")), ("surface", .string(s.rawValue))]).json)
  }
  public func marker(in size: CGSize) -> CGPoint? {
    guard let m = scene.marker, m.shown != false else { return nil }
    return scene.projection(size, camera).project(m.point)
  }
  // Aim commands return the camera and plan. Only the session can supply the
  // corresponding dial ranges and prompt. A stationary board may get no more frames.
  func replan(_ method: String, _ args: String) throws {
    struct DialView: Decodable { let dial: DialState }
    let previousArc = arcDegrees
    let previousSide = sideStep
    let previousRelease = release
    let previousControl = arcControl
    let a: AimOutput = try read(method, args)
    aim(a.aim, camera: a.camera)
    let view: DialView = try read("view")
    dial = view.dial
    // ARC's range moves with the circle and the stance (engine 0.16: its floor), so the
    // open slider is drawn again when it does, whatever the plan
    if arcDegrees != previousArc || sideStep != previousSide || release != previousRelease
      || arcControl != previousControl
    {
      revision += 1
    }
  }

  public func target(_ point: CGPoint, size: CGSize, snap: Bool, tap: Bool = false) throws {
    guard canAim, let g = scene.projection(size, camera).ground(point), !tap || g.y > 0.5 else {
      return
    }
    try replan("setTarget", #"{"x":\#(g.x),"y":\#(g.y),"snap":\#(snap)}"#)
  }
  public func sample(_ point: CGPoint?) { if canAim && !showsSide { input.sample(point) } }

  func resetContact() {
    input.reset()
  }

  public func cancelInput() throws {
    input.reset()
    guard canAim else { return }
    // The session's plan-held frame disarms even a forward swing. Ease immediately back to aim.
    let _: AimOutput = try read("frame", stamped(#"{"plan":true,"dt":0.001}"#))
    let a: AimOutput = try read("frame", stamped(#"{"dt":0.016666666666666666}"#))
    aim(a.aim, camera: a.camera)
    if let d = a.dial { dial = d }
  }

  /// One display tick. Returns true only when the screen needs repainting.
  @discardableResult public func tick(_ delta: Double) throws -> Bool {
    let dt = min(max(delta, 0.00001), 0.05)
    lookTime += dt
    knockAge += dt
    var eased = false
    if freeCamera.easing {
      let was = freeCamera.moved
      eased = freeCamera.tick(dt)
      if was != freeCamera.moved { revision += 1 }
    }
    if playback != nil {
      try play(dt)
      return true
    }
    // the dust of the last throw settles while the next is aimed
    let settling = effects?.active == true
    if settling { effects?.tick(dt) }
    let changed = try tickAim(dt)
    return changed || settling || eased
  }

  private func tickAim(_ dt: Double) throws -> Bool {
    var changed = try applySlide()
    if try applyStand() { changed = true }
    if held == nil && peekLeft > 0 { peekLeft = max(0, peekLeft - dt) }
    if standDrag == nil && standPeekLeft > 0 {
      standPeekLeft = max(0, standPeekLeft - dt)
      if standPeekLeft == 0 {
        revision += 1
        changed = true
      }
    }
    if try raiseHintTick(dt) { changed = true }
    // a watched raise: nothing else moves until it ends
    if try raiseShowTick(dt) || stoodShowTick(dt) { return true }
    if try autoRaiseTick(dt) { return true }
    if result != nil {
      resultAge += dt
      if resultAge >= Pacing.verdictShown {
        result = nil
        changed = true
      }
    }
    guard acceptsInput || (need?.cpu == true && runsComputer) else { return changed }
    guard handoff == nil, need == nil || need?.kind == "throw" else { return changed }
    let args: String
    var inputFrame = false
    let side = showsSide
    if !side, let sample = input.frame(after: dt) {
      args = sample
      inputFrame = canAim
    } else if (side && mix < 1) || (!side && mix > 0) || need?.cpu == true {
      args = #"{"dt":\#(dt),"plan":\#(side)}"#
    } else {
      return changed
    }
    // the computer's throws come through here too: only the player's own
    // carry verdicts and may change what the coach says next
    let own = need?.cpu != true
    let text = try engine.call("frame", json: stamped(args))
    let a = try decoder.decode(AimOutput.self, from: Data(text.utf8))
    let railBefore = railAt
    // read before the answer's aim is taken: a release's answer already carries the next
    // throw's aim, and the coach judges the throw that was made
    let wasDrive = isDrive
    aim(a.aim, camera: a.camera)
    // the release's aim already counts what the throw will fell: the header keeps the
    // count it had until the throw has played (the web's does)
    if a.recording != nil { railAt = railBefore }
    if let d = a.dial { dial = d }
    if inputFrame, let onFeedback {
      for cue in input.feedback(crossings: a.dial?.crossings ?? [], released: a.event == "release") {
        onFeedback(cue)
      }
    }
    if let recording = a.recording {
      try beginPlayback(recording, local: own, drive: own && wasDrive)
      if let action = try JSONNode.parse(text)["action"] { try committed(action.raw) }
    }
    return true
  }

  /// `local`: the throw was made on this device (its verdicts are the player's). `drive`:
  /// it was a drive, read by the caller before the release's answer replaced the aim (a
  /// drive's SHORT verdict is coached).
  func beginPlayback(_ recording: Recording, local: Bool = false, drive: Bool = false) throws {
    playbackLocal = local
    playbackDrive = drive
    plan = false
    openPlate = nil
    endSlide()
    endStand()
    input.reset()
    playback = Playback(recording, rings: effects?.rings == true)
    effects?.watch(recording)
    result = nil
    scene.arc = nil
    scene.marker = nil
    scene.thrower = nil
    try play(0)
  }

  public func skipPlayback() throws {
    guard let p = playback else { return }
    cancelFeedback?()
    result = p.recording.result
    resultAge = 0
    noteOwnResult()
    bursts = []
    playback = nil
    effects?.clear()
    // the engine's own raises before the next throw are still watched (the web's skip
    // runs on to its endPlayback)
    let view: ViewOutput = try read("view")
    if !beginStoodShow(view: view) { try adopt(view) }
  }

  /// Show the scene `id` (SceneID.shown: an unknown one is the day): its effects
  /// are made again when the scene or Reduce Motion changes, so a throw never
  /// carries the last scene's dust.
  public func useLook(_ id: String, reduced: Bool) {
    reduceMotion = reduced
    let shown = SceneID.shown(id)
    if effects?.look == shown && effects?.reduced == reduced { return }
    if effects == nil && shown == "day" { return }
    effects = SceneEffects(look: shown, reduced: reduced)
  }

  private func noteOwnResult() {
    guard playbackLocal else { return }
    coachSlow = result?.slowFlick ?? false
    coachShort = Coach.shortDrive(power: result?.verdicts?.power, drive: playbackDrive)
  }

  private func play(_ dt: Double) throws {
    guard var p = playback else { return }
    if !p.finished {
      let t = min(p.nextTime, p.recording.duration)
      let shown: Shown = try read("showAt", #"{"t":\#(t)}"#)
      // the wide view's pieces come un-turned from the engine; the recording's own are
      // in the thrower's frame
      scene.items = scene.wide ? (shown.items ?? p.pieces(at: t)) : p.pieces(at: t)
      // a piece turning faster than the frames can show is drawn as a spin (Spin.swift),
      // from its pose the frame before
      scene.spins = SpinTune.spins(from: p.lastShown, to: scene.items)
      p.lastShown = Dictionary(scene.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      effects?.observe(scene.items, t)
      slow = shown.speed < 0.99
      camera = shown.camera
      dial = shown.dial
      while p.nextCue < p.feedback.count && p.feedback[p.nextCue].time <= t {
        if p.feedback[p.nextCue].cue.sound != nil { knockAge = 0 }
        onFeedback?(p.feedback[p.nextCue].cue)
        p.nextCue += 1
      }
      for i in p.starts.indices
      where p.starts[i] == nil && t >= p.recording.timeline.bursts[i].start {
        p.starts[i] = p.realTime
      }
      if shown.done {
        p.finished = true
        result = p.recording.result
        resultAge = 0
        noteOwnResult()
      }
      p.nextTime = min(p.recording.duration, t + dt * shown.speed)
    } else {
      p.rest += dt
      // the verdict's time runs from the throw coming to rest (Pacing.verdictShown)
      resultAge += dt
      effects?.tick(dt)
      // between throws nothing spins
      if scene.spins != nil { scene.spins = nil }
    }
    bursts = p.starts.enumerated().compactMap { i, start in
      guard let start else { return nil }
      let b = p.recording.timeline.bursts[i]
      let age = p.realTime - start
      guard age < (b.kind == "double" ? 0.7 : 0.6) else { return nil }
      return HitBurst(
        kind: b.kind, age: age, anchor: b.anchor.vector, focusX: scene.focusX, wide: scene.wide, anchorY: scene.farFrameY)
    }
    p.realTime += dt
    if p.rest >= Pacing.restAfterThrow && bursts.isEmpty {
      playback = nil
      // kubbs the engine stood up and placed after this throw (the computer's raises, a
      // match raising automatically, a punishment kubb) are watched first, from the
      // engine's own list (AutoRaise.swift, engine 0.16.0's `setup.settled`)
      let view: ViewOutput = try read("view")
      if !beginStoodShow(view: view) { try adopt(view) }
    } else {
      playback = p
    }
  }
}
