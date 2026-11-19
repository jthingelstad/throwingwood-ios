import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// A phone on its side (WideLayout.swift): the web's wide arrangement on both
/// review phones held either way, with both meters and both sides.
@MainActor struct WideLayoutTests {
  /// The review phones on their side: the points and the safe area iOS gives
  /// them in landscape (the sensor housing's inset on both sides, the home
  /// indicator's at the bottom, no status bar).
  static let phones: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPhone 16e", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 47, bottom: 21, right: 47)),
    ("iPhone 17 Pro Max", CGSize(width: 956, height: 440), ScreenInsets(top: 0, left: 62, bottom: 20, right: 62)),
  ]
  /// The plan block as the app draws it (ARC over SIDE VIEW beside TILT over
  /// STAND, shadows included), rounded up.
  static let block = CGSize(width: 206, height: 212)

  @Test func aPhoneOnItsSideIsWideAndUprightIsNot() {
    for p in Self.phones {
      #expect(WideLayout.isWide(p.size))
      #expect(!WideLayout.isWide(CGSize(width: p.size.height, height: p.size.width)))
    }
  }

  @Test func noPhoneOnItsSideHasTheLinearMetersRoomSoItShowsTheClock() {
    for p in Self.phones {
      for side in MeterSide.allCases {
        let s = p.safe
        #expect(
          LinearMeter.layout(
            size: p.size, safeTop: s.top, safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right,
            side: side) == nil)
        let m = MeterLayout.make(
          kind: .linear, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: s.top,
          safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
        #expect(m == .clock(WideLayout.clock(size: p.size, safe: s, side: side)))
      }
    }
  }

  @Test func aWideLinearMeterFollowsTheWebsRuleWhereThereIsTheRoom() throws {
    // a tablet-sized wide screen has the room: at its edge, under the rail or MENU
    let size = CGSize(width: 1180, height: 820)
    let safe = ScreenInsets(top: 24, bottom: 20)
    let left = try #require(
      LinearMeter.layout(size: size, safeTop: 24, safeBottom: 20, side: .left))
    #expect(left.box.minX == 7 && left.box.height == 450)
    #expect(left.box.minY >= WideLayout.rail(size: size, safe: safe).maxY)
    let right = try #require(
      LinearMeter.layout(size: size, safeTop: 24, safeBottom: 20, side: .right))
    #expect(right.box.maxX == size.width - 7)
  }

  @Test func theClockIsTheWebsWideClockInTheChosenCorner() {
    let p = Self.phones[0]
    let r = WideLayout.clockBox(size: p.size, safe: p.safe, side: .right)
    // S = min(0.28 W, 0.5 H, 380) = 195, 1.2 S tall, 14 in, its foot 7 over the safe area
    #expect(abs(r.width - 195) < 1e-9 && abs(r.height - 234) < 1e-9)
    #expect(r.maxX == p.size.width - 47 - 14 && r.maxY == p.size.height - 21 - 7)
    let c = WideLayout.clock(size: p.size, safe: p.safe, side: .right)
    #expect(abs(c.radius - (195 - 2 * 7.8) / 2.12) < 1e-9)
    let l = WideLayout.clock(size: p.size, safe: p.safe, side: .left)
    #expect(abs((p.size.width - l.center.x) - c.center.x) < 1e-9 && l.center.y == c.center.y)
    // about the size of the upright 16e's (86)
    #expect(c.radius > 80 && c.radius < 90)
  }

  @Test func nothingOverlapsAndAllIsInsideTheSafeArea() {
    for p in Self.phones {
      let safeRect = CGRect(
        x: p.safe.left, y: p.safe.top, width: p.size.width - p.safe.left - p.safe.right,
        height: p.size.height - p.safe.top - p.safe.bottom)
      for kind in MeterKind.allCases {
        for side in MeterSide.allCases {
          let s = p.safe
          let meter = MeterLayout.make(
            kind: kind, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: s.top,
            safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
          let frames: [(String, CGRect)] = [
            ("rail", WideLayout.rail(size: p.size, safe: s)),
            ("menu", WideLayout.menu(size: p.size, safe: s)),
            ("caption", WideLayout.caption(size: p.size, safe: s)),
            ("minimap", WideLayout.minimap(size: p.size, safe: s, side: side)),
            ("meter", WideLayout.meterBox(meter, size: p.size, safe: s, side: side)),
            ("plans", WideLayout.plans(block: Self.block, meter: meter, size: p.size, safe: s, side: side)),
          ]
          let what = "\(p.name) \(kind) \(side)"
          for (name, f) in frames {
            #expect(safeRect.contains(f), "\(what): \(name) \(f) outside \(safeRect)")
          }
          for i in frames.indices {
            for j in frames.indices where j > i {
              let (a, fa) = frames[i]
              let (b, fb) = frames[j]
              #expect(!fa.intersects(fb), "\(what): \(a) \(fa) meets \(b) \(fb)")
            }
          }
          // the ring and its rim are on the screen, clear of the home indicator
          if let c = meter.clock {
            #expect(c.center.y + c.radius * 1.12 <= p.size.height - s.bottom)
            #expect(c.center.x - c.radius * 1.12 >= s.left && c.center.x + c.radius * 1.12 <= p.size.width - s.right)
          }
          // the plan block is on the meter's inner side, its foot above the meter's
          let plans = WideLayout.plans(block: Self.block, meter: meter, size: p.size, safe: s, side: side)
          let box = WideLayout.meterBox(meter, size: p.size, safe: s, side: side)
          #expect(side == .right ? plans.maxX < box.minX : plans.minX > box.maxX)
          #expect(plans.maxY == box.maxY - WideLayout.planLift)
          let anchor = WideLayout.plansAnchor(meter: meter, size: p.size, safe: s, side: side)
          #expect(side == .right ? anchor.edge == p.size.width - plans.maxX : anchor.edge == plans.minX)
          #expect(anchor.bottom == p.size.height - plans.maxY)
        }
      }
    }
  }

  @Test func theUprightClockIsUnchanged() {
    let b = CGRect(x: 0, y: 0, width: 390, height: 844)
    #expect(
      MeterLayout.make(kind: .clock, side: .left, bounds: b, safeTop: 47, safeBottom: 34)
        == .clock(ClockMeter(bounds: b, bottomInset: 34)))
  }

  private func aiming() throws -> PitchSession {
    let file = try #require(
      Bundle.module.url(forResource: "aim", withExtension: "json", subdirectory: "Fixtures/solo"))
    let app = try PitchSession(appVersion: "test")
    try app.restore(String(contentsOf: file, encoding: .utf8), save: nil)
    app.dismissHandoff()
    return app
  }

  @Test func turningTheScreenLetsGoOfASliderAndTheRestOfThatDragIsIgnored() throws {
    let app = try aiming()
    let arc = app.arcDegrees
    app.slide(.arc, to: 0.9, phase: .down)
    #expect(app.held == .arc)
    app.cancelHeld()
    #expect(app.held == nil)
    // the same finger keeps moving and lifts: nothing is held or sent
    app.slide(.arc, to: 0.1, phase: .move)
    #expect(app.held == nil)
    app.slide(.arc, to: 0.1, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.arcDegrees == arc)
    // a new press works as ever
    app.slide(.arc, to: 0.8, phase: .down)
    #expect(app.held == .arc)
    app.slide(.arc, to: 0.8, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.arcDegrees != arc)
  }

  @Test func turningTheScreenLetsGoOfStand() throws {
    let app = try aiming()
    let before = try #require(app.scene.thrower)
    app.stand(fx: 0.1, fy: 0.9, phase: .down)
    app.cancelHeld()
    #expect(!app.standHeld)
    app.stand(fx: 0.1, fy: 0.9, phase: .move)
    app.stand(fx: 0.1, fy: 0.9, phase: .up)
    try app.tick(1.0 / 60)
    #expect(try #require(app.scene.thrower).x == before.x)
    #expect(!app.standHeld)
  }
}
