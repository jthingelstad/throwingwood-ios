import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// The last throw's verdict never stops a player aiming (the owner, 2026-11-22: "the
/// display stays on the screen for a while keeping the player from being able to aim at
/// times. I wonder if our camera view should be a touch lower so the kubbs we are aiming
/// at are a little lower on the screen."): the thrower's view puts the far baseline at
/// 41% of a tall screen, the verdict stands in the band under the header, clear of the
/// target ring, the aim line near it, the tray, the minimap and the meter, upright and on
/// its side, both meters and sides, on the phones and an iPad, at larger text sizes too;
/// it goes at the first press of the aim, and otherwise after `Pacing.verdictShown`.
@MainActor struct VerdictLayoutTests {
  static let tall: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("16e", CGSize(width: 390, height: 844), ScreenInsets(top: 47, bottom: 34)),
    ("17 Pro Max", CGSize(width: 440, height: 956), ScreenInsets(top: 62, bottom: 34)),
    ("iPad mini", CGSize(width: 744, height: 1133), ScreenInsets(top: 24, bottom: 20)),
    ("iPad Pro 13-inch", CGSize(width: 1032, height: 1376), ScreenInsets(top: 24, bottom: 20)),
  ]

  /// Aims to hold it against: the first aim of a match (a base kubb at 8 m), the far
  /// corners, a field kubb's distance, a Kid match from the Kid line, and practice.
  static func aims() throws -> [(String, PitchSession)] {
    var out: [(String, PitchSession)] = []
    let first = try SceneLooksTests.match("day")
    out.append(("8 m", first))
    for (name, x, y) in [("far corner", 2.0, 8.0), ("field kubb", -1.0, 5.2), ("close", 0.6, 4.4)] {
      let app = try SceneLooksTests.match("day")
      try app.replan("setTarget", #"{"x":\#(x),"y":\#(y),"snap":false}"#)
      out.append((name, app))
    }
    out.append(("Kid match", try KidTests.kidMatch()))
    out.append(("practice", try PitchSession(appVersion: "test")))
    return out
  }

  @Test func theFarBaselineStandsAt41PercentUpright() throws {
    for (name, app) in try Self.aims() where name == "8 m" || name == "Kid match" || name == "practice" {
      for s in Self.tall {
        let far = try #require(app.scene.projection(s.size, app.camera).project(V3(0, 8, 0)))
        #expect(abs(far.y / s.size.height - PitchProjection.anchorAt) < 0.002, "\(name), \(s.name)")
      }
    }
  }

  @Test func theVerdictIsClearOfTheAimUpright() throws {
    for (name, app) in try Self.aims() {
      for s in Self.tall {
        for (meterKind, side) in [(MeterKind.clock, MeterSide.right), (.linear, .right), (.linear, .left)] {
          // the default text size, and the largest (the header two lines deeper, the
          // words and chips a third bigger)
          for large in [false, true] {
            let tag = "\(name), \(s.name), \(meterKind) \(side), \(large ? "large" : "default")"
            let header = s.safe.top + 66 + (large ? 44 : 0)
            let stack = WideLayout.verdictTall * (large ? 1.4 : 1)
            let aim = try #require(app.aimTop(in: s.size), "\(tag)")
            let band = WideLayout.verdictBand(size: s.size, safe: s.safe, headerBottom: header, aimTop: aim, tall: stack)
            // clear of the ring, the kubb in it and the arc near it
            #expect(band.maxY <= aim - WideLayout.verdictGap + 1e-9, "\(tag): \(band.maxY) over \(aim)")
            // at the default size the whole of it shows on every screen
            if !large { #expect(band.height >= WideLayout.verdictTall, "\(tag): \(band.height)") }
            #expect(band.height >= WideLayout.verdictLeast, "\(tag)")
            // the minimap, the meter and the tray
            let map = WideLayout.uprightMinimap(size: s.size, safe: s.safe, headerBottom: header)
            #expect(band.maxX <= map.minX - WideLayout.verdictGap + 1e-9, "\(tag)")
            #expect(band.minX >= s.safe.left + 12)
            let meter = MeterLayout.make(
              kind: meterKind, side: side, bounds: CGRect(origin: .zero, size: s.size), safeTop: s.safe.top,
              safeBottom: s.safe.bottom)
            let box = WideLayout.meterBox(meter, size: s.size, safe: s.safe, side: side)
            #expect(!band.intersects(box), "\(tag): meter \(box)")
            let tray = Tray.upright(size: s.size, safe: s.safe, meter: meter, side: side)
            #expect(!band.intersects(tray), "\(tag): tray \(tray)")
            // the lower placement keeps what is aimed at above the clock's reach
            if let clock = meter.clock, let m = app.scene.marker,
              let c = app.scene.projection(s.size, app.camera).project(m.point)
            {
              #expect(c.y < clock.center.y - clock.radius * 1.25, "\(tag)")
            }
          }
        }
      }
    }
  }

  @Test func theVerdictIsClearOfTheAimOnItsSide() throws {
    for (name, app) in try Self.aims() {
      for p in WideLayoutTests.iPhones + WideLayoutTests.iPads.filter { WideLayout.isWide($0.size) } {
        for (meterKind, side) in [(MeterKind.clock, MeterSide.right), (.clock, .left), (.linear, .right), (.linear, .left)] {
          let tag = "\(name), \(p.name), \(meterKind) \(side)"
          let meter = MeterLayout.make(
            kind: meterKind, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: p.safe.top,
            safeBottom: p.safe.bottom, safeLeft: p.safe.left, safeRight: p.safe.right)
          let room = WideLayout.captionRoom(size: p.size, safe: p.safe, meter: meter, side: side)
          let aim = app.aimTop(in: p.size)
          let r = WideLayout.verdictClear(room, aimTop: aim)
          if let aim, room.minY + WideLayout.verdictLeast <= aim - WideLayout.verdictGap {
            #expect(r.maxY <= aim - WideLayout.verdictGap + 1e-9, "\(tag)")
          }
          #expect(r.height >= WideLayout.verdictLeast && r.maxY <= room.maxY + 1e-9, "\(tag)")
        }
      }
    }
  }

  /// The first press of the aim takes the verdict away; untouched it stays
  /// `Pacing.verdictShown` (3.5 s, 6 before) from the throw coming to rest.
  @Test func theVerdictGoesAtTheFirstPressOrAfterItsTime() throws {
    #expect(Pacing.verdictShown == 3.5)
    func thrown() throws -> PitchSession {
      let app = try PitchSession(appVersion: "test")
      let dial = app.dial
      for p in try armPoints(dial) {
        app.sample(p)
        try app.tick(1.0 / 60)
      }
      app.sample(nil)
      for _ in 0..<2000 where app.result == nil { try app.tick(1.0 / 60) }
      try #require(app.result != nil)
      return app
    }
    let idle = try thrown()
    var t = 0.0
    while idle.result != nil && t < 10 {
      try idle.tick(0.05)
      t += 0.05
    }
    #expect(abs(t - Pacing.verdictShown) < 0.11, "\(t)")
    // a press of the aim: a tap, a plate, a slider, STAND
    for press in ["target", "plate", "slide", "stand"] {
      let app = try thrown()
      for _ in 0..<100 where app.playing { try app.tick(1.0 / 60) }
      #expect(app.result != nil && app.canAim, "\(press)")
      switch press {
      case "target": app.verdictAway()  // BoardView: any press while the player may aim
      case "plate": try app.tapPlate(.tilt)
      case "slide": app.slide(.side, to: 0.6, phase: .down)
      default: app.stand(fx: 0.5, fy: 0.5, phase: .down)
      }
      #expect(app.result == nil, "\(press)")
    }
  }

  /// The practice throw's arm, as RendererTests drives it: back to the power band's
  /// middle, then a fast flick to the release band's middle.
  private func armPoints(_ d: DialState) throws -> [CGPoint] {
    let dt = 1.0 / 60
    let back = try #require(d.powerLo.flatMap { lo in d.powerHi.map { (lo + $0) / 2 } })
    let stop = try #require(d.releaseLo.flatMap { lo in d.releaseHi.map { (lo + $0) / 2 } })
    var a = -5.0
    var angles = [0.0, a]
    while a > -back {
      a = max(-back, a - 400 * dt)
      angles.append(a)
    }
    while a < stop {
      a = min(stop, a + 2400 * dt)
      angles.append(a)
    }
    return angles.map { a in CGPoint(x: sin(a * .pi / 180), y: cos(a * .pi / 180)) }
  }
}
