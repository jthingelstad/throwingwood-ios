import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// A phone on its side: the raise and punishment panel is a bar along the bottom
/// (WideLayout.bar, the web's game.css .panel and layout.js stillFit). The bar
/// never covers the kubb being raised, either end's number or a press or drag on
/// the kubb, nor the ground a punishment kubb may go on; and it stays inside the
/// safe area. The heights are the app's bar as measured in the review (one line
/// and two lines of words), a third line, and a bar far taller than any.
@MainActor struct StillBarTests {
  static let heights: [CGFloat] = [WideLayout.barOneLine, WideLayout.barTwoLines, 92, 140]

  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  @Test func theBarIsInsideTheSafeAreaAlongTheBottom() {
    for p in WideLayoutTests.phones {
      #expect(WideLayout.isShort(p.size), "\(p.name)")
      #expect(!WideLayout.isShort(CGSize(width: p.size.height, height: p.size.width)))
      for h in Self.heights {
        let b = WideLayout.bar(height: h, size: p.size, safe: p.safe)
        // 12 pt inside the safe area's sides, at most 760 wide and centred between them
        let room = p.size.width - p.safe.left - p.safe.right - 24
        #expect(b.width == min(760, room), "\(p.name)")
        #expect(b.minX >= p.safe.left + 12 && b.maxX <= p.size.width - p.safe.right - 12)
        #expect(abs((b.minX - p.safe.left - 12) - (p.size.width - p.safe.right - 12 - b.maxX)) < 1e-9)
        #expect(b.maxY == p.size.height - p.safe.bottom - 8 && b.height == h)
        #expect(b.minY >= p.safe.top)
      }
    }
    // a wider screen: at most 760 pt, centred between the safe area's sides
    let b = WideLayout.bar(
      height: 71, size: CGSize(width: 1180, height: 440), safe: ScreenInsets(left: 40, bottom: 20, right: 0))
    #expect(b.width == 760 && abs(b.midX - (40 + 12 + (1180 - 12 - 40 - 12) / 2)) < 1e-9)
    // taller screens keep the panel they had
    #expect(!WideLayout.isShort(CGSize(width: 1180, height: 820)))
  }

  @Test func theBarStaysUnderThePunishmentHalfsNearBaseline() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("punish"), save: nil)
    #expect(abs((app.scene.stillLowest ?? 0) - 164.0) < 0.05)  // the web's punishNearY
    for p in WideLayoutTests.phones {
      app.stillFloor = nil
      let before = app.scene.projection(p.size, app.camera)
      for h in Self.heights {
        let bar = WideLayout.bar(height: h, size: p.size, safe: p.safe)
        app.stillFloor = Double(p.size.height - bar.minY)
        let pr = app.scene.projection(p.size, app.camera)
        let base = try #require(pr.project(V3(0, 0, 0)))
        // the whole baseline is level, and the half above it
        for x in [-2.5, -1, 1, 2.5] {
          #expect(abs(try #require(pr.project(V3(x, 0, 0))).y - base.y) < 1e-9)
        }
        #expect(base.y + WideLayout.stillClear <= bar.minY + 1e-9, "\(p.name) bar \(h)")
        let unmoved = try #require(before.project(V3(0, 0, 0)))
        if unmoved.y + WideLayout.stillClear <= bar.minY {
          #expect(base == unmoved, "\(p.name) bar \(h): clear already, no lift")
        } else {
          #expect(abs(base.y + WideLayout.stillClear - bar.minY) < 1e-9, "lifted by just the shortfall")
          #expect(pr.k == before.k, "the same scale")
        }
        // up to three lines of words the king's end of the half stays on the screen (a
        // bar far taller lifts it off the top: the baseline still wins); a finger
        // lands where it points
        if h <= 92 { #expect(try #require(pr.project(V3(0, 4, 0.3))).y > 0, "\(p.name) bar \(h)") }
        let g = try #require(pr.ground(CGPoint(x: p.size.width / 2, y: base.y - 20)))
        #expect(abs(try #require(pr.project(g)).y - (base.y - 20)) < 1e-6)
      }
    }
    // a bar under the measured ones does not lift either review phone
    for p in WideLayoutTests.phones {
      let bar = WideLayout.bar(height: WideLayout.barTwoLines, size: p.size, safe: p.safe)
      #expect(WideLayout.stillLift(size: p.size, lowest: 164.0, floor: Double(p.size.height - bar.minY)) == 0)
    }
  }

  @Test func theBarNeverCoversTheKubbBeingRaisedItsNumbersOrADragOnIt() throws {
    for name in ["raise", "raise-many", "raise-refused"] {
      let app = try PitchSession(appVersion: "test")
      try app.restore(fixture(name), save: nil)
      for p in WideLayoutTests.phones {
        for h in Self.heights {
          let bar = WideLayout.bar(height: h, size: p.size, safe: p.safe)
          app.stillFloor = Double(p.size.height - bar.minY)
          // the player's side view, as the board sends it (engine 1.4.1's held raise camera
          // is fitted to its box, kept over the bar)
          app.sideView(size: p.size, safe: p.safe)
          let top = bar.minY - WideLayout.stillClear
          let g = try #require(app.raiseGeometry(in: p.size))
          // the kubb, and a press within RaiseTouch.margin of it
          #expect(g.outline.map(\.y).max()! + RaiseTouch.margin <= top + 1e-9, "\(name) \(p.name) bar \(h)")
          for e in app.raiseEnds(in: p.size) {
            #expect(e.label.y + RaiseTouch.numberR <= top + 1e-9, "\(name) \(p.name) number \(e.index + 1)")
            #expect(e.footprint.y <= top)
            #expect(e.label.x - RaiseTouch.numberR > 0 && e.label.x + RaiseTouch.numberR < p.size.width)
          }
          // a drag along the kubb as drawn, its whole travel from either cap
          let a = g.caps[0], b = g.caps[1]
          let L = a.distance(to: b)
          // the held raise camera (engine 1.4, `need.camera`) draws the kubb small, so its
          // whole travel is the 90 pt floor: a drag needs only past half of it to stand the
          // kubb, so that much stays on the screen and over the bar
          let full = max(RaiseTouch.travelMin, L * RaiseTouch.travelK)
          let travel = app.need?.camera == nil ? full : full * 0.6
          for (from, d) in [(a, CGPoint(x: (a.x - b.x) / L, y: (a.y - b.y) / L)), (b, CGPoint(x: (b.x - a.x) / L, y: (b.y - a.y) / L))] {
            let end = CGPoint(x: from.x + d.x * travel, y: from.y + d.y * travel)
            #expect(end.y + RaiseTouch.margin <= top && end.x > 0 && end.x < p.size.width, "\(name) \(p.name) drag")
          }
        }
      }
    }
  }

  @Test func uprightAndTallerScreensKeepTheirFraming() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("punish"), save: nil)
    // the phones upright, a tablet, and the review iPads either way (a tall iPad keeps the panel)
    for size in [
      CGSize(width: 390, height: 844), CGSize(width: 440, height: 956), CGSize(width: 1180, height: 820),
      CGSize(width: 744, height: 1133), CGSize(width: 1133, height: 744),
      CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032),
    ] {
      #expect(!WideLayout.isShort(size))
      app.stillFloor = nil
      let before = try #require(app.scene.projection(size, app.camera).project(V3(0, 0, 0)))
      app.stillFloor = 300
      #expect(try #require(app.scene.projection(size, app.camera).project(V3(0, 0, 0))) == before)
    }
  }
}
