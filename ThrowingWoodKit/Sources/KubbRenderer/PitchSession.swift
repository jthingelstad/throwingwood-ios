import CoreGraphics
import Foundation
import KubbEngine
import KubbRooms

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
  struct Plan: Decodable { let loft, release: Double?, tilt, spin: Int? }
  struct Wind: Decodable { let text: String }
  let wind: Wind?, advText: String?
  let plan: Plan?, mix: Double?, projectile: String?
  let marker, thrower: GroundMark?
  let arc: [WorldPoint]?, advY: Double?
  let lineY, forwardY, halfWidth, backMax: Double?
}
struct AimOutput: Decodable {
  let aim: Aim, camera: Camera
  let dial: DialState?, recording: Recording?, event: String?
}
struct ViewOutput: Decodable {
  let need: MatchNeed
  let aim: Aim, camera: Camera, items: [Piece], surface: Surface, set: String, dial: DialState
}
private struct Shown: Decodable {
  let camera: Camera, speed: Double, done: Bool, dial: DialState
}

public struct HitBurst {
  public let kind: String, age: Double
  let anchor: V3, focusX: Double?
  public func point(size: CGSize, camera: Camera) -> CGPoint? {
    PitchProjection(size: size, camera: camera, focusX: focusX ?? 200).project(anchor)
  }
}

public typealias PracticePitch = PitchSession

@MainActor
public final class PitchSession {
  let appVersion: String
  var trail = ReportTrail()
  /// The engine this session runs on now: the newest, or the one a match belongs to
  /// (`useEngine(minor:)`).
  public private(set) var engine: Engine
  /// One Lua state per major.minor this session has run, made the first time.
  private var engines: [String: Engine] = [:]
  private let decoder = JSONDecoder()
  var input: any ThrowInput
  private(set) var playback: Playback?
  public internal(set) var scene: PitchScene, camera: Camera, dial: DialState
  public private(set) var result: ThrowResult?, bursts: [HitBurst] = []
  private var resultAge = 0.0
  /// The coach line's slow flick (Coach.swift): this player's own last throw was SLOW.
  public internal(set) var coachSlow = false
  private var playbackLocal = false
  public let options: SoloOptions
  public internal(set) var need: MatchNeed?, handoff: MatchNeed.Handoff?, placement: PlacementCheck?
  public internal(set) var revision = 0
  public internal(set) var plan = false
  public private(set) var arcDegrees: Int?, sideStep: Int?
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
  var playerSide: () -> String? = { "A" } // solo seat; online asks room.playingSide at the win
  public var onFeedback: ((PitchFeedback) -> Void)?
  public var cancelFeedback: (() -> Void)?
  public var canAim: Bool {
    acceptsInput && !playing && handoff == nil
      && (need == nil || (need?.kind == "throw" && need?.cpu == false))
  }
  public private(set) var windText: String?, advantageText: String?, slow = false
  var levelOverride: String?
  public var playing: Bool { playback != nil }

  public init(appVersion: String, input: any ThrowInput = PointerDial()) throws {
    self.appVersion = appVersion
    self.input = input
    engine = try Engine(appVersion: appVersion)
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
    scene = PitchScene(surface: v.surface, set: v.set, items: v.items)
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
    if let e = engines[mm] {
      engine = e
      return
    }
    let e = try Engine(minor: mm, appVersion: appVersion)
    engines[mm] = e
    engine = e
  }

  /// The major.minors this session has a Lua state for (a test sees the lazy one).
  public var loadedEngines: [String] { Engine.carried.filter { engines[$0] != nil } }

  func read<T: Decodable>(_ method: String, _ args: String = "") throws -> T {
    try decoder.decode(T.self, from: Data(engine.call(method, json: args).utf8))
  }
  func aim(_ a: Aim, camera c: Camera) {
    windText = a.wind?.text
    advantageText = a.advText
    camera = c
    mix = a.mix ?? 0
    arcDegrees = a.plan?.loft.map { Int($0.rounded()) }
    sideStep = a.projectile == "kubb" ? a.plan?.spin : a.plan?.tilt
    release = a.plan?.release
    projectile = a.projectile
    standAim = StandAim(
      projectile: a.projectile, lineY: a.lineY ?? 0, forwardY: a.forwardY,
      halfWidth: a.halfWidth ?? 2.5, backMax: a.backMax ?? 3)
    sideSteps = PlanScale.steps(of: sideStep ?? 0, kubb: a.projectile == "kubb")
    scene.advantageY = a.advY
    scene.marker = a.marker
    let reference = PitchProjection(size: CGSize(width: 400, height: 240), camera: c)
    if let marker = a.marker, marker.shown != false, let p = reference.project(marker.point) {
      scene.focusX = Double(p.x)
    } else {
      scene.focusX = nil
    }
    scene.thrower = a.thrower
    scene.arc = a.arc?.map(\.vector)
  }
  func adopt(_ v: ViewOutput) throws {
    scene = PitchScene(surface: v.surface, set: v.set, items: v.items)
    dial = v.dial
    aim(v.aim, camera: v.camera)
    if need != nil {
      let previous = need
      let previousHandoff = handoff
      need = v.need
      if let levelOverride, v.need.kind == "throw", v.need.cpu == false {
        try useLevel(levelOverride)
      }
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

  func resetPresentation() {
    cancelFeedback?()
    input.reset()
    resetRaiseTouch()
    playback = nil
    result = nil
    bursts = []
    plan = false
    endSlide()
    endStand()
    mix = 0
    slow = false
    levelOverride = nil
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
    let a: AimOutput = try read(method, args)
    aim(a.aim, camera: a.camera)
    let view: DialView = try read("view")
    dial = view.dial
    if arcDegrees != previousArc || sideStep != previousSide || release != previousRelease {
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
    let _: AimOutput = try read("frame", #"{"plan":true,"dt":0.001}"#)
    let a: AimOutput = try read("frame", #"{"dt":0.016666666666666666}"#)
    aim(a.aim, camera: a.camera)
    if let d = a.dial { dial = d }
  }

  /// One display tick. Returns true only when the screen needs repainting.
  @discardableResult public func tick(_ delta: Double) throws -> Bool {
    let dt = min(max(delta, 0.00001), 0.05)
    if playback != nil {
      try play(dt)
      return true
    }
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
    if try autoRaiseTick(dt) { return true }
    if result != nil {
      resultAge += dt
      if resultAge >= 6 {
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
    let text = try engine.call("frame", json: args)
    let a = try decoder.decode(AimOutput.self, from: Data(text.utf8))
    aim(a.aim, camera: a.camera)
    if let d = a.dial { dial = d }
    if inputFrame, let onFeedback {
      for cue in input.feedback(crossings: a.dial?.crossings ?? [], released: a.event == "release") {
        onFeedback(cue)
      }
    }
    if let recording = a.recording {
      try beginPlayback(recording, local: own)
      if let action = try JSONNode.parse(text)["action"] { try committed(action.raw) }
    }
    return true
  }

  /// `local`: the throw was made on this device (its verdicts are the player's).
  func beginPlayback(_ recording: Recording, local: Bool = false) throws {
    playbackLocal = local
    plan = false
    endSlide()
    endStand()
    input.reset()
    playback = Playback(recording)
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
    try adopt(read("view"))
  }

  private func noteOwnResult() {
    if playbackLocal { coachSlow = result?.slowFlick ?? false }
  }

  private func play(_ dt: Double) throws {
    guard var p = playback else { return }
    if !p.finished {
      let t = min(p.nextTime, p.recording.duration)
      let shown: Shown = try read("showAt", #"{"t":\#(t)}"#)
      scene.items = p.pieces(at: t)
      slow = shown.speed < 0.99
      camera = shown.camera
      dial = shown.dial
      while p.nextCue < p.feedback.count && p.feedback[p.nextCue].time <= t {
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
    }
    bursts = p.starts.enumerated().compactMap { i, start in
      guard let start else { return nil }
      let b = p.recording.timeline.bursts[i]
      let age = p.realTime - start
      guard age < (b.kind == "double" ? 0.7 : 0.6) else { return nil }
      return HitBurst(kind: b.kind, age: age, anchor: b.anchor.vector, focusX: scene.focusX)
    }
    p.realTime += dt
    if p.rest >= 0.8 && bursts.isEmpty {
      playback = nil
      try adopt(read("view"))
    } else {
      playback = p
    }
  }
}
