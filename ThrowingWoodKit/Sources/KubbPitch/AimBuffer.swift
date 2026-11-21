import Foundation

/// A watcher's copy of someone else's aim, drawn about 100 ms behind (the web's
/// src/net/aim.js AimBuffer, docs/MULTIPLAYER.md "Being there"; the same numbers).
///
/// Each cast is kept with the pitch's `ts` (when the pitch relayed it). This device's
/// clock and the pitch's differ by an offset plus the network's delay; the smallest gap
/// seen (arrival − ts) over the last `offsetSamples` casts stands for both. The aim is
/// drawn as it was `delay` ms before the newest the network could have brought: render
/// time = now − offset − delay, in the pitch's time. Between the two casts around it the
/// continuous fields go in a straight line (`linear`), `arm` the shorter way round (and
/// not between two casts half a turn or more apart); the rest are the earlier cast's.
/// Never across a new throw (`seq`) or another sender. Past the newest it holds the newest.
///
/// An action that ends a throw waits for its aim to play out (`holdFor`): the watcher
/// sees the swing let go and then the throw, never the throw first. At most `holdMax`.
public struct AimBuffer: Sendable {
  /// ms behind the pitch's clock (aimTune.delayMs).
  public var delay: Int
  /// The clock offset is the smallest gap over this many casts (aimTune.offsetSamples).
  public static let offsetSamples = 40
  /// Casts kept for drawing (aimTune.keep).
  public static let keep = 48
  /// The longest an action waits for its aim, ms (aimTune.holdMaxMs).
  public static let holdMax = 250
  /// A sender silent this long before an action is not waited for, ms (aimTune.staleMs).
  public static let stale = 1500
  /// The fields drawn in a straight line between casts (`arm`, degrees, apart).
  public static let linear = ["x", "y", "tx", "ty", "release", "tilt", "spin", "back", "mix"]

  struct Sample: Sendable {
    let from: String?
    let ts: Int
    let k: Int?
    let aim: JSONNode
  }
  private(set) var samples: [Sample] = []
  private var gaps: [Int] = []
  /// This device's clock minus the pitch's, in ms: the smallest gap of the recent casts.
  public private(set) var offset: Int?

  public init(delay: Int = 100) { self.delay = delay }

  public var isEmpty: Bool { samples.isEmpty }
  /// A new match or a reconnect: nothing to draw (the offset is kept, as on the web).
  public mutating func reset() { samples.removeAll() }

  /// One cast's aim (`d.s`), with its sender, the pitch's `ts`, the sender's count `k`
  /// when it has one, and this device's clock when it came.
  public mutating func add(_ aim: JSONNode, from sender: String?, ts: Int?, k: Int?, now: Int) {
    guard aim.kind == .object else { return }
    let ts = ts ?? now
    gaps.append(now - ts)
    if gaps.count > Self.offsetSamples { gaps.removeFirst(gaps.count - Self.offsetSamples) }
    offset = gaps.min()
    // the same sender's older cast, late: nothing to draw from it
    if let last = samples.last, last.from == sender, let k, let lk = last.k, k <= lk { return }
    // keep ts order (two senders' casts may cross)
    var i = samples.count
    while i > 0 && samples[i - 1].ts > ts { i -= 1 }
    samples.insert(Sample(from: sender, ts: ts, k: k, aim: aim), at: i)
    if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }
  }

  /// The render time for `now`, in the pitch's time.
  public func renderTime(now: Int) -> Int { now - (offset ?? 0) - delay }

  /// The aim to draw at this device's `now`, as `aimState` JSON; nil before any cast.
  public func sample(now: Int) -> JSONText? {
    guard !samples.isEmpty else { return nil }
    let t = renderTime(now: now)
    var i = samples.count - 1
    while i > 0 && samples[i].ts > t { i -= 1 }
    let a = samples[i]
    guard a.ts <= t, i + 1 < samples.count else { return a.aim.raw }
    let b = samples[i + 1]
    guard b.from == a.from, b.aim["seq"]?.raw == a.aim["seq"]?.raw, b.ts > a.ts else { return a.aim.raw }
    return Self.blend(a.aim, b.aim, Double(t - a.ts) / Double(b.ts - a.ts))
  }

  /// How long an action relayed at pitch time `ts` waits so the aim before it has been
  /// drawn: min(holdMax, ts + offset + delay − now), and 0 when there is no aim, or the
  /// newest is more than `stale` ms older than the action.
  public func holdFor(ts: Int?, now: Int) -> Int {
    guard let last = samples.last, let ts, let offset else { return 0 }
    if ts - last.ts > Self.stale { return 0 }
    return max(0, min(Self.holdMax, ts + offset + delay - now))
  }

  /// `a`'s fields with the linear ones `u` (0...1) of the way to `b`'s, `arm` the shorter
  /// way round unless the two are half a turn or more apart (the web's lerpAim).
  static func blend(_ a: JSONNode, _ b: JSONNode, _ u: Double) -> JSONText {
    if u <= 0 { return a.raw }
    if u >= 1 { return b.raw }
    let fields: [(String, JS)] = a.members.map { key, value in
      guard let x = value.double, let y = b[key]?.double else { return (key, .raw(value.raw)) }
      if linear.contains(key) { return (key, .number(x + (y - x) * u)) }
      if key == "arm" {
        var d = y - x
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        guard abs(d) < 180 else { return (key, .raw(value.raw)) }
        var arm = x + d * u
        if arm < 0 { arm += 360 } else if arm >= 360 { arm -= 360 }
        return (key, .number(arm))
      }
      return (key, .raw(value.raw))
    }
    return JS.object(fields).json
  }
}
