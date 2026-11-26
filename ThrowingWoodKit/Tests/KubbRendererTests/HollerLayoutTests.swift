import CoreGraphics
import Testing

@testable import KubbRenderer

/// HOLLER's panel and the hollers that arrive never go over the throw's meter or the
/// set-up tray, upright or on its side, either meter, either side (HollerLayout).
@MainActor struct HollerLayoutTests {
  private func meter(_ kind: MeterKind, _ side: MeterSide, _ size: CGSize, _ s: ScreenInsets) -> MeterLayout {
    MeterLayout.make(
      kind: kind, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: s.top,
      safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
  }

  @Test func theUprightPanelKeepsOffTheMeterAndTheTray() {
    for (name, size, safe) in TrayTests.upright {
      for kind in [MeterKind.clock, .linear] {
        for side in [MeterSide.left, .right] {
          let m = meter(kind, side, size, safe)
          let button = safe.top + 66 + 8 + 50
          let free = HollerLayout.upright(size: size, safe: safe, buttonBottom: button, meter: m, side: side)
          let box = HollerLayout.panel(in: free, height: 400)
          let tray = Tray.upright(size: size, safe: safe, meter: m, side: side)
          #expect(!box.isNull && box.minY > button, "\(name) \(kind) \(side)")
          #expect(!box.intersects(tray), "\(name) \(kind) \(side)")
          switch m {
          case .clock(let k):
            #expect(box.maxY <= k.center.y - k.radius - HollerLayout.promptHeight, "\(name) \(side)")
          case .linear(let l):
            #expect(!box.intersects(l.cover) && !box.intersects(l.tab), "\(name) linear \(side)")
          }
          #expect(box.width >= HollerLayout.minSize.width, "\(name) \(kind) \(side)")
        }
      }
    }
  }

  @Test func theWidePanelAndFeedKeepOffTheMeterAndTheTray() {
    for (name, size, safe) in WideLayoutTests.phones {
      for kind in [MeterKind.clock, .linear] {
        for side in [MeterSide.left, .right] {
          let m = meter(kind, side, size, safe)
          let button = WideLayout.shout(size: size, safe: safe, meter: m)
          let free = HollerLayout.wide(
            size: size, safe: safe, button: button, meter: m, side: side, trayWidth: WideLayout.trayWidth)
          let box = HollerLayout.panel(in: free, height: 400)
          let meterBox = WideLayout.meterBox(m, size: size, safe: safe, side: side)
          let plan = WideLayout.plan(meter: m, size: size, safe: safe, side: side, trayWidth: WideLayout.trayWidth)
          #expect(!box.isNull && !box.intersects(meterBox) && !box.intersects(plan.block), "\(name) \(kind) \(side)")
          let h = HollerLayout.feedHeight(size: size, safe: safe, button: button, meter: m, side: side, width: 240)
          let feed = CGRect(x: button.maxX - 240, y: button.maxY + 6, width: 240, height: h)
          #expect(!feed.intersects(meterBox) && !feed.intersects(m.linear?.tab ?? .null), "\(name) \(kind) \(side)")
          // room for a holler on every phone on its side
          #expect(h >= 50, "\(name) \(kind) \(side): \(h)")
        }
      }
    }
  }

  @Test func theFeedShowsTheNewestThatFit() {
    #expect(HollerLayout.feedCount(heights: [40, 60, 40], height: 100) == 1)
    #expect(HollerLayout.feedCount(heights: [40, 60, 40], height: 106) == 2)
    #expect(HollerLayout.feedCount(heights: [40, 60, 40], height: 39) == 0)
    #expect(HollerLayout.feedCount(heights: [40, 40], height: .infinity) == 2)
  }
}
