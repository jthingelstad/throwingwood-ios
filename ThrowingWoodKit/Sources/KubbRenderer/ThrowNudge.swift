import Foundation

// The throw's nudge (Jamie, 2026-11-19: "A couple of users have had a lot of
// confusion on how to throw. It would be awesome if we see the user not making
// progress on a throw to animate a nudge in the screen on what to do. Have the
// UI show it not a separate how to page."). When a player is stuck on their own
// throw, a ghost of the knob makes one good throw on the real meter with a ghost
// fingertip where the finger goes: a slow draw back and a fast flick, which is
// also the answer to "does it matter how quickly I move?" (the flick's speed is
// the throw's power; the draw back's is not).
//
// Pure: no UIKit, no engine. The host feeds the trigger what the player does and
// draws the timeline's frame. Drawing only: the ghost's arm is never fed to the
// engine, sent or recorded. A port of the web's src/game/nudge.js, same numbers.

public struct NudgeTune: Sendable, Equatable {
  // when it starts
  public var learnedAt = 3  // throws ever made on this device before it counts as learned
  public var learnCap = 9  // the counter kept on the device stops here
  public var wait = 8.0  // s in the aim without touching the meter before a new device is nudged
  public var idle = 30.0  // s with no input of any kind before a learned device is nudged
  public var fumbles = 2  // presses on the meter in a row that made no throw
  public var fumbleDelay = 0.8  // s after the last of those before the nudge starts
  public var tapResume = 1.5  // s a tap in the throw zone keeps the nudge away
  public var fadeOut = 0.15  // s the ghost takes to fade when it stops
  // the ghost's throw, one loop
  public var press = 0.4  // s at home: the fingertip comes down, a ring closes in
  public var back = 0.9  // s drawing back to the middle of the power band, eased
  public var hold = 0.25  // s held at the back: a beat
  public var flick = 0.25  // s flicking forward to the release band, fast
  public var release = 0.35  // s at the release: the fingertip lets go, a ring opens out
  public var rest = 1.0  // s of nothing between loops
  public var fadeIn = 0.15
  public var defaultBack = 120.0
  public var defaultRelease = 90.0
  public init() {}
  public var loop: Double { press + back + hold + flick + release + rest }
}

public struct NudgeSwing: Equatable, Sendable {
  public let back, release: Double
  /// To the middle of the power band, forward to the middle of the release band.
  public init(_ d: DialState, tune: NudgeTune = NudgeTune()) {
    func mid(_ lo: Double?, _ hi: Double?) -> Double? {
      guard let lo, let hi, hi > lo else { return nil }
      return (lo + hi) / 2
    }
    back = mid(d.powerLo, d.powerHi) ?? tune.defaultBack
    release = mid(d.releaseLo, d.releaseHi) ?? tune.defaultRelease
  }
  public init(back: Double, release: Double) {
    self.back = back
    self.release = release
  }
}

public struct NudgeFrame: Equatable, Sendable {
  public enum Step: String, Sendable { case press, back, hold, flick, release, rest, still }
  public var arm: Double  // the ghost's arm, degrees
  public var step: Step
  public var press: Double  // 0 lifted .. 1 on the glass
  public var ring: (k: Double, alpha: Double)?  // the press cue's ring, of the fingertip's radius
  public var alpha: Double

  public static func == (a: NudgeFrame, b: NudgeFrame) -> Bool {
    a.arm == b.arm && a.step == b.step && a.press == b.press && a.alpha == b.alpha
      && a.ring?.k == b.ring?.k && a.ring?.alpha == b.ring?.alpha
  }

  /// The engine's own words for the plate while the ghost throws (WIND BACK,
  /// then FLICK! from the beat on); nil leaves the plate as the engine has it.
  public var caption: String? {
    switch step {
    case .hold, .flick, .still: "FLICK!"
    case .press, .back: "WIND BACK"
    default: nil
    }
  }

  /// The ghost at `t` s since the nudge started. Reduced motion: a still picture
  /// at the back (the host adds the strokes' arrows).
  public static func at(
    _ t: Double, swing: NudgeSwing, reduced: Bool = false, tune n: NudgeTune = NudgeTune()
  ) -> NudgeFrame {
    let back = -abs(swing.back)
    let fwd = abs(swing.release)
    if reduced { return NudgeFrame(arm: back, step: .still, press: 1, ring: nil, alpha: 1) }
    func clamp(_ u: Double) -> Double { max(0, min(1, u)) }
    func easeInOut(_ u: Double) -> Double { u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2 }
    let L = n.loop
    var u = (t.truncatingRemainder(dividingBy: L) + L).truncatingRemainder(dividingBy: L)
    let fadeIn = clamp(u / n.fadeIn)
    if u < n.press {
      let p = u / n.press
      return NudgeFrame(
        arm: 0, step: .press, press: easeInOut(clamp(p / 0.7)),
        ring: (2.4 - 1.3 * easeInOut(p), 0.9 * p), alpha: fadeIn)
    }
    u -= n.press
    if u < n.back {
      return NudgeFrame(arm: back * easeInOut(u / n.back), step: .back, press: 1, ring: nil, alpha: 1)
    }
    u -= n.back
    if u < n.hold { return NudgeFrame(arm: back, step: .hold, press: 1, ring: nil, alpha: 1) }
    u -= n.hold
    if u < n.flick {
      let e = u / n.flick
      return NudgeFrame(arm: back + (fwd - back) * e * e, step: .flick, press: 1, ring: nil, alpha: 1)
    }
    u -= n.flick
    if u < n.release {
      let p = u / n.release
      return NudgeFrame(
        arm: fwd, step: .release, press: 1 - easeInOut(clamp(p / 0.5)),
        ring: (1.1 + 1.6 * easeInOut(p), 0.9 * (1 - p)), alpha: 1 - p * p)
    }
    return NudgeFrame(arm: 0, step: .rest, press: 0, ring: nil, alpha: 0)
  }
}

/// When the nudge shows. Its waits count only eligible time: this player's own
/// throw to make, nothing over the pitch, no finger down, the dial idle.
///
/// A device with fewer than `learnedAt` throws is nudged after `wait` s in the
/// aim without a press on the meter (taps that move the circle do not count). A
/// learned one after `fumbles` presses on the meter in a row that made no throw
/// (`fumbleDelay` after the last), or after `idle` s with no input. Two fumbles
/// bring it on a new device too. A throw clears the fumbles.
public struct NudgeTrigger: Sendable {
  public var tune: NudgeTune
  public private(set) var thrown: Int
  public private(set) var fumbles = 0
  public private(set) var showing = false
  private var clock = 0.0, meterAt = 0.0, inputAt = 0.0
  private var endedAt = -Double.infinity, holdUntil = 0.0
  private var shownAt = 0.0, fade = 0.0, lastT = 0.0

  public init(thrown: Int = 0, tune: NudgeTune = NudgeTune()) {
    self.tune = tune
    self.thrown = min(tune.learnCap, max(0, thrown))
  }

  public var learned: Bool { thrown >= tune.learnedAt }

  /// A throw is wanted (a new aim).
  public mutating func aimBegan() {
    meterAt = clock
    inputAt = clock
  }
  /// Any input: a press anywhere, a plan button.
  public mutating func input() { inputAt = clock }
  /// A press on the meter, beside the ring, or a stroke in the throw zone.
  public mutating func meterPressed() {
    input()
    meterAt = clock
    showing = false
  }
  /// A press in the throw zone or beside the ring that may yet be a tap.
  public mutating func zonePressed() {
    input()
    showing = false
    holdUntil = clock + tune.tapResume
  }
  /// A press on the meter ended, with a throw or without.
  public mutating func pressEnded(thrown: Bool) {
    input()
    meterAt = clock
    showing = false
    if thrown {
      fumbles = 0
      endedAt = -.infinity
      self.thrown = min(tune.learnCap, self.thrown + 1)
    } else {
      fumbles += 1
      endedAt = clock
    }
  }

  var wanted: Bool {
    if clock < holdUntil { return false }
    if fumbles >= tune.fumbles && clock - endedAt >= tune.fumbleDelay { return true }
    if !learned { return clock - meterAt >= tune.wait }
    return clock - inputAt >= tune.idle
  }

  /// Eligible seconds until it would start, if nothing else happens (for a host
  /// that sleeps its display link meanwhile). 0 while showing.
  public var untilWanted: Double {
    if showing { return 0 }
    var due = learned ? inputAt + tune.idle : meterAt + tune.wait
    if fumbles >= tune.fumbles { due = min(due, endedAt + tune.fumbleDelay) }
    return max(0, max(due, holdUntil) - clock)
  }

  /// Time passing. Returns whether to draw, the timeline's time and the fade.
  public mutating func step(_ dt: Double, eligible: Bool) -> (show: Bool, t: Double, alpha: Double) {
    if !eligible {
      showing = false
    } else {
      clock += dt
      if !showing && wanted {
        showing = true
        shownAt = clock
      }
    }
    if showing {
      fade = 1
      lastT = clock - shownAt
    } else {
      fade = max(0, fade - dt / tune.fadeOut)
    }
    return (fade > 0, lastT, fade)
  }
}
