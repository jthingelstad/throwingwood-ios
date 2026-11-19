import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// The linear meter's geometry, its arm degrees against the clock's, its sides and
/// the touches each meter claims.
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
    // the web's floor and cap: 390 to 450 pt where there is the room
    let short = try #require(
      LinearMeter.layout(size: CGSize(width: 375, height: 812), safeTop: 47, safeBottom: 34, side: .right))
    #expect(abs(short.box.height - 390) < 0.001)
    let tall = try #require(
      LinearMeter.layout(size: CGSize(width: 440, height: 1100), safeTop: 47, safeBottom: 34, side: .right))
    #expect(abs(tall.box.height - 450) < 0.001)
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

  @Test func leftSideIsTheRightMirrored() throws {
    for b in [small, large] {
      let r = try linear(b, .right)
      let l = try linear(b, .left)
      #expect(l.side == .left && l.tabDirection == 1)
      #expect(abs(l.box.minX - 7) < 0.001)
      #expect(l.channelLeft < l.laneLeft)  // the lane toward the centre again
      #expect(abs(l.width - r.width) < 0.001 && abs(l.box.height - r.box.height) < 0.001)
      #expect(abs(l.yHome - r.yHome) < 0.001 && abs(l.scale - r.scale) < 0.001)
      // the box mirrored about the screen's centre, the parts within it too
      #expect(abs(l.box.minX - (b.width - r.box.maxX)) < 0.001)
      #expect(abs((l.knobX - l.left) - (r.right - r.knobX)) < 0.001)
      #expect(abs((l.laneX - l.left) - (r.right - r.laneX)) < 0.001)
      // the same stroke gives the same arm on either side
      for dy in [-120.0, -10, 0, 33, 140] as [CGFloat] {
        let lp = MeterLayout.linear(l).unit(CGPoint(x: l.knobX, y: l.yHome + dy), grab: 0)
        let rp = MeterLayout.linear(r).unit(CGPoint(x: r.knobX, y: r.yHome + dy), grab: 0)
        #expect(lp == rp)
      }
    }
  }

  /// Exactly which presses each meter claims, before and after the pitch's own.
  @Test func touchClaims() throws {
    let clock = ClockMeter(bounds: small, bottomInset: 34)
    let cl = MeterLayout.clock(clock)
    let c = clock.center, r = clock.radius
    func at(_ k: CGFloat, _ arm: Double = 90) -> CGPoint { clock.point(arm: arm, radius: r * k) }
    // the ring, out to 1.25 radii, is the throw at once, as always
    #expect(cl.first(c) == .meter(grab: 0))
    #expect(cl.first(at(1.24)) == .meter(grab: 0))
    #expect(cl.first(at(1.26)) == nil)
    // beside it, 1.25 to 2.1 radii, after the target and the thrower
    for arm in [-150.0, -90, 0, 90, 150] {
      #expect(cl.after(at(1.3, arm), in: small.size, aimable: false) == .beside)
      #expect(cl.after(at(2.09, arm), in: small.size, aimable: true) == .besidePending)
    }
    #expect(cl.after(at(2.11), in: small.size, aimable: false) == nil)
    // the clock has no throw zone
    #expect(cl.after(CGPoint(x: 20, y: small.height * 0.7), in: small.size, aimable: false) == nil)
    // the arm is the angle about the centre at any radius
    #expect(abs(clock.arm(at: at(1.9, -120)) - -120) < 1e-9)

    for side in MeterSide.allCases {
      let m = try linear(small, side)
      let ml = MeterLayout.linear(m)
      // the knob: 46 pt up or down from home, across the body and 6 pt either side
      #expect(ml.first(CGPoint(x: m.knobX, y: m.yHome)) == .meter(grab: 0))
      #expect(ml.first(CGPoint(x: m.left - 5, y: m.yHome + 40)) == .meter(grab: 40))
      #expect(ml.first(CGPoint(x: m.right + 5, y: m.yHome - 46)) == .meter(grab: -46))
      #expect(ml.first(CGPoint(x: m.knobX, y: m.yHome + 47)) == .body)
      // the rest of the body, its shadow too, swallows the press
      #expect(ml.first(CGPoint(x: m.laneX, y: m.top + 4)) == .body)
      #expect(ml.first(CGPoint(x: m.knobX, y: m.bottom + m.shadow - 1)) == .body)
      let outside = side == .right ? m.left - 7 : m.right + m.shadow + 7
      #expect(ml.first(CGPoint(x: outside, y: m.yHome)) == nil)
      // the throw zone: the lower 40% of the screen, wherever the finger is
      let zoneY = small.height * MeterLayout.zoneFrom
      #expect(ml.after(CGPoint(x: small.midX, y: zoneY), in: small.size, aimable: true) == .zone)
      #expect(ml.after(CGPoint(x: 5, y: small.height - 2), in: small.size, aimable: false) == .zone)
      #expect(ml.after(CGPoint(x: small.midX, y: zoneY - 1), in: small.size, aimable: false) == nil)
      // a stroke from the zone is relative: the press point is the knob's home
      let press = CGPoint(x: small.midX, y: small.height * 0.8)
      let grab = press.y - m.yHome
      #expect(ml.unit(press, grab: grab) == meterPoint(arm: 0))
      let down = ml.unit(CGPoint(x: 30, y: press.y + 30 * m.scale), grab: grab)
      #expect(abs(atan2(down.x, down.y) * 180 / .pi - -30) < 1e-9)
    }
    #expect(MeterLayout.tapSlop == 10)
  }

  /// A stroke from the throw zone as BoardView feeds it: the press (the knob's
  /// home) on one frame, then the finger, already past the tap slop, on the next.
  @Test func zoneStrokeThrows() throws {
    let dt = 1.0 / 60
    let pitch = try PracticePitch(appVersion: "test")
    let m = try linear(small)
    let ml = MeterLayout.linear(m)
    let press = CGPoint(x: small.midX, y: small.height * 0.75)
    let grab = press.y - m.yHome
    let d = pitch.dial
    let back = try #require(d.powerLo.flatMap { lo in d.powerHi.map { (lo + $0) / 2 } })
    let stop = try #require(d.releaseLo.flatMap { lo in d.releaseHi.map { (lo + $0) / 2 } })
    pitch.beginDial()
    pitch.sample(ml.unit(press, grab: grab))
    try pitch.tick(dt)
    var y = press.y + 12  // the move that made it a drag
    while y < press.y + CGFloat(back) * m.scale {
      pitch.sample(ml.unit(CGPoint(x: press.x, y: y), grab: grab))
      try pitch.tick(dt)
      y = min(press.y + CGFloat(back) * m.scale, y + 400 * dt * m.scale)
    }
    #expect(pitch.dial.back > back - 8)
    while y > press.y - CGFloat(stop) * m.scale {
      y = max(press.y - CGFloat(stop) * m.scale, y - 2400 * dt * m.scale)
      pitch.sample(ml.unit(CGPoint(x: press.x - 20, y: y), grab: grab))
      try pitch.tick(dt)
    }
    pitch.sample(nil)
    try pitch.tick(dt)
    #expect(pitch.playing)
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
