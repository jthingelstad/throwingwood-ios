import Foundation
import Testing

@testable import KubbRenderer

/// The nudge: when it starts and stops, and the ghost's throw (the web's numbers).
struct NudgeTests {
  private func run(_ n: inout NudgeTrigger, _ seconds: Double, eligible: Bool = true) -> Bool {
    var shown = false
    for _ in 0..<Int((seconds * 60).rounded()) { shown = n.step(1.0 / 60, eligible: eligible).show }
    return shown
  }

  @Test func newDeviceAfterEightSecondsWithoutTheMeter() {
    var n = NudgeTrigger(thrown: 0)
    n.aimBegan()
    #expect(!run(&n, 7.9))
    #expect(run(&n, 0.2))
    // a press on the meter stops it at once and starts the wait again
    n.meterPressed()
    #expect(!n.showing)
    #expect(abs(n.untilWanted - 8) < 1e-9)
  }

  @Test func tapsThatAimDoNotCountButHoldItOff() {
    var n = NudgeTrigger(thrown: 1)
    n.aimBegan()
    _ = run(&n, 5)
    n.input()  // a tap that moved the circle: the meter's wait goes on
    #expect(!run(&n, 2.9))
    #expect(run(&n, 0.2))
    // a tap in the throw zone keeps it away 1.5 s
    n.zonePressed()
    #expect(!run(&n, 1.4))
    #expect(run(&n, 0.2))
  }

  @Test func learnedDeviceAfterThirtySecondsIdleOrTwoFumbles() {
    var n = NudgeTrigger(thrown: 3)
    #expect(n.learned)
    n.aimBegan()
    #expect(!run(&n, 29.9))
    #expect(run(&n, 0.2))
    n.meterPressed()
    n.pressEnded(thrown: false)
    #expect(!run(&n, 5))
    n.meterPressed()
    n.pressEnded(thrown: false)
    #expect(!run(&n, 0.75))
    #expect(run(&n, 0.1))
    // a throw clears the fumbles and counts, up to the cap
    n.pressEnded(thrown: true)
    #expect(n.fumbles == 0 && n.thrown == 4)
    for _ in 0..<10 { n.pressEnded(thrown: true) }
    #expect(n.thrown == 9)
  }

  @Test func onlyEligibleTimeCounts() {
    var n = NudgeTrigger(thrown: 0)
    n.aimBegan()
    _ = run(&n, 6)
    #expect(!run(&n, 60, eligible: false))  // the computer's turn, a finger down, the plan
    #expect(!run(&n, 1.9))
    #expect(run(&n, 0.2))
    // it fades out over 0.15 s when it stops
    let fade = n.step(0.05, eligible: false)
    #expect(fade.show && abs(fade.alpha - (1 - 0.05 / 0.15)) < 1e-9)
    #expect(!n.step(0.11, eligible: false).show)
  }

  /// A slow draw back to the middle of the power band, a beat, a fast flick to the
  /// middle of the release band.
  @Test func theGhostsThrow() {
    let swing = NudgeSwing(back: 120, release: 60)
    let t = NudgeTune()
    #expect(abs(t.loop - 3.15) < 1e-9)
    func at(_ s: Double) -> NudgeFrame { NudgeFrame.at(s, swing: swing) }
    #expect(at(0.1).step == .press && at(0.1).arm == 0 && at(0.1).ring != nil)
    #expect(at(0.4 + 0.45).step == .back && abs(at(0.85).arm - -60) < 1e-9)
    #expect(at(1.4).step == .hold && at(1.4).arm == -120)
    #expect(at(1.7).step == .flick)
    #expect(at(1.85).step == .release && at(1.85).arm == 60)
    #expect(at(2.5).step == .rest && at(2.5).alpha == 0)
    #expect(at(3.15 + 1.4) == at(1.4))  // it loops
    // the draw back takes 0.9 s and the flick 0.25 s: 133 and 720 degrees a second
    let backSpeed = 120 / t.back, flickSpeed = 180 / t.flick
    #expect(flickSpeed > 5 * backSpeed)
    // the flick speeds up all the way (ease-in): fastest as it reaches the release
    let early = at(1.55 + 0.05).arm - at(1.55).arm
    let late = at(1.8 - 0.001).arm - at(1.8 - 0.051).arm
    #expect(late > 3 * early)
    #expect(at(0.2).caption == "WIND BACK" && at(1.6).caption == "FLICK!" && at(2.5).caption == nil)
    // reduced motion: a still picture at the back
    let still = NudgeFrame.at(0.3, swing: swing, reduced: true)
    #expect(still.step == .still && still.arm == -120 && still.alpha == 1)
  }

  @MainActor @Test func swingIsTheMiddlesOfTheBands() throws {
    let pitch = try PracticePitch(appVersion: "test")
    let d = pitch.dial
    let s = NudgeSwing(d)
    let lo = try #require(d.powerLo), hi = try #require(d.powerHi)
    #expect(s.back == (lo + hi) / 2)
    #expect(s.release == ((d.releaseLo ?? 0) + (d.releaseHi ?? 0)) / 2)
  }
}
