import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// A press on the target's ring is always the aim, and the upright throw zone narrows to
/// the meter's half while the ring is in it (the owner, 2026-11-27, from an 11-inch iPad:
/// "On iPad I'm trying to move the drill target and when I tap it is activating the throw
/// instead. I can't find a tap target to move the drill location."). TargetRing.swift,
/// MeterLayout.start; docs/RENDER.md "The meter".
@MainActor struct TargetRingTests {
  /// Screens held upright: the 11-inch iPad Pro the report came from (834 x 1194), the
  /// review iPads upright (WideLayoutTests.iPads turned) and the 16e.
  static let upright: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPad Pro 11-inch upright", CGSize(width: 834, height: 1194), ScreenInsets(top: 24, bottom: 20)),
    ("iPad mini (A17 Pro) upright", CGSize(width: 744, height: 1133), ScreenInsets(top: 32, bottom: 20)),
    ("iPad Pro 13-inch (M5) upright", CGSize(width: 1032, height: 1376), ScreenInsets(top: 32, bottom: 20)),
    ("iPhone 16e", CGSize(width: 390, height: 844), ScreenInsets(top: 47, bottom: 34)),
  ]

  private func session(_ fixture: String) throws -> PitchSession {
    let file = try #require(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures/solo"))
    let app = try PitchSession(appVersion: "test")
    try app.restore(String(contentsOf: file, encoding: .utf8), save: nil)
    app.dismissHandoff()
    return app
  }

  private func linear(_ size: CGSize, _ s: ScreenInsets, _ side: MeterSide) throws -> MeterLayout {
    let m = MeterLayout.make(
      kind: .linear, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: s.top, safeBottom: s.bottom,
      safeLeft: s.left, safeRight: s.right)
    _ = try #require(m.linear)
    return m
  }

  /// The touch target is the drawn ring and 10 pt round it, never under 44 pt across.
  @Test func theRingsTouchTargetIsItsShapeAndAMargin() {
    // a ring drawn 120 x 40 (an ellipse, as a ground circle seen from the thrower)
    let c = CGPoint(x: 200, y: 600)
    let outline = (0..<48).map { i -> CGPoint in
      let a = Double(i) / 48 * 2 * .pi
      return CGPoint(x: c.x + 60 * cos(a), y: c.y + 20 * sin(a))
    }
    let ring = TargetRing(center: c, outline: outline)
    #expect(ring.contains(c) && ring.contains(CGPoint(x: c.x + 55, y: c.y)))
    #expect(ring.contains(CGPoint(x: c.x + 69, y: c.y)) && !ring.contains(CGPoint(x: c.x + 71, y: c.y)))
    // the ring is 40 tall: the least, 44, holds at its centre, and the margin beyond
    #expect(ring.contains(CGPoint(x: c.x, y: c.y + 29)) && !ring.contains(CGPoint(x: c.x, y: c.y + 31)))
    // a ring drawn tiny is still 44 across
    let tiny = TargetRing(center: c, outline: (0..<8).map { CGPoint(x: c.x + 3 * cos(Double($0)), y: c.y + 1 * sin(Double($0))) })
    #expect(tiny.contains(CGPoint(x: c.x + 21.9, y: c.y)) && tiny.contains(CGPoint(x: c.x, y: c.y - 21.9)))
    #expect(!tiny.contains(CGPoint(x: c.x + 23, y: c.y)) && !tiny.contains(CGPoint(x: c.x, y: c.y + 23)))
  }

  /// The reported state: a kubb at the advantage line, its ring low on the screen and in
  /// the upright throw zone (0.72 of the 11-inch's height). A press on the ring is the
  /// aim, upright, for both sides; the knob still wins; a press on the other half in the
  /// zone aims, and only the meter's half strokes.
  @Test func aPressOnTheRingInTheZoneAims() throws {
    let app = try session("advantage")
    for p in Self.upright {
      let ring = try #require(app.targetRing(in: p.size), "\(p.name)")
      #expect(ring.center.y >= p.size.height * MeterLayout.zoneFrom, "\(p.name): ring at \(ring.center.y / p.size.height)")
      for side in MeterSide.allCases {
        let meter = try linear(p.size, p.safe, side)
        let m = try #require(meter.linear)
        let what = "\(p.name) \(side)"
        func start(_ q: CGPoint) -> MeterLayout.Start {
          meter.start(q, in: p.size, ring: ring, stance: nil, aimable: app.tapCouldAim(q, size: p.size))
        }
        #expect(meter.zoneNarrows(ring: ring, in: p.size), "\(what)")
        // the ring: its centre, its rim and 8 pt outside its rim at either end
        let b = ring.bounds
        for q in [ring.center, CGPoint(x: b.minX + 1, y: ring.center.y), CGPoint(x: b.maxX - 1, y: ring.center.y),
          CGPoint(x: b.minX - 8, y: ring.center.y), CGPoint(x: b.maxX + 8, y: ring.center.y),
          CGPoint(x: ring.center.x, y: b.maxY + 8)]
        {
          #expect(start(q) == .aim, "\(what): \(q) on the ring")
        }
        // without the ring (as before) the same press was the zone's: the bug
        #expect(meter.after(ring.center, in: p.size, aimable: true) == .zone, "\(what)")
        // the knob, at its home, still wins wherever the ring is
        #expect(start(CGPoint(x: m.knobX, y: m.yHome)) == .meter(.meter(grab: 0)), "\(what)")
        // the zone is the meter's half while the ring is in it: low on the other half aims,
        // low on the meter's half (off the ring) strokes
        let low = p.size.height - p.safe.bottom - 4
        let far = side == .right ? p.size.width * 0.1 : p.size.width * 0.9
        let near = side == .right ? p.size.width * 0.5 + 2 : p.size.width * 0.5 - 2
        #expect(start(CGPoint(x: far, y: low)) == .aim, "\(what): the other half")
        #expect(!ring.contains(CGPoint(x: near, y: low)))
        #expect(start(CGPoint(x: near, y: low)) == .meter(.zone), "\(what): the meter's half")
        // above the zone nothing changed: the pitch's aim
        #expect(start(CGPoint(x: near, y: p.size.height * MeterLayout.zoneFrom - 1)) == .aim)
      }
    }
  }

  /// A drag that starts on the ring moves the circle by the finger's travel and never
  /// feeds the dial: the press is the aim's from its start, so no stroke begins.
  @Test func aDragFromTheRingMovesTheAimAndNeverSamplesTheDial() throws {
    for p in Self.upright {
      let app = try session("advantage")
      let ring = try #require(app.targetRing(in: p.size))
      let meter = try linear(p.size, p.safe, .right)
      let before = try #require(app.scene.marker)
      let dial = app.dial
      #expect(meter.start(ring.center, in: p.size, ring: ring, stance: nil, aimable: true) == .aim)
      // BoardView's aim drag: past AimDrag.slop, then the moves, then the lift
      for _ in 0..<6 {
        try app.nudgeAim(by: CGVector(dx: 12, dy: -6))
        try app.tick(1.0 / 60)
      }
      try app.settleAim()
      try app.tick(1.0 / 60)
      let after = try #require(app.scene.marker)
      #expect(after.x != before.x || after.y != before.y, "\(p.name): the circle moved")
      #expect(!app.playing, "\(p.name)")
      var input = app.input
      #expect(input.frame(after: 1.0 / 60) == nil, "\(p.name): the dial was never sampled")
      #expect(app.dial.phase == dial.phase && app.dial.back == 0 && app.dial.arm == dial.arm, "\(p.name)")
    }
  }

  /// The zone narrows only while the ring's centre is in it: a baton at the far baseline
  /// (its ring at 0.41 of the height) keeps the whole lower 40% as the zone. A wide
  /// screen's zone is the meter's half as before, and the clock has no zone to narrow.
  @Test func theZoneNarrowsOnlyWhenTheRingIsInIt() throws {
    let app = try session("aim")
    for p in Self.upright {
      let ring = try #require(app.targetRing(in: p.size))
      #expect(ring.center.y < p.size.height * MeterLayout.zoneFrom)
      for side in MeterSide.allCases {
        let meter = try linear(p.size, p.safe, side)
        #expect(!meter.zoneNarrows(ring: ring, in: p.size))
        let far = side == .right ? p.size.width * 0.1 : p.size.width * 0.9
        let q = CGPoint(x: far, y: p.size.height - p.safe.bottom - 4)
        #expect(meter.start(q, in: p.size, ring: ring, stance: nil, aimable: true) == .meter(.zone), "\(p.name) \(side)")
      }
      let clock = MeterLayout.make(
        kind: .clock, side: .right, bounds: CGRect(origin: .zero, size: p.size), safeTop: p.safe.top,
        safeBottom: p.safe.bottom)
      let low = try #require(try session("advantage").targetRing(in: p.size))
      #expect(!clock.zoneNarrows(ring: low, in: p.size))
    }
    // no ring: nothing narrows
    let p = Self.upright[0]
    #expect(!(try linear(p.size, p.safe, .right)).zoneNarrows(ring: nil, in: p.size))
    // on a wide screen: never
    for w in WideLayoutTests.iPads + WideLayoutTests.phones {
      for side in MeterSide.allCases {
        let meter = MeterLayout.make(
          kind: .linear, side: side, bounds: CGRect(origin: .zero, size: w.size), safeTop: w.safe.top,
          safeBottom: w.safe.bottom, safeLeft: w.safe.left, safeRight: w.safe.right)
        let ring = TargetRing(center: CGPoint(x: w.size.width / 2, y: w.size.height * 0.9), outline: [])
        #expect(!meter.zoneNarrows(ring: ring, in: w.size))
      }
    }
  }

  /// The clock: a press beside its ring that is on the target's ring aims; its own ring
  /// still turns the arm.
  @Test func besideTheClockTheTargetsRingAims() {
    let size = CGSize(width: 834, height: 1194)
    let clock = ClockMeter(bounds: CGRect(origin: .zero, size: size), bottomInset: 20)
    let cl = MeterLayout.clock(clock)
    let beside = clock.point(arm: 90, radius: clock.radius * 1.6)
    let ring = TargetRing(center: beside, outline: [])
    #expect(cl.after(beside, in: size, aimable: false) == .beside)
    #expect(cl.start(beside, in: size, ring: ring, stance: nil, aimable: false) == .aim)
    #expect(cl.start(beside, in: size, ring: nil, stance: nil, aimable: false) == .meter(.beside))
    // the clock's own ring wins over a target ring drawn on it
    let on = TargetRing(center: clock.center, outline: [])
    #expect(cl.start(clock.center, in: size, ring: on, stance: nil, aimable: true) == .meter(.meter(grab: 0)))
    // the thrower's mark comes before the ring, as it came before the meter's later claims
    #expect(cl.start(beside, in: size, ring: ring, stance: beside, aimable: true) == .stance)
  }

  /// On a wide screen the ring is the aim too: on the meter's half, and over the linear
  /// meter's body (which is throw zone there); the knob's channel still wins.
  @Test func onAWideScreenTheRingAims() throws {
    for w in WideLayoutTests.iPads + WideLayoutTests.phones {
      for side in MeterSide.allCases {
        let meter = MeterLayout.make(
          kind: .linear, side: side, bounds: CGRect(origin: .zero, size: w.size), safeTop: w.safe.top,
          safeBottom: w.safe.bottom, safeLeft: w.safe.left, safeRight: w.safe.right)
        let m = try #require(meter.linear)
        let half = CGPoint(x: side == .right ? w.size.width * 0.7 : w.size.width * 0.3, y: w.size.height * 0.5)
        let ring = TargetRing(center: half, outline: [])
        #expect(meter.start(half, in: w.size, ring: nil, stance: nil, aimable: true) == .meter(.zone))
        #expect(meter.start(half, in: w.size, ring: ring, stance: nil, aimable: true) == .aim, "\(w.name) \(side)")
        // the lane, off the knob's reach: throw zone, or the aim under a ring
        let lane = CGPoint(x: m.laneX, y: m.top + 4)
        #expect(meter.first(lane, wide: true) == .zone)
        #expect(
          meter.start(lane, in: w.size, ring: TargetRing(center: lane, outline: []), stance: nil, aimable: true) == .aim)
        let knob = CGPoint(x: m.knobX, y: m.yHome)
        #expect(
          meter.start(knob, in: w.size, ring: TargetRing(center: knob, outline: []), stance: nil, aimable: true)
            == .meter(.meter(grab: 0)))
      }
    }
  }

  /// While the zone is the meter's half, the nudge's fingertip strokes there.
  @Test func theNudgeStrokesInTheNarrowedZone() throws {
    let swing = NudgeSwing(back: NudgeTune().defaultBack, release: NudgeTune().defaultRelease)
    for p in Self.upright {
      for side in MeterSide.allCases {
        let m = try #require(try linear(p.size, p.safe, side).linear)
        let sweep = m.nudgeSweep(swing: swing, size: p.size, safeLeft: 0, safeRight: 0, narrow: true)
        let mid = p.size.width / 2
        #expect(side == .right ? sweep.minX >= mid : sweep.maxX <= mid, "\(p.name) \(side): \(sweep)")
        #expect(!sweep.intersects(m.cover), "\(p.name) \(side): \(sweep)")
        // the stroke starts in the zone (the flick's top may rise above it, as ever)
        let start = m.nudgePath(swing: swing, size: p.size, safeLeft: 0, safeRight: 0, narrow: true)
        let q = CGPoint(x: start.x, y: start.y0)
        #expect(q.y >= p.size.height * MeterLayout.zoneFrom, "\(p.name) \(side)")
        #expect(MeterLayout.linear(m).after(q, in: p.size, aimable: true) == .zone)
        // without narrowing, upright, the fingertip was on the other half on an iPad
        let wide = m.nudgePath(swing: swing, size: p.size, safeLeft: 0, safeRight: 0)
        if p.size.width > 700 { #expect(side == .right ? wide.x < mid : wide.x > mid, "\(p.name) \(side)") }
      }
    }
  }
}
