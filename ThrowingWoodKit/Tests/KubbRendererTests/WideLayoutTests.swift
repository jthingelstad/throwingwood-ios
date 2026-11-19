import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// A phone on its side (WideLayout.swift): the web's wide arrangement on both
/// review phones held either way, with both meters and both sides.
@MainActor struct WideLayoutTests {
  /// The review phones on their side, turned left and turned right: the points
  /// and the safe area the iOS 26.2 simulator gives the app (the review's
  /// layout dump, 2026-11-19). The sensor housing's inset is on both sides
  /// whichever way the phone is turned, the home indicator's at the bottom, and
  /// there is no status bar.
  static let phones: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPhone 16e turned left", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 47, bottom: 20, right: 47)),
    ("iPhone 16e turned right", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 47, bottom: 20, right: 47)),
    ("iPhone 17 Pro Max turned left", CGSize(width: 956, height: 440), ScreenInsets(top: 0, left: 62, bottom: 20, right: 62)),
    ("iPhone 17 Pro Max turned right", CGSize(width: 956, height: 440), ScreenInsets(top: 0, left: 62, bottom: 20, right: 62)),
    // a phone whose housing is on one side only, in case iOS ever reports it so
    ("a lopsided phone", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 59, bottom: 21, right: 0)),
  ]
  /// The plan block as the app frames it.
  static let block = WideLayout.planBlock

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
    #expect(r.maxX == p.size.width - 47 - 14 && r.maxY == p.size.height - p.safe.bottom - 7)
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
            ("minimap", WideLayout.plan(meter: meter, size: p.size, safe: s, side: side).minimap),
            ("meter", WideLayout.meterBox(meter, size: p.size, safe: s, side: side)),
            ("plans", WideLayout.plan(meter: meter, size: p.size, safe: s, side: side).block),
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
          // the plan block is at the screen's edge away from the meter, 8 in from
          // the safe area, its foot 10 above the meter's box's foot
          let plan = WideLayout.plan(meter: meter, size: p.size, safe: s, side: side)
          let box = WideLayout.meterBox(meter, size: p.size, safe: s, side: side)
          #expect(plan.edge == (side == .right ? .left : .right), "\(what)")
          #expect(
            side == .right
              ? plan.block.minX == s.left + 8 : plan.block.maxX == p.size.width - s.right - 8, "\(what)")
          #expect(plan.block.maxY == box.maxY - WideLayout.planLift)
          // the minimap keeps its corner's y and size, 12 from the block's inner side
          let corner = WideLayout.minimap(size: p.size, safe: s, side: side)
          #expect(plan.minimap.size == corner.size && plan.minimap.minY == corner.minY)
          #expect(
            side == .right
              ? plan.minimap.minX == plan.block.maxX + 12 : plan.minimap.maxX == plan.block.minX - 12)
          // nothing on the throwing line: the block and the minimap stop 24 short
          // of the screen's centre, the meter is on the other half
          let centre = p.size.width / 2
          for f in [plan.block, plan.minimap] {
            #expect(side == .right ? f.maxX <= centre - 24 : f.minX >= centre + 24, "\(what): \(f)")
          }
          #expect(side == .right ? box.minX > centre : box.maxX < centre)
          // and clear of the clock's outer touch zone (a press beside the ring)
          if let c = meter.clock {
            for f in [plan.block, plan.minimap] {
              #expect(
                distance(c.center, f) > c.radius * ClockMeter.touchReach, "\(what): \(f) in the clock's reach")
            }
          }
          // the meter has not moved for it
          #expect(meter == MeterLayout.make(
            kind: kind, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: s.top,
            safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right))
          if let c = meter.clock { #expect(c == WideLayout.clock(size: p.size, safe: s, side: side)) }
        }
      }
    }
  }

  // MARK: The same game on an iPad

  /// The review iPads on their side, as the iOS 26.2 simulator gives them to the
  /// app in full screen (the review's layout dump, 2026-11-19): the status bar's
  /// inset at the top and the home indicator's at the bottom, none at the sides.
  static let iPads: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPad mini (A17 Pro) on its side", CGSize(width: 1133, height: 744), ScreenInsets(top: 32, bottom: 20)),
    ("iPad Pro 13-inch (M5) on its side", CGSize(width: 1376, height: 1032), ScreenInsets(top: 32, bottom: 20)),
  ]

  /// Every frame of the wide arrangement inside the safe area and none meeting
  /// another, the clock's ring and rim on the screen, and the plan block and the
  /// minimap off the throwing line: what holds on a phone holds on any wide screen.
  private func holds(_ name: String, _ size: CGSize, _ s: ScreenInsets, kind: MeterKind, side: MeterSide) {
    let safeRect = CGRect(
      x: s.left, y: s.top, width: size.width - s.left - s.right, height: size.height - s.top - s.bottom)
    let meter = MeterLayout.make(
      kind: kind, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: s.top,
      safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
    let plan = WideLayout.plan(meter: meter, size: size, safe: s, side: side)
    let frames: [(String, CGRect)] = [
      ("rail", WideLayout.rail(size: size, safe: s)),
      ("menu", WideLayout.menu(size: size, safe: s)),
      ("minimap", plan.minimap),
      ("meter", WideLayout.meterBox(meter, size: size, safe: s, side: side)),
      ("plans", plan.block),
    ]
    let what = "\(name) \(Int(size.width)) x \(Int(size.height)) \(kind) \(side)"
    for (n, f) in frames {
      #expect(safeRect.contains(f), "\(what): \(n) \(f) outside \(safeRect)")
    }
    for i in frames.indices {
      for j in frames.indices where j > i {
        #expect(!frames[i].1.intersects(frames[j].1), "\(what): \(frames[i].0) meets \(frames[j].0)")
      }
    }
    if let c = meter.clock {
      #expect(c.center.y + c.radius * 1.12 <= size.height - s.bottom, "\(what)")
      #expect(
        c.center.x - c.radius * 1.12 >= s.left && c.center.x + c.radius * 1.12 <= size.width - s.right, "\(what)")
    }
    // At the far edge the block and the minimap are clear of a press beside the
    // ring. Back beside the meter (a window too narrow, the web's planAt) the
    // block is in that reach on the web too: its plates are above the pitch, so
    // a press on one is the plate's.
    if plan.edge != nil, let c = meter.clock {
      for f in [plan.block, plan.minimap] {
        #expect(distance(c.center, f) > c.radius * ClockMeter.touchReach, "\(what): \(f) in the clock's reach")
      }
    }
    if plan.edge != nil {
      let centre = size.width / 2
      for f in [plan.block, plan.minimap] {
        #expect(side == .right ? f.maxX <= centre - 24 : f.minX >= centre + 24, "\(what): \(f)")
      }
    }
  }

  @Test func anIPadOnItsSideIsTheWideArrangementWithTheLinearMetersRoom() throws {
    for p in Self.iPads {
      #expect(WideLayout.isWide(p.size) && !WideLayout.isShort(p.size))
      for side in MeterSide.allCases {
        // the web's linearBox: a wide screen's track is 450 pt, at its edge
        let m = try #require(
          LinearMeter.layout(size: p.size, safeTop: p.safe.top, safeBottom: p.safe.bottom, side: side), "\(p.name)")
        #expect(m.box.height == 450 && m.travel >= 320)
        #expect(side == .left ? m.box.minX == 7 : m.box.maxX == p.size.width - 7)
        for kind in MeterKind.allCases {
          holds(p.name, p.size, p.safe, kind: kind, side: side)
          // the plan block at the edge away from the meter: two hands, as on a phone
          let meter = MeterLayout.make(
            kind: kind, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: p.safe.top,
            safeBottom: p.safe.bottom)
          let plan = WideLayout.plan(meter: meter, size: p.size, safe: p.safe, side: side)
          #expect(plan.edge == (side == .right ? .left : .right), "\(p.name) \(kind) \(side)")
          #expect(plan.block.size == WideLayout.planBlock)
        }
      }
      // the clock is the web's wide clock: S = min(0.28 W, 0.46 H, 380), not a phone's
      let box = WideLayout.clockBox(size: p.size, safe: p.safe, side: .right)
      #expect(abs(box.width - min(p.size.width * 0.28, p.size.height * 0.46, 380)) < 1e-9)
    }
  }

  @Test func anIPadUprightIsThePhoneLayoutWithTheLinearMeterAtItsCap() throws {
    for p in Self.iPads {
      let size = CGSize(width: p.size.height, height: p.size.width)
      #expect(!WideLayout.isWide(size))
      let m = try #require(LinearMeter.layout(size: size, safeTop: 32, safeBottom: 20, side: .right))
      #expect(abs(m.box.height - 450) < 0.001 && m.travel >= 320)
      // the upright clock keeps the phone's cap: the controls do not grow
      let c = ClockMeter(bounds: CGRect(origin: .zero, size: size), bottomInset: 20)
      #expect(c.radius == 114)
    }
  }

  /// An iPad's window can be any size (iPadOS 26): every wide one from a phone's
  /// on its side to a 13-inch iPad's, in full screen (the status bar's inset)
  /// and in a window (10 pt, or 53 under the window's controls).
  @Test func everyWideWindowHolds() {
    let insets = [
      ScreenInsets(top: 32, bottom: 20), ScreenInsets(top: 10, bottom: 10), ScreenInsets(top: 53, bottom: 10),
    ]
    var checked = 0
    for w in stride(from: CGFloat(480), through: 1400, by: 20) {
      for h in stride(from: CGFloat(380), through: 1040, by: 20) {
        let size = CGSize(width: w, height: h)
        guard WideLayout.isWide(size) else { continue }
        for s in insets {
          for kind in MeterKind.allCases {
            for side in MeterSide.allCases {
              holds("window", size, s, kind: kind, side: side)
              checked += 1
            }
          }
        }
      }
    }
    #expect(checked > 10_000)
  }

  /// Upright windows, from a phone's width to a 13-inch iPad's: the phone's
  /// layout, its clock no bigger than the phone's cap, the linear meter only
  /// with its 320 pt of track and never over 450 pt, both inside the window.
  @Test func everyUprightWindowKeepsThePhonesMeters() {
    for w in stride(from: CGFloat(320), through: 1040, by: 20) {
      for h in stride(from: CGFloat(480), through: 1380, by: 20) {
        let size = CGSize(width: w, height: h)
        guard !WideLayout.isWide(size) else { continue }
        let c = ClockMeter(bounds: CGRect(origin: .zero, size: size), bottomInset: 20)
        #expect(c.radius <= 114)
        #expect(c.center.y + c.radius * 1.12 <= h - 20 && c.center.x - c.radius * 1.12 >= 0)
        for side in MeterSide.allCases {
          if let m = LinearMeter.layout(size: size, safeTop: 53, safeBottom: 10, side: side) {
            #expect(m.travel >= 320 && m.box.height <= 450 + 0.001)
            #expect(m.box.minX >= 0 && m.box.maxX <= w && m.box.minY >= 53 && m.box.maxY <= h - 10)
          }
        }
      }
    }
  }

  /// The nearest a rect comes to a point.
  private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
    hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
  }

  @Test func theBlockIsTheWebsAtTheFarEdgeMirroredForAClockAtTheLeft() {
    // the web's rects (planAt) for its 202 x 168 block, its insets 59 a side and
    // 21 at the bottom: x and the foot are the same rule
    let web = CGSize(width: 202, height: 168)
    let safe = ScreenInsets(top: 0, left: 59, bottom: 21, right: 59)
    func at(_ size: CGSize, _ side: MeterSide) -> WideLayout.Plan {
      let m = MeterLayout.clock(WideLayout.clock(size: size, safe: safe, side: side))
      return WideLayout.plan(block: web, meter: m, size: size, safe: safe, side: side)
    }
    func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.05 }
    let right = at(CGSize(width: 852, height: 393), .right)
    #expect(right.edge == .left && right.block == CGRect(x: 67, y: 187, width: 202, height: 168))
    #expect(near(right.minimap.minX, 281) && near(right.minimap.width, 62.9))
    let left = at(CGSize(width: 852, height: 393), .left)
    #expect(left.edge == .right && left.block == CGRect(x: 583, y: 187, width: 202, height: 168))
    #expect(near(left.minimap.minX, 508.1))
    let big = at(CGSize(width: 932, height: 430), .right)
    #expect(big.block == CGRect(x: 67, y: 224, width: 202, height: 168))
    #expect(near(big.minimap.minX, 281) && near(big.minimap.width, 68.8))
  }

  @Test func aScreenTooNarrowForTheBlockAndMinimapOffTheLineKeepsItBesideTheMeter() {
    // just wide (H = W), the block and minimap would cross the centre
    let size = CGSize(width: 420, height: 420)
    for side in MeterSide.allCases {
      let m = MeterLayout.clock(WideLayout.clock(size: size, safe: ScreenInsets(), side: side))
      let plan = WideLayout.plan(meter: m, size: size, safe: ScreenInsets(), side: side)
      #expect(plan.edge == nil)
      #expect(plan.block == WideLayout.plans(block: Self.block, meter: m, size: size, safe: ScreenInsets(), side: side))
      #expect(plan.minimap == WideLayout.minimap(size: size, safe: ScreenInsets(), side: side))
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
