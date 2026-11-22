import Foundation
import KubbPitch
import simd

/// Automatic raising, the player's choice while a match raises by hand (Jamie,
/// 2026-11-19: "When raising kubbs we have three options today including an auto,
/// we should also add an "auto all". In fact I could see players wanting to shift
/// to auto raise kubbs for the rest of the game."). A port of the web's
/// src/game/auto-raise.js: AUTO ALL on the raise panel (`turn`) stands the rest of
/// this turn's kubbs on the engine's choice of end, and the menu's Raising (or
/// REST OF GAME on the panel) does it for the rest of the match (`game`). Nothing
/// is kept on the device: a match that should always raise itself is the match's
/// own Raising option.
///
/// Every automatic raise is watched (the owner, 2026-11-22: "When you hit auto to raise
/// kubbs you should watch the computer raise them."): each kubb lies a moment in the raise
/// scene, tips up onto the end the engine chose with the hand drag's tip, stands a moment,
/// and the next follows (`RaiseShow`, `Pacing.raiseStep`). The engine's actions and their
/// order do not change: each is the same `raise` action, sent as its kubb starts to tip.
public struct AutoRaise: Sendable {
  /// For the rest of this match.
  public internal(set) var game = false
  /// For the rest of this turn's kubbs (AUTO ALL).
  public internal(set) var turn = false
  /// This device has been asked to raise in this match: the menu shows its Raising
  /// row from then on.
  public internal(set) var seen = false
  /// A tap asked for the rest of this turn's raise at once: no more watching it.
  public internal(set) var hurry = false
  private var key: String?

  public init() {}

  public var on: Bool { game || turn }

  /// One display tick. `raising` names the kubb this device may raise now (nil:
  /// no raise of ours, or a card is up). True once for each kubb when automatic raising
  /// is on: its watched raise starts.
  public mutating func tick(_ dt: Double, raising: String?) -> Bool {
    guard let raising else {
      key = nil
      return false
    }
    seen = true
    guard on, key != raising else { return false }
    key = raising
    return true
  }

  /// The menu's Raising, and BY HAND / REST OF GAME on the panel.
  public mutating func setGame(_ value: Bool) {
    game = value
    if !value { turn = false }
    key = nil
  }

  /// AUTO ALL.
  public mutating func restOfTurn() {
    turn = true
    key = nil
  }

  /// The engine would not raise it: back to the player.
  public mutating func refused() {
    game = false
    turn = false
  }

  /// The turn's raising is over: AUTO ALL ends with it, and so does a tap's hurry.
  public mutating func turnEnded() {
    turn = false
    hurry = false
  }

  mutating func hurryUp() { hurry = true }
}

/// One watched raise of the need on the screen: the kubb lies `lie` s, tips up onto end
/// `i` over `tip` s (the hand drag's tip, `RaiseTouch.tilt`), stands `hold` s, then the
/// board moves on. `pending`: the action not yet sent (this device's automatic raise),
/// sent as the kubb starts to tip; nil when it is already applied (another member's raise
/// arriving online).
struct RaiseShow {
  let i: Int?
  var pending: String?
  var age = 0.0
  let lie, tip, hold: Double
  var total: Double { lie + tip + hold }

  /// The parts of a kubb's step: lying, tipping, standing.
  static let parts = (lie: 0.3, tip: 0.5, hold: 0.2)

  init(i: Int?, pending: String?, step: Double, lies: Bool = true) {
    self.i = i
    self.pending = pending
    lie = lies ? step * Self.parts.lie : 0
    tip = step * Self.parts.tip
    hold = step * Self.parts.hold
  }

  /// How far up the kubb is: 0 lying, 1 standing; under Reduce Motion it stands at once
  /// when its lying is done, with no tip between.
  func up(reduced: Bool) -> Double {
    if age < lie { return 0 }
    if reduced || tip <= 0 { return 1 }
    return min(1, (age - lie) / tip)
  }
}

/// Kubbs the engine stood up with no raise of this device's to show (the computer's own
/// raises, or every raise in a match whose Raising is Automatic): seen the same way after
/// the throw that sent them there, one after another, each in the raise scene (or where it
/// lies in the watcher's wide view), before the board moves on.
struct StoodShow {
  struct Kubb {
    let id: String
    /// Lying where the throw left it, and standing where the engine put it, in the show's
    /// frame.
    let lying, standing: Piece
    /// From its middle toward the end it stands on, on the ground (unit).
    let toward: V2
    /// Its two ends' footprints, the one it stands on first.
    let ends: [V2]
  }
  var kubbs: [Kubb]
  /// The pieces as the throw left them, in the show's frame.
  let before: [Piece]
  /// The view the board takes when the show ends.
  let after: ViewOutput
  var k = 0
  var age = 0.0
  let lie, tip, hold: Double
  /// Seen in place (the watcher's wide view): no camera of its own.
  let inPlace: Bool
  var total: Double { lie + tip + hold }

  init(kubbs: [Kubb], before: [Piece], after: ViewOutput, inPlace: Bool) {
    self.kubbs = kubbs
    self.before = before
    self.after = after
    self.inPlace = inPlace
    let step = Pacing.raiseStep(kubbs.count)
    lie = step * RaiseShow.parts.lie
    tip = step * RaiseShow.parts.tip
    hold = step * RaiseShow.parts.hold
  }

  func up(reduced: Bool) -> Double {
    if age < lie { return 0 }
    if reduced || tip <= 0 { return 1 }
    return min(1, (age - lie) / tip)
  }

  /// A lying kubb tipped `t` up onto the end `toward` points to, pivoting on that end's
  /// bottom edge (RaiseTouch.tilt for a pose the engine gave as pieces).
  static func tilt(_ k: Kubb, t: Double) -> Piece {
    guard t > 0 else { return k.lying }
    if t >= 1 { return k.standing }
    let u = k.toward
    let th = t * .pi / 2
    let q = simd_quatd(angle: th, axis: V3(-u.y, u.x, 0)) * k.lying.rotation
    let hl = RaiseTouch.halfLength, hs = RaiseTouch.halfSide
    let px = k.lying.x + u.x * hl, py = k.lying.y + u.y * hl
    let a = -hl * cos(th) + hs * sin(th)
    var p = k.lying
    p.x = px + u.x * a
    p.y = py + u.y * a
    p.z = hl * sin(th) + hs * cos(th)
    (p.qw, p.qx, p.qy, p.qz) = (q.real, q.imag.x, q.imag.y, q.imag.z)
    return p
  }

  /// The kubbs that went from lying (`before`, as the throw left them) to standing
  /// (`after`'s items), in the frame where they lie in the near half (the raising side's,
  /// whose raise scene looks at them from its own baseline). `turnBefore`: the throw's
  /// pieces are in the other side's frame from the view's. nil when none stood.
  static func of(before: [Piece], after: ViewOutput, turnBefore: Bool, inPlace: Bool) -> StoodShow? {
    var was = before
    if turnBefore { was = was.map(NeighbourField.halfTurned) }
    let byId = Dictionary(was.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var stood: [(lying: Piece, standing: Piece)] = []
    for q in after.items where q.kind == "kubb" && !Neon.lying(q) {
      // a kubb stood where it lay (a raise; one put somewhere else, a punishment kubb the
      // engine placed, just appears there)
      guard let p = byId[q.id], Neon.lying(p), simd_distance(V2(p.x, p.y), V2(q.x, q.y)) < 0.5 else { continue }
      stood.append((p, q))
    }
    guard !stood.isEmpty else { return nil }
    // the raising side's frame: the kubbs in its own half (y under 4); the wide view's
    // world frame stays as it is
    let turn = !inPlace && stood.map(\.standing.y).reduce(0, +) / Double(stood.count) > 4
    func framed(_ p: Piece) -> Piece { turn ? NeighbourField.halfTurned(p) : p }
    let kubbs = stood.map { pair -> Kubb in
      let lying = framed(pair.lying), standing = framed(pair.standing)
      let axis3 = lying.rotation.act(V3(0, 0, 1))
      var u = simd_length(V2(axis3.x, axis3.y)) > 1e-6 ? simd_normalize(V2(axis3.x, axis3.y)) : V2(1, 0)
      let off = RaiseTouch.halfLength + RaiseTouch.halfSide
      let a = V2(lying.x, lying.y) + u * off, b = V2(lying.x, lying.y) - u * off
      let s = V2(standing.x, standing.y)
      if simd_distance(b, s) < simd_distance(a, s) { u = -u }
      let first = V2(lying.x, lying.y) + u * off, other = V2(lying.x, lying.y) - u * off
      return Kubb(id: pair.standing.id, lying: lying, standing: standing, toward: u, ends: [first, other])
    }
    return StoodShow(kubbs: kubbs, before: was.map(framed), after: after, inPlace: inPlace)
  }
}

extension PitchSession {
  /// The menu's Raising for this match: every kubb of this device's raised by the
  /// engine's choice, until BY HAND or the match ends.
  public var raiseAutomatically: Bool {
    get { autoRaise.game }
    set {
      autoRaise.setGame(newValue)
      revision += 1
    }
  }
  /// AUTO ALL is raising this turn's kubbs.
  public var raisingRest: Bool { autoRaise.turn }
  /// This device has been asked to raise in this match (or chose Automatic).
  public var raiseSeen: Bool { autoRaise.seen || autoRaise.game }
  /// A raise is being watched (a kubb tipping up, or the computer's raises after a throw):
  /// the board is busy until it ends, as it is while a throw plays.
  public var raiseShowing: Bool { raiseShow != nil || stoodShow != nil }

  /// This device's raise, with no card over it.
  var raiseIsOurs: Bool {
    acceptsInput && !playing && handoff == nil && need?.kind == "raise" && need?.cpu != true
      && raiseShow == nil
  }

  /// AUTO ALL: this kubb and the rest of this turn's, by the engine's choice.
  public func raiseRest() {
    guard raiseIsOurs else { return }
    autoRaise.restOfTurn()
    revision += 1
  }

  /// BY HAND: back to choosing the ends.
  public func raiseByHand() {
    autoRaise.setGame(false)
    revision += 1
  }

  /// AUTO: this kubb, by the engine's choice, watched as it tips up (no lying first: the
  /// player is looking at it).
  public func raiseWatched() throws {
    guard raiseIsOurs else { return }
    try startRaiseShow(lies: false)
  }

  /// A tap during a watched raise: the rest of it at once. This kubb's action goes now and
  /// every later one of this turn's automatic raise as soon as it can (online, as soon as
  /// the last has landed), each still the same action in the same order; the computer's
  /// raises after a throw are skipped to the board's next view.
  public func skipRaise() throws {
    if raiseShow != nil {
      autoRaise.hurryUp()
      _ = try raiseShowTick(0)
    } else if var s = stoodShow {
      s.k = s.kubbs.count
      stoodShow = s
      _ = try stoodShowTick(0)
    }
  }

  /// The end the engine stands this need's kubb on when no end is named: its `default`
  /// choice's end, an index into `ends`.
  func defaultEnd(_ n: MatchNeed) -> Int? {
    guard let d = n.default, let choices = n.choices, choices.indices.contains(d - 1) else { return nil }
    let which = choices[d - 1].which
    return n.ends?.firstIndex { $0.which == which }
  }

  /// The end a `raise` action stands the board's need's kubb on (its choice, else the
  /// engine's default), or nil when it is not a raise of this need.
  public func raiseEnd(of action: JSONText) -> Int? {
    guard let n = need, n.kind == "raise", let node = try? JSONNode.parse(action.text),
      node["type"]?.string == "raise"
    else { return nil }
    if let c = node["choice"]?.int, let choices = n.choices, choices.indices.contains(c - 1) {
      let which = choices[c - 1].which
      return n.ends?.firstIndex { $0.which == which }
    }
    return defaultEnd(n)
  }

  /// The kubbs still to raise this turn, this one among them.
  private var raisesLeft: Int {
    guard let n = need else { return 1 }
    return max(1, (n.of ?? 1) - (n.n ?? 1) + 1)
  }

  private func startRaiseShow(lies: Bool) throws {
    guard let n = need else { return }
    raiseShow = RaiseShow(
      i: defaultEnd(n), pending: #"{"type":"raise"}"#, step: autoRaise.hurry ? 0 : Pacing.raiseStep(raisesLeft),
      lies: lies)
    // one line for the whole of it, not a line a kubb: once when this turn's automatic
    // raising starts, or for AUTO's one kubb
    let run = "\(n.turn ?? 0):\(n.side ?? "")"
    if !autoRaise.on || raiseRun != run {
      raiseRun = autoRaise.on ? run : nil
      announce(
        autoRaise.on && raisesLeft > 1 ? "Raising \(raisesLeft) kubbs automatically." : "Raising the kubb automatically.")
    }
    _ = try raiseShowTick(0)
  }

  /// Another member's raise, already applied to this board's engine (OnlinePitch): its
  /// kubb tips up onto end `i` before the board moves on, at the sender's pace with no
  /// lying first (it lay while the sender chose).
  public func watchRaise(end i: Int?) throws {
    raiseShow = RaiseShow(i: i, pending: nil, step: Pacing.raiseStep(raisesLeft), lies: false)
    _ = try raiseShowTick(0)
  }

  /// A VoiceOver line for the app to say once.
  func announce(_ text: String) {
    raiseNews = (raiseNewsCount + 1, text)
    raiseNewsCount += 1
  }

  func raiseShowTick(_ dt: Double) throws -> Bool {
    guard var s = raiseShow else { return false }
    s.age += autoRaise.hurry ? s.total + 1 : dt
    if let action = s.pending, s.age >= s.lie {
      s.pending = nil
      let response: PlacementCheck = try read("apply", action)
      guard response.ok else {
        raiseShow = nil
        placement = response
        autoRaise.refused()
        resetRaiseTouch()
        try settleScene()
        revision += 1
        return true
      }
      try committed(JSONText(action))
    }
    if s.age >= s.total {
      raiseShow = nil
      resetRaiseTouch()
      try adopt(read("view"))
      return true
    }
    raiseShow = s
    let t = s.up(reduced: reduceMotion)
    if let i = s.i, t > 0 {
      raiseDragging = RaiseTouch.Drag(i: i, t: t)
      raiseSelected = i
    }
    try settleScene()
    revision += 1
    return true
  }

  /// After a throw has played: the kubbs the engine stood up with it (the computer's
  /// raises, or a match raising automatically), watched before `view` is taken. False
  /// when none stood (the caller adopts `view`).
  func beginStoodShow(before: [Piece], view: ViewOutput) -> Bool {
    guard need != nil, view.need.kind != "raise" else { return false }
    let turn = !scene.wide && scene.frameSide != nil && viewFrame(of: view.need) != scene.frameSide
    guard let show = StoodShow.of(before: before, after: view, turnBefore: turn, inPlace: scene.wide) else {
      return false
    }
    stoodShow = show
    let who = view.need.teams?[show.kubbs.count > 0 ? raisingSide(show, view) : "A"] ?? "The other side"
    announce("\(who) stood \(show.kubbs.count == 1 ? "a kubb" : "\(show.kubbs.count) kubbs") up.")
    _ = try? stoodShowTick(0)
    return true
  }

  /// The side whose half the stood kubbs are in (in the view's frame, its own half is
  /// under 4 m for the side the view belongs to).
  private func raisingSide(_ s: StoodShow, _ v: ViewOutput) -> String {
    let viewSide = viewFrame(of: v.need) ?? "A"
    let y = v.items.filter { k in s.kubbs.contains { $0.id == k.id } }.map(\.y)
    let near = (y.reduce(0, +) / Double(max(1, y.count))) < 4
    return near ? viewSide : (viewSide == "A" ? "B" : "A")
  }

  func stoodShowTick(_ dt: Double) throws -> Bool {
    guard var s = stoodShow else { return false }
    s.age += dt
    if s.age >= s.total, s.k < s.kubbs.count {
      s.k += 1
      s.age = 0
    }
    if s.k >= s.kubbs.count {
      stoodShow = nil
      try adopt(s.after)
      return true
    }
    stoodShow = s
    let k = s.kubbs[s.k]
    let t = s.up(reduced: reduceMotion)
    var items = s.before.filter { p in !s.kubbs.contains { $0.id == p.id } }
    for (j, other) in s.kubbs.enumerated() where j != s.k {
      items.append(j < s.k ? other.standing : other.lying)
    }
    items.append(StoodShow.tilt(k, t: t))
    scene.items = items
    scene.arc = nil
    scene.marker = nil
    scene.thrower = nil
    scene.advantageY = nil
    scene.kidY = nil
    scene.keepOut = nil
    if !s.inPlace {
      let lying = k.lying
      camera = RaiseCamera.camera(x: lying.x, y: lying.y, axis: k.toward)
      scene.stillZoom = RaiseCamera.zoom
      scene.focusX = nil
      scene.stillLowest = nil
      scene.footprints = k.ends.enumerated().map { j, e in
        GroundMark(x: e.x, y: e.y, angle: atan2(k.toward.y, k.toward.x), allowed: true, chosen: j == 0 && t >= 0.5)
      }
    }
    revision += 1
    return true
  }

  func autoRaiseTick(_ dt: Double) throws -> Bool {
    if need?.kind == "over" {
      autoRaise = AutoRaise()
      return false
    }
    if need?.kind != "raise" { autoRaise.turnEnded() }
    let raising = raiseIsOurs ? "\(need?.turn ?? 0):\(need?.kubb ?? ""):\(need?.n ?? 0)" : nil
    guard autoRaise.tick(dt, raising: raising) else { return false }
    try startRaiseShow(lies: true)
    return true
  }
}
