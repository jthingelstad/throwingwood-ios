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
/// kubbs you should watch the computer raise them."; the web's lift.js): the first kubb of
/// the turn's lies a moment in the raise scene, then each tips up onto the end the engine
/// chose with the hand drag's tip, stands a moment, and the next follows (`RaiseShow`, `RaisePace`, `Pacing.raiseBeat`). The engine's actions and their
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

/// The pace of a watched raise (the web's lift.js): the first kubb of a turn's automatic
/// raise lies `lead` s, then each kubb takes a beat (its tip `tipOf` of it, eased, then it
/// stands; a kubb a crowded raise moved slides to its spot in half the rest).
enum RaisePace {
  static let tipOf = 0.7
  /// m: a kubb standing farther than this from the footprint it tipped onto slides there.
  static let displaced = 0.3
  /// Each waiting action makes an arriving raise run this much faster (online).
  static let catchUp = 2.0

  static func ease(_ u: Double) -> Double {
    let t = max(0, min(1, u))
    return t * t * (3 - 2 * t)
  }

  /// How far up at `age` s into a clip of `lead` and `beat`: 0 lying, 1 standing. Under
  /// Reduce Motion: no tip, lying for the first half of the beat and standing for the second.
  static func up(age: Double, lead: Double, beat: Double, reduced: Bool) -> Double {
    if age < lead { return 0 }
    if reduced { return age - lead < beat / 2 ? 0 : 1 }
    let tip = beat * tipOf
    return tip <= 0 ? 1 : ease((age - lead) / tip)
  }

  /// How far it has slid from the footprint to where the engine stood it (0 to 1).
  static func slid(age: Double, lead: Double, beat: Double) -> Double {
    let tip = beat * tipOf
    let rest = (beat - tip) / 2
    return rest <= 0 ? 1 : ease((age - lead - tip) / rest)
  }
}

/// One watched raise of the need on the screen: the kubb lies `lead` s (the first of a
/// turn's automatic raise), tips up onto end `i` (the hand drag's tip, `RaiseTouch.tilt`),
/// stands and, if the engine put it elsewhere (`final`), slides there, then the board
/// moves on. `pending`: the action not yet sent (this device's automatic raise), sent as
/// the kubb starts to tip; nil when it is already applied (another member's raise
/// arriving online).
struct RaiseShow {
  let i: Int?
  /// This device's own automatic raise (else another member's, arriving online).
  let own: Bool
  var pending: String?
  var age = 0.0
  let lead, beat: Double
  /// Where the engine stands it (the choice's pose), when that is away from the footprint.
  let final: MatchNeed.Pose?
  var total: Double { lead + beat }

  init(i: Int?, pending: String?, lead: Double, beat: Double, final: MatchNeed.Pose? = nil, own: Bool? = nil) {
    self.i = i
    self.own = own ?? (pending != nil)
    self.pending = pending
    self.lead = lead
    self.beat = beat
    self.final = final
  }

  func up(reduced: Bool) -> Double { RaisePace.up(age: age, lead: lead, beat: beat, reduced: reduced) }
}

/// Kubbs the engine stood up with no raise of this device's to show (the computer's own
/// raises, every raise in a match whose Raising is Automatic) and the punishment kubbs it
/// placed: seen the same way after the throw that sent them there, one after another in
/// the order done, each in the raise scene with the watched raise's tip and pace, before
/// the board moves on (the web's lift.js settledClips). Built only from the engine's own
/// list (engine 0.16.0's `setup.settled`, `engineRaised`), every pose in the frame it gives.
struct StoodShow {
  struct Kubb {
    let id: String
    /// Lying where the throw left it, and standing where the engine put it, both in the
    /// frame the raise view draws in, as the engine gives them.
    let lying, standing: Piece
    /// From its middle toward the end it stands on, on the ground (unit): the lying pose's
    /// own axis, end 1 the +axis end and end 2 the -axis end (core/raising), in its frame.
    let toward: V2
    /// A punishment kubb the engine placed: not on the pitch before its turn.
    var placed = false
    /// The side whose view frame its poses are in ("A" for the world frame).
    var frame: String? = nil
    /// The pitch round it in its own frame, where the engine gives it (the entry's `others`
    /// and `king`, from its next release); nil: the show's `before`.
    var around: [Piece]? = nil
  }
  var kubbs: [Kubb]
  /// The pitch round them, in the same frame (the king alone in the thrower's view).
  let before: [Piece]
  /// The view the board takes when the show ends.
  let after: ViewOutput
  var k = 0
  var age = 0.0
  /// The first kubb lies `Pacing.autoRaiseWait` s; each then takes `beat`.
  let beat: Double
  var lead: Double { k == 0 ? Pacing.autoRaiseWait : 0 }
  var total: Double { lead + beat }

  init(kubbs: [Kubb], before: [Piece], after: ViewOutput) {
    self.kubbs = kubbs
    self.before = before
    self.after = after
    beat = Pacing.raiseBeat(kubbs.count)
  }

  func up(reduced: Bool) -> Double { RaisePace.up(age: age, lead: lead, beat: beat, reduced: reduced) }

  /// The kubb at this moment (the web's liftKubb): lying, tipping onto its end, then
  /// standing, sliding from the footprint it tipped onto to where the engine stood it in
  /// half the beat's rest, and settling into its seat over the same (engine 1.0.0's
  /// `seat`: it ends as the next throw's first frame draws it, so nothing steps).
  func shown(reduced: Bool) -> Piece {
    let kb = kubbs[k]
    let t = up(reduced: reduced)
    guard t >= 1 else { return Self.tilt(kb, t: t) }
    if reduced { return kb.standing }
    let top = Self.tilt(kb, t: 1)
    let u = RaisePace.slid(age: age, lead: lead, beat: beat)
    var p = kb.standing
    p.x = top.x + (kb.standing.x - top.x) * u
    p.y = top.y + (kb.standing.y - top.y) * u
    p.z = top.z + (kb.standing.z - top.z) * u
    let q = simd_slerp(top.rotation, kb.standing.rotation, u)
    (p.qw, p.qx, p.qy, p.qz) = (q.real, q.imag.x, q.imag.y, q.imag.z)
    return p
  }

  /// A standing kubb at `seat` (engine 1.0.0): that orientation, resting on its lowest
  /// corner as the engine rests it (core/world addPiece, `-lowestZ`).
  static func seated(_ p: Piece, _ seat: MatchNeed.Settled.Seat?) -> Piece {
    guard let seat else { return p }
    var out = p
    let q = simd_normalize(simd_quatd(ix: seat.qx, iy: seat.qy, iz: seat.qz, r: seat.qw))
    (out.qw, out.qx, out.qy, out.qz) = (q.real, q.imag.x, q.imag.y, q.imag.z)
    // the world z of each body axis, times its half extent
    let ax = q.act(V3(1, 0, 0)).z, ay = q.act(V3(0, 1, 0)).z, az = q.act(V3(0, 0, 1)).z
    out.z = RaiseTouch.halfSide * (abs(ax) + abs(ay)) + RaiseTouch.halfLength * abs(az)
    return out
  }

  /// The pieces at this moment: the pitch round the kubb, the list's kubbs done standing
  /// and those to come lying (a punishment kubb is not there before it is placed), and
  /// the kubb itself.
  func items(reduced: Bool) -> [Piece] {
    let kb = kubbs[k]
    let ids = Set(kubbs.map(\.id))
    var items = (kb.around ?? before).filter { !ids.contains($0.id) }
    for (j, other) in kubbs.enumerated() where j != k {
      if j < k {
        items.append(other.standing)
      } else if !other.placed {
        items.append(other.lying)
      }
    }
    items.append(shown(reduced: reduced))
    return items
  }

  /// A lying kubb tipped `t` up onto the end `toward` points to, pivoting on that end's
  /// bottom edge (RaiseTouch.tilt for a pose the engine gave as pieces); at 1 it stands
  /// on that end's footprint.
  static func tilt(_ k: Kubb, t: Double) -> Piece {
    guard t > 0 else { return k.lying }
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

  /// VoiceOver's one line for the show: "2 kubbs stood up.", "A punishment kubb placed.",
  /// "A kubb stood up and a punishment kubb placed."
  static func news(stood: Int, placed: Int) -> String {
    func count(_ n: Int, _ what: String) -> String { n == 1 ? "a \(what)" : "\(n) \(what)s" }
    var parts: [String] = []
    if stood > 0 { parts.append("\(count(stood, "kubb")) stood up") }
    if placed > 0 { parts.append("\(count(placed, "punishment kubb")) placed") }
    let line = parts.joined(separator: " and ")
    return line.prefix(1).uppercased() + line.dropFirst() + "."
  }

  /// The raises the engine made itself and the punishment kubbs it placed before this
  /// throw (the computer's own, every raise of a match started with Raising: Automatic),
  /// as clips, from the view's `need.setup.settled` (engine 0.16.0): each kubb's id, the
  /// end it stands on and its lying and standing poses (a punishment kubb's one pose) in
  /// the raiser's view frame, or the world frame in the wide view. The app never turns a
  /// pose from one frame into another, or compares the pitch before and after, to find
  /// them. Round them (`others`): the view's items where the view and the list are both
  /// the world's (the wide view), else the king alone, who stands on the pitch's centre in
  /// either frame (the web's settledLifts), until the engine gives each entry its own.
  /// nil when there is none (and after a restore: the kubbs already stand).
  static func engineRaised(_ view: ViewOutput, wide: Bool = false) -> (kubbs: [Kubb], others: [Piece])? {
    guard view.need.kind == "throw", let list = view.need.setup?.settled?.list, !list.isEmpty else { return nil }
    let world = wide && list.allSatisfy { $0.frame == "world" }
    var kubbs: [Kubb] = []
    for e in list {
      let frame = e.frame == "world" ? "A" : e.side
      var around: [Piece]? = nil
      if e.others != nil || e.king != nil {
        around = (e.others ?? []).map { $0.pose.piece(id: $0.id) } + (e.king.map { [$0.piece(id: "king", king: true)] } ?? [])
      }
      switch e.kind {
      case "raise":
        guard let l = e.lying, let st = e.standing else { continue }
        let a = l.angle ?? 0
        let sign = e.which == 2 ? -1.0 : 1.0
        kubbs.append(
          Kubb(
            id: e.id, lying: MatchNeed.Pose(x: l.x, y: l.y, angle: l.angle, standing: false).piece(id: e.id),
            standing: Self.seated(
              MatchNeed.Pose(x: st.x, y: st.y, angle: st.angle, standing: true).piece(id: e.id), e.seat),
            toward: V2(cos(a), sin(a)) * sign, frame: frame, around: around))
      case "punish":
        guard let p = e.pose else { continue }
        let a = p.angle ?? 0
        kubbs.append(
          Kubb(
            id: e.id, lying: MatchNeed.Pose(x: p.x, y: p.y, angle: p.angle, standing: false).piece(id: e.id),
            standing: Self.seated(
              MatchNeed.Pose(x: p.x, y: p.y, angle: p.angle, standing: true).piece(id: e.id), e.seat),
            toward: V2(cos(a), sin(a)), placed: true, frame: frame, around: around))
      default: continue
      }
    }
    guard !kubbs.isEmpty else { return nil }
    let others = world ? view.items : view.items.filter { $0.id == "king" }
    return (kubbs, others)
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
  /// The engine's own raises being watched: how far through, 0 to 1 of the whole show (its
  /// first kubb's lying included); nil when none is (review tools).
  public var engineRaiseProgress: Double? {
    guard let s = stoodShow else { return nil }
    let total = Pacing.autoRaiseWait + s.beat * Double(s.kubbs.count)
    // the first kubb's age runs through its lying; each later one's from its own start
    let done = s.k == 0 ? s.age : Pacing.autoRaiseWait + s.beat * Double(s.k) + s.age
    return min(1, done / total)
  }
  /// The engine's own raise being watched now: the kubb's place in the list (one-based),
  /// the list's length, the side that raised it and whether it is a punishment kubb placed
  /// (the header's words, `HeaderWords.engineRaise`); nil when none is.
  public var engineRaising: (k: Int, of: Int, side: String?, placed: Bool)? {
    guard let s = stoodShow, s.kubbs.indices.contains(s.k) else { return nil }
    let kb = s.kubbs[s.k]
    let side = s.after.need.setup?.settled?.list?.first { $0.id == kb.id }?.side
    return (s.k + 1, s.kubbs.count, side, kb.placed)
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
    guard let n0 = need, n0.kind == "raise", let node = try? JSONNode.parse(action.text),
      node["type"]?.string == "raise"
    else { return nil }
    // engine 1.4.0: the raise names its kubb (any order) and the end by `which`; the
    // watched raise is drawn on that kubb
    let n = n0.picking(node["kubb"]?.string)
    if let id = node["kubb"]?.string, n.kubb == id { raisePicked = id }
    if let which = node["which"]?.int { return n.ends?.firstIndex { $0.which == which } }
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
    // the engine's choice raises its own first kubb
    raisePicked = nil
    guard let n = need else { return }
    // the first kubb of this turn's automatic raise lies a moment first, and its one line
    // for VoiceOver is said then, not a line a kubb (AUTO's one kubb: no lying, one line)
    let run = "\(n.turn ?? 0):\(n.side ?? "")"
    let first = !autoRaise.on || raiseRun != run
    if first {
      raiseRun = autoRaise.on ? run : nil
      announce(
        autoRaise.on && raisesLeft > 1 ? "Raising \(raisesLeft) kubbs automatically." : "Raising the kubb automatically.")
    }
    let hurry = autoRaise.hurry
    raiseCatchUp = 0
    raiseShow = RaiseShow(
      i: defaultEnd(n), pending: #"{"type":"raise"}"#,
      lead: hurry || !lies || !first ? 0 : Pacing.autoRaiseWait,
      beat: hurry ? 0 : Pacing.raiseBeat(n.of ?? 1), final: finalPose(n, choice: nil))
    _ = try raiseShowTick(0)
  }

  /// Where the engine stands the need's kubb for `choice` (one-based, nil: its default).
  func finalPose(_ n: MatchNeed, choice: Int?) -> MatchNeed.Pose? {
    guard let choices = n.choices, let c = choice ?? n.default, choices.indices.contains(c - 1) else { return nil }
    return choices[c - 1].pose
  }

  /// Another member's raise, already applied to this board's engine (OnlinePitch): its
  /// kubb tips up onto end `i` before the board moves on, at the sender's pace with no
  /// lying first (it lay while the sender chose).
  public func watchRaise(end i: Int?, choice: Int? = nil, which: Int? = nil) throws {
    let final = raiseNeed.flatMap { n in
      which.map { w in n.choices?.first { $0.which == w }?.pose } ?? finalPose(n, choice: choice)
    }
    raiseShow = RaiseShow(i: i, pending: nil, lead: 0, beat: Pacing.raiseBeat(need?.of ?? 1), final: final)
    _ = try raiseShowTick(0)
  }

  /// Actions waiting behind a watched raise (OnlinePitch): each makes it run
  /// `RaisePace.catchUp` times faster more, so a watcher keeps up.
  public var actionsWaiting: Int {
    get { raiseCatchUp }
    set { raiseCatchUp = newValue }
  }

  /// A VoiceOver line for the app to say once.
  func announce(_ text: String) {
    raiseNews = (raiseNewsCount + 1, text)
    raiseNewsCount += 1
  }

  func raiseShowTick(_ dt: Double) throws -> Bool {
    guard var s = raiseShow else { return false }
    s.age += autoRaise.hurry ? s.total + 1 : dt * (1 + RaisePace.catchUp * Double(raiseCatchUp))
    if let pending = s.pending, s.age >= s.lead {
      s.pending = nil
      let action = stamped(pending)
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
    // standing: from the footprint it tipped onto to where the engine put it (a crowded
    // raise's search moved it), in half the beat's rest
    if t >= 1, !reduceMotion, let f = s.final, let n = raiseNeed, let id = n.kubb, let i = s.i,
      let lying = n.pose.map({ $0.piece(id: id) })
    {
      let top = RaiseTouch.tilt(n, lying: lying, i: i, t: 1)
      if hypot(top.x - f.x, top.y - f.y) > RaisePace.displaced, let j = scene.items.lastIndex(where: { $0.id == id }) {
        let u = RaisePace.slid(age: s.age, lead: s.lead, beat: s.beat)
        scene.items[j].x = top.x + (f.x - top.x) * u
        scene.items[j].y = top.y + (f.y - top.y) * u
      }
    }
    revision += 1
    return true
  }

  /// After a throw has played (or was skipped): the kubbs the engine stood up and placed
  /// before the next (the computer's raises, a match raising automatically, a punishment
  /// kubb it placed), watched before `view` is taken, from the engine's own list in the
  /// frame it gives (`StoodShow.engineRaised`: the raiser's view frame, the world frame in
  /// the watcher's wide view). False when there is none (the caller adopts `view`).
  func beginStoodShow(view: ViewOutput) -> Bool {
    guard need != nil, let raised = StoodShow.engineRaised(view, wide: scene.wide), !raised.kubbs.isEmpty
    else { return false }
    stoodShow = StoodShow(kubbs: raised.kubbs, before: raised.others, after: view)
    let stood = raised.kubbs.filter { !$0.placed }.count, placed = raised.kubbs.count - stood
    announce(StoodShow.news(stood: stood, placed: placed))
    _ = try? stoodShowTick(0)
    return true
  }

  func stoodShowTick(_ dt: Double) throws -> Bool {
    guard var s = stoodShow else { return false }
    s.age += dt
    while s.k < s.kubbs.count, s.age >= s.total {
      s.age -= s.total
      s.k += 1
    }
    if s.k >= s.kubbs.count {
      stoodShow = nil
      try adopt(s.after)
      return true
    }
    stoodShow = s
    let k = s.kubbs[s.k]
    scene.items = s.items(reduced: reduceMotion)
    // drawn in the kubb's own frame (the raiser's, or the world's in the wide view)
    if let f = k.frame { scene.frameSide = f }
    scene.arc = nil
    scene.marker = nil
    scene.thrower = nil
    scene.advantageY = nil
    scene.kidY = nil
    scene.keepOut = nil
    camera = RaiseCamera.camera(x: k.lying.x, y: k.lying.y, axis: k.toward)
    scene.stillZoom = RaiseCamera.zoom
    scene.focusX = nil
    scene.stillLowest = nil
    // no footprints: nothing is chosen, it is watched (the web's settledClips)
    scene.footprints = nil
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
