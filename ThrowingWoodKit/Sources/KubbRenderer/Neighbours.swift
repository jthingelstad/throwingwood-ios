import CoreGraphics
import Foundation
import KubbEngine
import QuartzCore
import simd

// The Tournament's neighbouring pitches, live (engine 0.15.1, kubb-engine docs/SESSION.md
// "Neighbours", docs/CLIENTS.md "0.15.1 on top"): computer-against-computer matches on the
// pitches round the player's, as scenery. They run on an engine of their own (a second
// Lua state, `Engine.neighbours()`, on a serial queue of their own), never the player's,
// and nothing about them reaches the player's match: its snapshot, actions and hashes.
// No people and no names on the screen; their sounds, quiet and far, are NeighbourSounds.

// ---------- the engine's answers ----------

/// A point in a neighbour's own pitch frame (Team A's: its baseline at y 0, B's at 8).
struct NeighbourPoint: Decodable, Sendable, Equatable {
  let x, y: Double
}

/// A neighbour's team as `open`, `view` and `setup` give it. Its name is never shown.
struct NeighbourTeam: Decodable, Sendable {
  let name: String
  let players: Int
}

/// A neighbour's recording: the session's cut to what a far pitch needs (only the bodies
/// that moved, integer poses at `poseScale`, no items, cameras or ruling).
struct NeighbourRecording: Decodable, Sendable {
  struct Body: Decodable, Sendable {
    let id, kind: String
    let team: String?
    let start, frames: Int
    let poses: [Int]
    /// s into the throw a kubb or the king went over (none: it did not).
    var toppleT: Double? = nil
  }
  struct Projectile: Decodable, Sendable { let id, kind: String }
  let frameDt, duration, poseScale: Double
  let projectile: Projectile
  let bodies: [Body]

  /// The session's `Recording` this plays as through `Playback`: the pitch's current
  /// `items` in place of the recording's, and the thrown piece (not among them) added at
  /// its first pose. No timeline, so no feedback of the player's: the neighbours' own quiet
  /// sounds come from the recording itself (NeighbourSounds.cues).
  func recording(items: [Piece]) -> Recording {
    var all = items
    let have = Set(items.map(\.id))
    for b in bodies where !have.contains(b.id) && b.poses.count >= 7 {
      let d = b.poses, s = poseScale
      all.append(
        Piece(
          id: b.id, kind: b.kind, team: b.team, x: Double(d[0]) / s, y: Double(d[1]) / s, z: Double(d[2]) / s,
          qw: Double(d[3]) / s, qx: Double(d[4]) / s, qy: Double(d[5]) / s, qz: Double(d[6]) / s))
    }
    return Recording(
      projectile: Recording.Projectile(id: projectile.id), frameDt: frameDt, duration: duration,
      poseScale: poseScale, items: all,
      bodies: bodies.map { Recording.Body(id: $0.id, start: $0.start, frames: $0.frames, poses: $0.poses) },
      timeline: Recording.Timeline(bursts: [], touches: nil, contacts: nil, batonLanding: nil, impacts: nil),
      result: ThrowResult(flag: nil, restText: nil, verdicts: nil, ruling: nil))
  }
}

/// A pitch as `open` and `view` give it.
struct NeighbourPitchState: Decodable, Sendable {
  let id: Int
  let offset: NeighbourPoint
  let teams: [String: NeighbourTeam]?
  let phase: String
  let at: Double
  let items: [Piece]
  let recording: NeighbourRecording?
  let side, kind: String?
  let from: NeighbourPoint?
}

/// `neighbours.open`'s answer.
struct NeighbourOpening: Decodable, Sendable {
  let pitches: [NeighbourPitchState]
  let seed, count: Int
  let stakes: [NeighbourPoint]
  let now: Double
}

/// A beat on one pitch (`advance`'s events), in time order.
struct NeighbourEvent: Decodable, Sendable {
  let id: Int
  let phase: String
  let at: Double
  let side, kind: String?
  let from: NeighbourPoint?
  let recording: NeighbourRecording?
  let items: [Piece]?
  let teams: [String: NeighbourTeam]?
  let winner: String?
}

/// `neighbours.advance`'s answer.
struct NeighbourAdvance: Decodable, Sendable {
  struct Used: Decodable, Sendable { let ms: Double?, steps: Int? }
  let now: Double
  let events: [NeighbourEvent]
  let used: Used
  let late: Int
}

// ---------- the field as the screen keeps it ----------

/// The live neighbours as the screen holds them: each pitch's items (replaced by a beat
/// that carries them, a throw's recording played over them and its last poses kept), and
/// the last beat. Equal to `neighbours.view` after every call (the engine's tests prove
/// the model; `NeighbourTests` holds this one to it). No people (the owner, 2026-11-22:
/// "Tournament mode should not have people. Just pitches with live play."): the pieces
/// move as if by unseen hands, calmly. A thrown piece shows once it is in the air
/// (`Calm.airborne` from where it left), and kubbs a beat stands up (a raise, a fresh
/// pitch set out) rise over `Calm.rise` s one after another rather than pop.
struct NeighbourField {
  struct Live {
    let id: Int
    var offset: NeighbourPoint
    var items: [Piece]
    var teams: [String: NeighbourTeam]
    var phase: String
    var at: Double
    /// The throw playing: its playback and when it left the hand.
    var playing: (playback: Playback, at: Double)? {
      didSet { launch = playing.flatMap { Calm.launch($0.playback) } }
    }
    /// Where the thrown piece left from (its first pose): it is drawn once it is clear of it.
    private(set) var launch: V3?
    var from: NeighbourPoint?, side: String?, kind: String?
    var winner: String?
    /// Pieces rising, by id: the pose they rise from and when they start.
    var rises: [String: (from: Piece, at: Double)] = [:]
    /// The throw's sounds (NeighbourSounds), on the field's clock.
    var cues: [NeighbourCue] = []

    /// A throw from `r`, over `items`, left the hand at `at`.
    mutating func play(_ r: NeighbourRecording, at: Double) {
      playing = (Playback(r.recording(items: items)), at)
      cues = NeighbourSounds.cues(r, at: at)
    }

    init(id: Int, offset: NeighbourPoint, items: [Piece], teams: [String: NeighbourTeam], phase: String, at: Double) {
      self.id = id
      self.offset = offset
      self.items = items
      self.teams = teams
      self.phase = phase
      self.at = at
    }
  }
  var pitches: [Live] = []
  var stakes: [NeighbourPoint] = []

  init() {}

  init(_ o: NeighbourOpening) {
    stakes = o.stakes
    pitches = o.pitches.map { p in
      var live = Live(
        id: p.id, offset: p.offset, items: p.items, teams: p.teams ?? [:], phase: p.phase, at: p.at)
      if let r = p.recording {
        live.play(r, at: p.at)
        (live.from, live.side, live.kind) = (p.from, p.side, p.kind)
      }
      return live
    }
  }

  /// A pitch put back as `view` gives it (one coming into view, or after a pause).
  mutating func replace(_ p: NeighbourPitchState) {
    guard let i = pitches.firstIndex(where: { $0.id == p.id }) else { return }
    var live = Live(
      id: p.id, offset: p.offset, items: p.items, teams: p.teams ?? pitches[i].teams, phase: p.phase, at: p.at)
    if let r = p.recording {
      live.play(r, at: p.at)
      (live.from, live.side, live.kind) = (p.from, p.side, p.kind)
    }
    pitches[i] = live
  }

  /// The beats of an `advance`, in order.
  mutating func apply(_ events: [NeighbourEvent]) {
    for e in events {
      guard let i = pitches.firstIndex(where: { $0.id == e.id }) else { continue }
      var p = pitches[i]
      // a beat after a throw: the recording has played out by now, its last poses kept
      finish(&p)
      if e.phase == "throw", let r = e.recording {
        p.play(r, at: e.at)
        (p.from, p.side, p.kind) = (e.from, e.side, e.kind)
        p.rises = [:]
      }
      if let items = e.items {
        p.rises = Calm.rises(from: p.items, to: items, at: e.at)
        p.items = items
      }
      if let teams = e.teams { p.teams = teams }
      if e.phase == "over" { p.winner = e.winner }
      if e.phase == "setup" { (p.winner, p.from, p.side) = (nil, nil, nil) }
      (p.phase, p.at) = (e.phase, e.at)
      pitches[i] = p
    }
  }

  /// Every throw that has played to its end by `now` leaves its last poses as the items.
  mutating func settle(_ now: Double) {
    for i in pitches.indices {
      if let (pb, at) = pitches[i].playing, now - at >= pb.recording.duration { finish(&pitches[i]) }
      if !pitches[i].rises.isEmpty, !Calm.rising(pitches[i], now) { pitches[i].rises = [:] }
    }
  }

  private func finish(_ p: inout Live) {
    guard let (pb, _) = p.playing else { return }
    p.items = pb.pieces(at: pb.recording.duration)
    p.playing = nil
    p.cues = []
  }

  /// A throw is in the air somewhere, or kubbs are rising: the screen draws again.
  func moving(_ now: Double) -> Bool {
    pitches.contains { Self.moving($0, now) }
  }

  static func moving(_ p: Live, _ now: Double) -> Bool {
    p.playing != nil || Calm.rising(p, now)
  }

  /// What the screen draws at `now`: every pitch at its offset with its pieces (the six
  /// stakes among them), turned half round about the player's pitch centre (0, 4) while
  /// the player's view is Team B's (`turned`).
  func drawn(at now: Double, turned: Bool) -> [NeighbourPitch] {
    pitches.map { p in
      var pieces: [Piece]
      if let (pb, at) = p.playing {
        pieces = pb.pieces(at: max(0, now - at))
        // the thrown piece shows once it is in the air, clear of the hand no one holds it in
        let id = pb.recording.projectile.id
        if let launch = p.launch {
          pieces.removeAll { $0.id == id && simd_distance($0.center, launch) < Calm.airborne }
        }
      } else {
        pieces = p.items
      }
      if !p.rises.isEmpty {
        pieces = pieces.map { q in p.rises[q.id].map { Calm.risen($0.from, to: q, u: (now - $0.at) / Calm.rise) } ?? q }
      }
      pieces = pieces.filter { $0.kind != "stake" }
      pieces += stakes.enumerated().map { i, s in
        Piece(id: "stake\(i)", kind: "stake", team: nil, x: s.x, y: s.y, z: 0.075, qw: 1, qx: 0, qy: 0, qz: 0)
      }
      var dx = p.offset.x, dy = p.offset.y
      if turned {
        // (ox + x, oy + y) is drawn at (-(ox + x), 8 - (oy + y)): the pitch's origin at
        // (-ox, -oy) and each point (-x, 8 - y) in it, each piece half turned about z
        dx = -dx
        dy = -dy
        pieces = pieces.map(Self.halfTurned)
      }
      return NeighbourPitch(dx: dx, dy: dy, pieces: pieces, score: Self.score(pieces))
    }
  }

  /// A piece turned half round about the pitch's centre (core/frame's point and quat).
  static func halfTurned(_ p: Piece) -> Piece {
    var q = p
    (q.x, q.y) = (-p.x, 8 - p.y)
    // (0, 0, 0, 1) * q: a half turn about z, before the piece's own turn
    (q.qw, q.qx, q.qy, q.qz) = (-p.qz, -p.qy, p.qx, p.qw)
    return q
  }

  /// The scoreboard: the kubbs each side has standing, as the player's own.
  static func score(_ pieces: [Piece]) -> (a: Int, b: Int) {
    func standing(_ team: String) -> Int {
      pieces.filter { $0.kind == "kubb" && $0.team == team && !Neon.lying($0) }.count
    }
    return (standing("A"), standing("B"))
  }
}

/// How the neighbours' pieces move with no one to move them: calmly, as scenery.
enum Calm {
  /// m a thrown piece is from where it left before it is drawn (a baton leaves a hand at
  /// about shoulder height; with no hand drawn it would hang there for a frame or two).
  static let airborne = 0.3
  /// s a kubb takes to rise, and the gap between one and the next (a raise of six takes
  /// 0.5 + 5 x 0.12 = 1.1 s; at most `riseSpan` s from the first to the last start).
  static let rise = 0.5, stagger = 0.12, riseSpan = 1.2

  static func launch(_ pb: Playback) -> V3? {
    pb.pieces(at: 0).first { $0.id == pb.recording.projectile.id }?.center
  }

  /// A kubb or the king standing in `to` that was not standing there in `from` rises:
  /// from its own lying pose where it lay within half a metre (a raise), else from lying
  /// where it now stands (a fresh pitch set out). Batons and lying pieces just change.
  static func rises(from: [Piece], to: [Piece], at: Double) -> [String: (from: Piece, at: Double)] {
    let was = Dictionary(from.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var out: [String: (from: Piece, at: Double)] = [:]
    let up = to.filter { ($0.kind == "kubb" || $0.kind == "king") && !Neon.lying($0) }.filter { q in
      guard let p = was[q.id] else { return true }
      return Neon.lying(p) || simd_distance(p.center, q.center) > 0.05
    }
    let gap = up.count > 1 ? min(stagger, riseSpan / Double(up.count - 1)) : 0
    for (k, q) in up.enumerated() {
      var start = was[q.id].flatMap { Neon.lying($0) && simd_distance($0.center, q.center) < 0.5 ? $0 : nil }
      if start == nil { start = lying(q) }
      out[q.id] = (start!, at + Double(k) * gap)
    }
    return out
  }

  /// A standing piece laid on its side where it stands, its long axis along the pitch.
  static func lying(_ q: Piece) -> Piece {
    var p = q
    let r = simd_quatd(angle: .pi / 2, axis: V3(1, 0, 0)) * q.rotation
    (p.qw, p.qx, p.qy, p.qz) = (r.real, r.imag.x, r.imag.y, r.imag.z)
    p.z = q.kind == "king" ? 0.045 : 0.035
    return p
  }

  /// `from` risen `u` of the way to `to`, eased.
  static func risen(_ from: Piece, to: Piece, u: Double) -> Piece {
    let t = max(0, min(1, u))
    let e = t * t * (3 - 2 * t)
    var p = to
    p.x = from.x + (to.x - from.x) * e
    p.y = from.y + (to.y - from.y) * e
    p.z = from.z + (to.z - from.z) * e
    let q = simd_slerp(from.rotation, to.rotation, e)
    (p.qw, p.qx, p.qy, p.qz) = (q.real, q.imag.x, q.imag.y, q.imag.z)
    return p
  }

  static func rising(_ p: NeighbourField.Live, _ now: Double) -> Bool {
    p.rises.values.contains { now - $0.at < rise }
  }
}

// ---------- the second engine ----------

/// What the neighbours' engine costs, by its own clock on its queue: each `advance` call
/// (the engine's work and its answer's encoding, then the decoding here) in ms.
public struct NeighbourCost: Sendable {
  public internal(set) var calls = 0
  public internal(set) var total = 0.0, worst = 0.0
  /// Every call's ms, for percentiles (the last 20000).
  public internal(set) var samples: [Double] = []
  public var mean: Double { calls == 0 ? 0 : total / Double(calls) }
  public func percentile(_ p: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let s = samples.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
  }
  mutating func add(_ ms: Double) {
    calls += 1
    total += ms
    worst = max(worst, ms)
    if samples.count < 20000 { samples.append(ms) }
  }
}

/// The engine and its results, touched only on the neighbours' queue (the engine) or
/// under the lock (the inbox).
private final class FieldEngine: @unchecked Sendable {
  var engine: Engine?
  let lock = NSLock()
  var inbox: [(generation: Int, result: Result<Answer, Error>)] = []
  var cost = NeighbourCost()
  enum Answer {
    case opened(NeighbourOpening)
    case advanced(NeighbourAdvance)
  }
  func post(_ generation: Int, _ r: Result<Answer, Error>) {
    lock.lock()
    inbox.append((generation, r))
    lock.unlock()
  }
  func take() -> [(generation: Int, result: Result<Answer, Error>)] {
    lock.lock()
    defer { lock.unlock() }
    let out = inbox
    inbox = []
    return out
  }
}

/// The Tournament's neighbours for one screen: a second engine on a serial queue of its
/// own, opened with the match's seed and closed when the match, practice or watched match
/// in the Tournament scene is left (or the app goes to the background), advanced once a
/// frame on the match clock. Nothing here waits on the queue: a call still running when
/// the next frame comes is left to finish, the field stays as it is meanwhile, and a call
/// that fails leaves the neighbours standing; the player's match never sees any of it.
@MainActor public final class TournamentNeighbours {
  /// What the screen wants: the match's seed and the layout. The app always asks for the
  /// grid (the owner: "a grid of pitches that are all live"): the thrower's camera frames
  /// the player's own pitch, so the engine's row for a phone on its side would leave every
  /// neighbour out of the aim. `row` stays for a host that wants it.
  public struct Want: Equatable, Sendable {
    public let seed: Int, row: Bool
    public init(seed: Int, row: Bool = false) {
      self.seed = seed
      self.row = row
    }
  }
  /// The budget of each `advance` (docs/CLIENTS.md: 2 ms keeps eight pitches to about
  /// half a percent of a core).
  public nonisolated static let budgetMs = 2.0

  private let queue = DispatchQueue(label: "throwingwood.neighbours", qos: .utility)
  private let box = FieldEngine()
  /// What is open (nil: nothing), and the open's number: answers of an older one are let go.
  public private(set) var open: Want?
  private var generation = 0
  private var opened = false
  private var pending = false
  private var failed = false
  /// The match clock (s): it moves only while the board ticks, so it stops while the
  /// match is paused (a menu over it) and the neighbours pause with it.
  public private(set) var clock = 0.0
  var field = NeighbourField()
  /// Pitches a beat has changed since the screen last drew them (`needsDraw`).
  private var fresh = Set<Int>()
  /// Frames whose `advance` was left out because the one before was still running.
  public private(set) var skipped = 0
  /// The clock up to which the neighbours' sounds have been taken (`sounds`).
  private var heard = 0.0

  public init() {}

  /// What a screen wants (the app asks each frame and on every change): live neighbours
  /// only in the Tournament scene (`look`, the match's or practice's), only while a match,
  /// a practice or a watched match is on the screen or paused under its menu (`inMatch`),
  /// and never under Reduce Motion (`reduced`: the fixed pitches, and no second engine).
  /// The grid in every layout, upright and on its side.
  public static func want(look: String?, inMatch: Bool, reduced: Bool, seed: @autoclosure () -> Int) -> Want? {
    guard SceneID.shown(look) == "tournament", inMatch, !reduced else { return nil }
    return Want(seed: seed())
  }

  /// The second engine has been made (it is made on the first open, never before).
  public var engineStarted: Bool { queue.sync { box.engine != nil } }

  /// The neighbours' engine itself, on its queue (tests only).
  func onEngine<T>(_ body: (Engine) throws -> T) throws -> T? {
    try queue.sync { try box.engine.map(body) }
  }

  /// The engine's cost so far (its queue's own measure).
  public var cost: NeighbourCost {
    box.lock.lock()
    defer { box.lock.unlock() }
    return box.cost
  }

  /// The field is open and has answered: it draws live.
  public var live: Bool { opened && !failed }
  /// The field is open and has not failed (it may not have answered yet): the board keeps
  /// its frames coming.
  public var running: Bool { open != nil && !failed }

  /// Opens, reopens or closes to match `want` (nil: none). A new seed or layout closes the
  /// field and opens it again from its start.
  public func want(_ want: Want?) {
    guard want != open else { return }
    if open != nil { close() }
    guard let want else { return }
    open = want
    generation += 1
    let g = generation
    clock = 0
    heard = 0
    let box = box
    let args = #"{"seed":\#(want.seed),"scene":"tournament","layout":"\#(want.row ? "row" : "grid")","now":0}"#
    pending = true
    queue.async {
      do {
        if box.engine == nil { box.engine = try Engine.neighbours() }
        let text = try box.engine!.call("neighbours.open", json: args)
        box.post(g, .success(.opened(try JSONDecoder().decode(NeighbourOpening.self, from: Data(text.utf8)))))
      } catch {
        box.post(g, .failure(error))
      }
    }
  }

  /// Closes the field (the engine stays, its neighbours gone): leaving the scene or the
  /// match, or the app going to the background. Reopening with the same seed shows the
  /// same tournament from its start.
  public func close() {
    guard open != nil else { return }
    open = nil
    generation += 1
    opened = false
    failed = false
    pending = false
    field = NeighbourField()
    let box = box
    queue.async {
      _ = try? box.engine?.call("neighbours.close", json: "{}")
    }
  }

  /// Once a frame while the board runs: the match clock moves on by `dt`, what the
  /// queue has answered is taken in, and the next `advance` is asked for unless one is
  /// still running. True when the field changed or moves (the board draws again).
  @discardableResult public func tick(_ dt: Double) -> Bool {
    guard open != nil else { return false }
    clock += max(0, dt)
    var changed = false
    for (g, r) in box.take() where g == generation {
      pending = false
      switch r {
      case .success(.opened(let o)):
        field = NeighbourField(o)
        opened = true
        changed = true
      case .success(.advanced(let a)):
        if !a.events.isEmpty {
          field.apply(a.events)
          fresh.formUnion(a.events.map(\.id))
          changed = true
        }
      case .failure:
        // the neighbours stand as they are; the match is untouched
        failed = true
      }
    }
    guard opened, !failed else { return changed }
    // a throw that ends this frame is drawn once more, at rest
    let flying = field.pitches.filter { $0.playing != nil }.map(\.id)
    field.settle(clock)
    for p in field.pitches where p.playing == nil && flying.contains(p.id) { fresh.insert(p.id) }
    if pending {
      skipped += 1
    } else {
      pending = true
      let g = generation, now = clock, box = box
      queue.async {
        guard let engine = box.engine else { return }
        let t0 = CACurrentMediaTime()
        do {
          let text = try engine.call("neighbours.advance", json: #"{"now":\#(now),"budgetMs":\#(Self.budgetMs)}"#)
          let a = try JSONDecoder().decode(NeighbourAdvance.self, from: Data(text.utf8))
          let ms = (CACurrentMediaTime() - t0) * 1000
          box.lock.lock()
          box.cost.add(ms)
          box.lock.unlock()
          box.post(g, .success(.advanced(a)))
        } catch {
          box.post(g, .failure(error))
        }
      }
    }
    return changed || field.moving(clock)
  }

  /// Something of the field on the screen of `size` has changed or moves (a beat, a
  /// throw in the air, kubbs rising): the board draws again. A pitch off the screen
  /// moving draws nothing, so an aim with nothing beside in view keeps its frames still.
  public func needsDraw(size: CGSize, session: PitchSession) -> Bool {
    guard live else { return false }
    let projection = session.scene.projection(size, session.shownCamera)
    let screen = CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24)
    let turned = session.scene.neighboursTurned
    var any = false
    for p in field.pitches where fresh.contains(p.id) || NeighbourField.moving(p, clock) {
      let ox = turned ? -p.offset.x : p.offset.x, oy = turned ? -p.offset.y : p.offset.y
      let box = projection.polygon([
        V3(ox - 3.5, oy - 2, 0), V3(ox + 3.5, oy - 2, 0), V3(ox + 3.5, oy + 10, 0), V3(ox - 3.5, oy + 10, 0),
        V3(ox - 3.5, oy + 10, 2), V3(ox + 3.5, oy - 2, 2),
      ])
      if box.count >= 3, path(box).boundingBoxOfPath.intersects(screen) {
        any = true
        break
      }
    }
    fresh = []
    return any
  }

  /// The field to draw now, turned for Team B's view (`turned`); nil until it has
  /// answered, or once it has failed (the static pitches draw instead).
  public func drawn(turned: Bool) -> LiveNeighbours? {
    guard live else { return nil }
    return LiveNeighbours(pitches: field.drawn(at: clock, turned: turned))
  }

  /// The cues come due since the last take, `NeighbourSounds.stale` at most behind the
  /// clock, each with its pitch.
  func takeCues() -> [(NeighbourField.Live, NeighbourCue)] {
    defer { heard = clock }
    guard live, clock > heard else { return [] }
    var out: [(NeighbourField.Live, NeighbourCue)] = []
    for p in field.pitches {
      for c in p.cues where c.time > heard && c.time <= clock && clock - c.time <= NeighbourSounds.stale {
        out.append((p, c))
      }
    }
    return out
  }

  /// Waits for the queue (tests and review tools only, never the frame).
  public func drain() {
    queue.sync {}
  }

  /// A neighbour's thrown piece is part way through its flight (`from` to `to` of its
  /// recording) and on the screen of `size` as `session` draws it (the review tools'
  /// "a neighbour mid-throw").
  public func throwInView(size: CGSize, session: PitchSession, from: Double = 0.3, to: Double = 0.7) -> Bool {
    guard live else { return false }
    let projection = session.scene.projection(size, session.shownCamera)
    let screen = CGRect(origin: .zero, size: size).insetBy(dx: 30, dy: 30)
    let drawn = field.drawn(at: clock, turned: session.scene.neighboursTurned)
    for (p, d) in zip(field.pitches, drawn) {
      guard let (pb, at) = p.playing else { continue }
      let u = (clock - at) / max(pb.recording.duration, 0.01)
      guard u >= from, u <= to, let piece = d.pieces.first(where: { $0.id == pb.recording.projectile.id }),
        let s = projection.project(V3(d.dx + piece.x, d.dy + piece.y, piece.z))
      else { continue }
      if screen.contains(s) { return true }
    }
    return false
  }
}

/// The live neighbours of one frame, ready to draw (`PitchRenderer.draw`'s `neighbours`).
public struct LiveNeighbours {
  let pitches: [NeighbourPitch]
}
