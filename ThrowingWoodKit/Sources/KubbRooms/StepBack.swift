/// When an observer first in line for host steps back (leaves and joins again, last in
/// line; the web's src/net/step-back.js and docs/OBSERVER.md, its numbers). Pure, so the
/// rule is tested alone with an injected clock.
///
/// The first step back is at once. While nobody takes host the wait between them doubles
/// from 20 s to 5 minutes, so two observers on an abandoned pitch do not take turns
/// rejoining for as long as they stay. It starts again from the first when a host is
/// connected, or when a member this device has never seen connects: that one may be a
/// player, and it should not wait behind an observer. Observers keep their member id
/// when they rejoin, so their own step backs never look like an arrival. Nothing new on
/// the wire.
public struct StepBack: Sendable {
  /// ms: the second wait, doubling from here (the web's `stepBackMs`).
  public static let firstWait = 20_000
  /// ms: the longest wait (the web's `stepBackMaxMs`).
  public static let maxWait = 5 * 60 * 1000

  /// The wait after `steps` step backs, in ms: 0 before the first.
  public static func delay(_ steps: Int) -> Int {
    guard steps > 0 else { return 0 }
    let shift = min(steps - 1, 20)
    return min(firstWait << shift, maxWait)
  }

  /// Step backs since a host was last here or someone new came.
  public private(set) var steps = 0
  private var last = 0
  private var seen = Set<String>()
  public init() {}

  /// The member ids connected now. True when one of them is new (not on the first look).
  @discardableResult public mutating func see(_ ids: [String]) -> Bool {
    let first = seen.isEmpty
    var fresh = false
    for id in ids where !seen.contains(id) {
      seen.insert(id)
      if !first { fresh = true }
    }
    if fresh { reset() }
    return fresh
  }

  /// A host is connected: the next time it is gone, start from the first wait.
  public mutating func reset() { steps = 0 }

  /// ms from `now` until a step back is allowed (0: now).
  public func wait(at now: Int) -> Int {
    guard steps > 0 else { return 0 }
    return max(0, last + Self.delay(steps) - now)
  }
  public func due(_ now: Int) -> Bool { wait(at: now) == 0 }

  public mutating func took(_ now: Int) {
    steps += 1
    last = now
  }
}
