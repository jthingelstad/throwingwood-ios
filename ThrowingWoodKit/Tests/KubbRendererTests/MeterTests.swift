import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// The linear meter's geometry and its arm degrees against the clock's.
@MainActor struct MeterTests {
  private let small = CGRect(x: 0, y: 0, width: 390, height: 844)  // iPhone 16e
  private let large = CGRect(x: 0, y: 0, width: 440, height: 956)  // iPhone 17 Pro Max

  private func linear(_ b: CGRect, _ side: MeterSide = .right) throws -> LinearMeter {
    try #require(LinearMeter.layout(size: b.size, safeTop: 47, safeBottom: 34, side: side))
  }

  @Test func trackIsThreeQuartersOfTheOldAndNeverCramped() throws {
    for b in [small, large] {
      let m = try linear(b)
      // 47% of the height, never under 320 pt of track
      #expect(abs(m.box.height / b.height - 0.47) < 0.001)
      #expect(m.travel >= 320)
      // the box stands on the bottom margin above the safe area and at the right edge
      #expect(abs(m.box.maxY - (b.height - 34 - 7)) < 0.001)
      #expect(abs(m.box.maxX - (b.width - 7)) < 0.001)
      #expect(m.right + m.shadow <= b.width - 7 + 0.001)
      // home is the middle of the track, one scale both ways
      #expect(abs(m.yHome - (m.yForward + m.yBack) / 2) < 0.001)
      #expect(abs(m.y(arm: 180) - m.yForward) < 0.001)
      #expect(abs(m.y(arm: -180) - m.yBack) < 0.001)
      #expect(abs(m.scale * 360 - m.travel) < 0.001)
      // the lane (targets) toward the centre, the channel (knob) toward the edge
      #expect(m.laneLeft < m.channelLeft)
      #expect(m.tabDirection == -1)
    }
    // about 330 pt of track on the 16e, a tall phone
    let m = try linear(small)
    #expect(m.travel > 325 && m.travel < 345)
  }

  @Test func screensWithoutTheRoomShowTheClock() {
    // a phone on its side, and a short phone
    for size in [CGSize(width: 844, height: 390), CGSize(width: 320, height: 568)] {
      let layout = MeterLayout.make(
        kind: .linear, side: .right, bounds: CGRect(origin: .zero, size: size), safeTop: 20,
        safeBottom: 0)
      #expect(layout.linear == nil)
      #expect(layout.clock != nil)
    }
    let clock = MeterLayout.make(kind: .clock, side: .left, bounds: small, safeTop: 47, safeBottom: 34)
    #expect(clock == .clock(ClockMeter(bounds: small, bottomInset: 34)))
  }

  @Test func armRoundTripsAndClamps() throws {
    let m = try linear(small)
    for a in stride(from: -180.0, through: 180, by: 7.5) {
      #expect(abs(m.arm(atY: m.y(arm: a)) - a) < 1e-9)
    }
    #expect(m.arm(atY: m.yBack + 200) == -180)
    #expect(m.arm(atY: m.yForward - 200) == 180)
    // drawing down toward yourself is the backswing
    #expect(m.arm(atY: m.yHome + 10) < 0)
  }

  private func armOf(_ frame: String?) throws -> Double {
    let f = try #require(frame)
    let r = try #require(f.range(of: #"(?<="arm":)[-0-9.e+]+"#, options: .regularExpression))
    return try #require(Double(f[r]))
  }

  /// The same stroke on either meter is the same arm, frame by frame, and so the same throw.
  @Test func linearStrokeThrowsAsTheClockDoes() throws {
    let dt = 1.0 / 60
    let clockPitch = try PracticePitch(appVersion: "test")
    let linearPitch = try PracticePitch(appVersion: "test")
    let d = clockPitch.dial
    let back = try #require(d.powerLo.flatMap { lo in d.powerHi.map { (lo + $0) / 2 } })
    let stop = try #require(d.releaseLo.flatMap { lo in d.releaseHi.map { (lo + $0) / 2 } })
    var arms = [0.0, -5]
    var a = -5.0
    while a > -back {
      a = max(-back, a - 400 * dt)
      arms.append(a)
    }
    while a < stop {
      a = min(stop, a + 2400 * dt)
      arms.append(a)
    }
    let clock = ClockMeter(bounds: small, bottomInset: 34)
    let m = try linear(small)
    let clockLayout = MeterLayout.clock(clock), linearLayout = MeterLayout.linear(m)
    // the finger presses 12 pt below the knob's home: the grab is relative
    let grab: CGFloat = 12
    var clockInput = PointerDial(), linearInput = PointerDial()
    for arm in arms {
      let cp = clockLayout.unit(clock.point(arm: arm, radius: clock.radius * 1.6), grab: 0)
      let lp = linearLayout.unit(CGPoint(x: m.knobX - 3, y: m.y(arm: arm) + grab), grab: grab)
      clockInput.sample(cp)
      linearInput.sample(lp)
      let ca = try armOf(clockInput.frame(after: dt)), la = try armOf(linearInput.frame(after: dt))
      #expect(abs(ca - la) < 1e-9)
      #expect(abs(la - arm) < 1e-9)
      clockPitch.sample(cp)
      linearPitch.sample(lp)
      try clockPitch.tick(dt)
      try linearPitch.tick(dt)
      let cd = clockPitch.dial, ld = linearPitch.dial
      #expect(cd.phase == ld.phase && cd.prompt == ld.prompt)
      #expect(abs(cd.back - ld.back) < 1e-9 && abs(cd.arm - ld.arm) < 1e-9)
    }
    clockPitch.sample(nil)
    linearPitch.sample(nil)
    try clockPitch.tick(dt)
    try linearPitch.tick(dt)
    let c = try #require(clockPitch.playback), l = try #require(linearPitch.playback)
    #expect(c.recording.result == l.recording.result)
    // The verdict is the same; the flight is not hash for hash. The finger 1.6
    // radii out on the clock and the knob's height give the same arm only to the
    // last bits, and the pieces' tumble magnifies that, as with two fingers on one
    // clock.
  }
}
