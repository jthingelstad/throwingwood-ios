import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
import QuartzCore
import simd

// The home screen's match (the owner, 2026-11-27: "Instead of a static image, I'd like to
// have the Kubb Engine playing a game in the background. Pick the standard 'Park' scene so
// it looks 'normal'. If we can have the game minimize idle time it would be good."): the
// computer against the computer on the newest carried engine, in the Park scene, drawn by
// the app's own renderer through the thrower's camera, as a solo match is. It is scenery:
// no sound, no haptics, no cards, no names on the screen, nothing kept and nothing sent.
//
// It runs as the Tournament's neighbours do (Neighbours.swift): a Lua state of its own on
// a serial queue of its own, never the player's engine and never waited on by the main
// thread. The queue plays each throw headless (the engine's computer at its fastest think
// and swing, `frame {speed}`), samples the throw's flight camera from `showAt`, and hands
// the main thread a finished throw; the main thread only plays it back (`Playback`) and
// draws. Two throws are made ahead at most. The Lua state exists only while home shows.

/// One throw of the home match as the queue made it, ready to play.
struct HomeThrow: @unchecked Sendable {
  /// Which match it belongs to (a new number for each new match).
  let match: Int
  /// The pitch as the throw is aimed (the thrower's frame): its items, ground and set, with
  /// the aim's focus and far baseline taken as `PitchSession.aim` takes them.
  let before: PitchScene
  /// The camera the throw is aimed through (the computer's own aim).
  let aimCamera: Camera
  /// The side whose frame its poses are in (the thrower's).
  let side: String?
  let recording: Recording
  /// The flight's camera every `HomeTune.sampleDt` s of real time, with the recording's
  /// own time there (`showAt`'s pace: it slows round the hit).
  let samples: [HomeSample]
  /// The match is over after this throw.
  let over: Bool
}

struct HomeSample: Sendable {
  let t: Double
  let camera: Camera
}

/// The home match's pace: every number that decides how little it idles. The throws
/// themselves play at the match's own pace (`showAt`), slow motion round a hit included.
public enum HomeTune {
  /// The computer's level for both sides: Pro, whose throws hit, so a match moves and ends.
  public static let level = "pro"
  /// The engine's computer think (0.9 s) and swing (0.6 s) are run headless at the
  /// engine's fastest (8x, in 0.1 s steps): nothing of them is shown.
  static let thinkSpeed = 8, thinkStep = 0.1
  /// s of real time between the flight camera's samples (interpolated between).
  static let sampleDt = 1.0 / 30
  /// s the pitch rests after a throw before the next is shown (a match's: 0.8).
  public static let rest = 0.5
  /// s the next throw's aim is held before it is thrown: the same thrower again, or the
  /// other end after a turn changes hands (the camera turns round).
  public static let aimSame = 0.35, aimTurn = 0.8
  /// s a finished match rests before the next starts (no winner card), and the first
  /// throw of a match is held once its pieces have stood up.
  public static let over = 2.2, firstAim = 0.4
  /// Throws made ahead of the one shown.
  static let ahead = 2
  /// A match that has not ended by then ends anyway (the web's watch mode: 60).
  static let maxTurns = 40
}

/// The queue's side: the engine and the match, touched only on the queue, and the inbox
/// under its lock.
private final class HomeEngine: @unchecked Sendable {
  let appVersion: String
  /// The first match's seed (review pictures); every other match's is random.
  var seed: Int?
  var engine: Engine?
  var inMatch = false
  var match = 0
  var first = "A"
  /// Calls the engine has answered and throws made (tests read them).
  var made = 0
  let lock = NSLock()
  var inbox: [(generation: Int, result: Result<HomeThrow, Error>)] = []

  /// A match ends after this many turns at most (a test asks for fewer).
  var maxTurns = HomeTune.maxTurns
  init(appVersion: String, seed: Int?) {
    self.appVersion = appVersion
    self.seed = seed
  }

  func post(_ generation: Int, _ r: Result<HomeThrow, Error>) {
    lock.lock()
    inbox.append((generation, r))
    lock.unlock()
  }
  func take() -> [(generation: Int, result: Result<HomeThrow, Error>)] {
    lock.lock()
    defer { lock.unlock() }
    let out = inbox
    inbox = []
    return out
  }

  private let decoder = JSONDecoder()
  private func read<T: Decodable>(_ e: Engine, _ method: String, _ args: String = "") throws -> T {
    try decoder.decode(T.self, from: Data(e.call(method, json: args).utf8))
  }

  /// A new match: both sides the computer, the Park scene, raising automatic, no wind.
  private func newMatch(_ e: Engine) throws {
    let seed = self.seed ?? Int.random(in: 1..<2_147_483_648)
    self.seed = nil
    let setup = JS.object([
      ("mode", .string("match")), ("cpu", .string("both")), ("seed", .number(Double(seed))),
      ("first", .string(first)), ("computer", .string(HomeTune.level)), ("raising", .string("auto")),
      ("wind", .string("off")), ("scene", .string("day")), ("maxTurns", .number(Double(maxTurns))),
    ]).ascii
    _ = try e.call("new", json: setup)
    first = first == "A" ? "B" : "A"
    match += 1
    inMatch = true
  }

  /// The next throw of the match (a new match first when none is on).
  func next() throws -> HomeThrow {
    if engine == nil { engine = try Engine(appVersion: appVersion) }
    let e = engine!
    for _ in 0..<3 {
      if !inMatch { try newMatch(e) }
      let v: ViewOutput = try read(e, "view")
      guard v.need.kind == "throw", v.need.cpu == true else {
        // over (the last throw's match), or anything the computer does not throw: anew
        inMatch = false
        continue
      }
      var aimed: AimOutput?
      var released: AimOutput?
      let step = #"{"dt":\#(HomeTune.thinkStep),"speed":\#(HomeTune.thinkSpeed)}"#
      for _ in 0..<200 {
        let a: AimOutput = try read(e, "frame", step)
        if a.recording != nil {
          released = a
          break
        }
        aimed = a
      }
      guard let released, let recording = released.recording else {
        inMatch = false
        continue
      }
      // the flight's camera, sampled at the throw's own pace
      var samples: [HomeSample] = []
      var t = 0.0
      for _ in 0..<3000 {
        let s: HomeShown = try read(e, "showAt", #"{"t":\#(t)}"#)
        samples.append(HomeSample(t: t, camera: s.camera))
        if s.done || t >= recording.duration { break }
        t = min(recording.duration, t + HomeTune.sampleDt * max(0.05, s.speed))
      }
      let need: HomeNeed = try read(e, "need")
      let over = need.kind != "throw"
      if over { inMatch = false }
      let aim = aimed?.aim ?? v.aim
      let camera = aimed?.camera ?? v.camera
      var scene = PitchScene(surface: v.surface, set: v.set, items: v.items, look: v.scene)
      scene.farFrameY = PitchProjection.farFrame(camera)
      let reference = PitchProjection(size: CGSize(width: 400, height: 240), camera: camera)
      if let m = aim.marker, m.shown != false, let p = reference.project(m.point) { scene.focusX = Double(p.x) }
      made += 1
      return HomeThrow(
        match: match, before: scene, aimCamera: camera, side: v.need.frame ?? v.need.side,
        recording: recording, samples: samples, over: over)
    }
    throw HomeMatchError.noThrow
  }

  /// Lets the Lua state go (leaving home).
  func close() {
    engine = nil
    inMatch = false
  }
}

enum HomeMatchError: Error { case noThrow }

private struct HomeShown: Decodable {
  let camera: Camera
  let speed: Double
  let done: Bool
}

private struct HomeNeed: Decodable {
  let kind: String
}

/// The home screen's match on the main thread: what to draw now, from the throws the queue
/// has made. Ask `want` on every change of screen, the app's phase and Reduce Motion;
/// `tick` once a frame while it is drawn.
@MainActor public final class HomeMatch {
  /// What the home screen wants of it.
  public enum State: Equatable, Sendable {
    /// Not on home (or Reduce Motion): no engine, no match.
    case off
    /// Home, with the app in the background: the match and its engine kept, its clock still.
    case paused
    /// Home on the screen: playing.
    case on
  }

  /// The state for a screen: on while home shows, paused while the app is in the
  /// background on home, and off everywhere else and always under Reduce Motion (the
  /// still pitch, and no second engine).
  public static func state(home: Bool, background: Bool, reduced: Bool) -> State {
    guard home, !reduced else { return .off }
    return background ? .paused : .on
  }

  private let queue = DispatchQueue(label: "throwingwood.home", qos: .utility)
  private let box: HomeEngine
  public private(set) var state = State.off
  private var generation = 0
  private var asked = 0
  private var failed = false
  /// Throws made and not yet shown.
  private var ahead: [HomeThrow] = []

  /// The throw on the screen and where it is.
  private enum Phase {
    /// Its aim held `age` s of `hold`, the pieces rising into place (`rises`, on the
    /// phase's own clock).
    case aim(age: Double, hold: Double)
    /// Its flight, `age` s of real time in.
    case flight(age: Double)
    /// At rest, `age` s of `hold`.
    case rest(age: Double, hold: Double)
  }
  private var current: HomeThrow?
  private var playback: Playback?
  private var phase = Phase.aim(age: 0, hold: 0)
  private var rises: [String: Rise] = [:]
  private var lastShown: [String: Piece] = [:]
  /// What is drawn now; nil until the first throw has come.
  public private(set) var scene: PitchScene?
  public private(set) var camera: Camera?

  /// `seed`: the first match's (the review pictures', so they are the same every time).
  public init(appVersion: String, seed: Int? = nil, maxTurns: Int? = nil) {
    box = HomeEngine(appVersion: appVersion, seed: seed)
    if let maxTurns { box.maxTurns = maxTurns }
  }
  /// Throws shown since `on` (review pictures).
  public private(set) var begun = 0

  /// The engine's Lua state exists (it is made on the first `on`, let go at `off`).
  public var engineStarted: Bool { queue.sync { box.engine != nil } }
  /// Throws the queue has made since this was made (tests).
  public var throwsMade: Int { queue.sync { box.made } }
  /// The match on the screen, by number (tests).
  public var shownMatch: Int? { current?.match }
  /// Something to draw has come.
  public var ready: Bool { scene != nil }

  /// Moves to `state`. Off lets the engine and the match go (the next on starts a new
  /// match); paused keeps them and stops asking for throws.
  public func want(_ s: State) {
    guard s != state else { return }
    state = s
    switch s {
    case .off:
      generation += 1
      asked = 0
      begun = 0
      failed = false
      ahead = []
      current = nil
      playback = nil
      scene = nil
      camera = nil
      rises = [:]
      let box = box
      queue.async { box.close() }
    case .paused:
      break
    case .on:
      askAhead()
    }
  }

  /// Asks the queue for throws until `HomeTune.ahead` are made or on their way.
  private func askAhead() {
    guard state == .on, !failed else { return }
    while ahead.count + asked < HomeTune.ahead {
      asked += 1
      let g = generation, box = box
      queue.async {
        box.post(g, Result { try box.next() })
      }
    }
  }

  /// One frame of `dt` s while home shows: the throws the queue has made are taken in
  /// and the one on the screen moves on. True when the picture changed.
  @discardableResult public func tick(_ dt: Double) -> Bool {
    guard state == .on else { return false }
    for (g, r) in box.take() where g == generation {
      asked = max(0, asked - 1)
      switch r {
      case .success(let t): ahead.append(t)
      case .failure:
        // the pitch stands as it is; home is untouched
        failed = true
      }
    }
    defer { askAhead() }
    let dt = min(max(dt, 0), 0.1)
    guard let c = current else { return begin(after: nil) }
    switch phase {
    case .aim(let age, let hold):
      let now = age + dt
      if now >= hold {
        startFlight()
      } else {
        phase = .aim(age: now, hold: hold)
        guard !rises.isEmpty else { return false }
        drawAim(c, at: now)
      }
      return true
    case .flight(let age):
      let now = age + dt
      let k = now / HomeTune.sampleDt
      if Int(k) >= c.samples.count - 1 {
        settle(c)
        phase = .rest(age: 0, hold: c.over ? HomeTune.over : HomeTune.rest)
      } else {
        phase = .flight(age: now)
        drawFlight(c, sample: k)
      }
      return true
    case .rest(let age, let hold):
      let now = age + dt
      if now < hold {
        phase = .rest(age: now, hold: hold)
        return false
      }
      return begin(after: c)
    }
  }

  /// The next throw on the screen once one has been made: its pieces rise from where the
  /// last throw left them (turned round when the other end throws now), or all stand up
  /// for a new match.
  private func begin(after last: HomeThrow?) -> Bool {
    guard !ahead.isEmpty else { return false }
    let next = ahead.removeFirst()
    var hold: Double
    if let last, last.match == next.match, let pb = playback {
      var was = pb.pieces(at: pb.recording.duration)
      let turned = last.side != next.side
      if turned { was = was.map(NeighbourField.halfTurned) }
      rises = Calm.rises(from: was, to: next.before.items, at: 0)
      hold = turned ? HomeTune.aimTurn : HomeTune.aimSame
    } else {
      rises = Calm.rises(from: [], to: next.before.items, at: 0, setup: true)
      hold = HomeTune.firstAim
    }
    let rising = rises.values.map { $0.at + $0.length }.max() ?? 0
    current = next
    begun += 1
    playback = Playback(next.recording)
    lastShown = [:]
    phase = .aim(age: 0, hold: rising + hold)
    drawAim(next, at: 0)
    return true
  }

  private func drawAim(_ t: HomeThrow, at now: Double) {
    var s = t.before
    if !rises.isEmpty {
      s.items = s.items.map { q in rises[q.id].map { Calm.risen($0.from, to: q, u: (now - $0.at) / $0.length) } ?? q }
    }
    scene = s
    camera = t.aimCamera
  }

  private func startFlight() {
    rises = [:]
    phase = .flight(age: 0)
    if let c = current { drawFlight(c, sample: 0) }
  }

  /// The flight `k` samples in (fractional): the camera between its two samples, the
  /// pieces at the recording's time there, a spin drawn as one (Spin.swift).
  private func drawFlight(_ c: HomeThrow, sample k: Double) {
    guard let pb = playback, !c.samples.isEmpty else { return }
    let i = max(0, min(c.samples.count - 1, Int(k)))
    let j = min(c.samples.count - 1, i + 1)
    let u = max(0, min(1, k - Double(i)))
    let a = c.samples[i], b = c.samples[j]
    let t = a.t + (b.t - a.t) * u
    var s = c.before
    s.items = pb.pieces(at: t)
    s.spins = SpinTune.spins(from: lastShown, to: s.items)
    lastShown = Dictionary(s.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    scene = s
    camera = a.camera.mixed(b.camera, u)
  }

  /// The throw at rest: its last poses, the flight's last camera.
  private func settle(_ c: HomeThrow) {
    guard let pb = playback else { return }
    var s = c.before
    s.items = pb.pieces(at: pb.recording.duration)
    scene = s
    camera = c.samples.last?.camera ?? c.aimCamera
  }

  /// Draws the match as it is now on the day's pitch (nothing before the first throw).
  public func draw(in context: CGContext, size: CGSize) {
    guard let scene, let camera else { return }
    PitchRenderer.draw(in: context, size: size, camera: camera, scene: scene, look: "day")
  }

  /// Plays on at `step` s a frame, waiting for the queue whenever the next throw is
  /// needed, until the `n`th throw shown (from 1) is `at` of its flight (0 to 1), or
  /// `limit` s have passed: the same picture every time for one seed (tests and review
  /// pictures only, never a frame).
  @discardableResult public func play(toThrow n: Int, at: Double, limit: Double = 600, step: Double = 1.0 / 60) -> Bool {
    var clock = 0.0
    while clock < limit {
      if waiting { drain() }
      tick(step)
      clock += step
      if begun == n, case .flight(let age) = phase, let c = current,
        age >= at * Double(c.samples.count - 1) * HomeTune.sampleDt
      {
        return true
      }
      if begun > n { return false }
    }
    return false
  }
  /// The next throw is wanted and may not have come: before the first, or at rest.
  var waiting: Bool {
    guard ahead.isEmpty else { return false }
    if current == nil { return true }
    if case .rest = phase { return true }
    return false
  }

  /// Waits for the queue (tests and review pictures only, never a frame).
  public func drain() { queue.sync {} }
}

extension Camera {
  /// Part way from this camera to `b` (u 0 to 1): close samples of one flight, so a
  /// straight mix of each number is near enough.
  func mixed(_ b: Camera, _ u: Double) -> Camera {
    guard u > 0 else { return self }
    func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
    func mo(_ x: Double?, _ y: Double?) -> Double? {
      guard let x, let y else { return x ?? y }
      return m(x, y)
    }
    var c = Camera(
      px: m(px, b.px), py: m(py, b.py), pz: m(pz, b.pz), fx: m(fx, b.fx), fy: m(fy, b.fy), fz: m(fz, b.fz),
      rx: m(rx, b.rx), ry: m(ry, b.ry), rz: m(rz, b.rz), ux: m(ux, b.ux), uy: m(uy, b.uy), uz: m(uz, b.uz),
      f: m(f, b.f), cx: m(cx, b.cx), cy: m(cy, b.cy))
    c.lx = mo(lx, b.lx)
    c.ly = mo(ly, b.ly)
    c.lz = mo(lz, b.lz)
    c.kind = kind
    return c
  }
}
