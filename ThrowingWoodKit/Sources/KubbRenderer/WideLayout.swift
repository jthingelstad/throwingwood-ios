import CoreGraphics
import Foundation

// A phone on its side (Jamie, 2026-11-19: "Given we have a widescreen view for
// web, can we extend that to support iPhone rotated display?"). The web's wide
// arrangement (src/game/layout.js, its numbers): the clock lower right or lower
// left by Meter side, the minimap in the other bottom corner, the plan (TILT,
// STAND, ARC, SIDE VIEW) in one block beside the meter with ARC next to it, the
// turn rail top left and MENU top right. The linear meter goes at its edge only
// where its track has `LinearMeter.Tune.minTravel`, which no iPhone on its side
// has, so there the clock is shown, as on the web. The camera is the thrower's
// view as ever: the projection's wide rule (the 400 x 240 frame fitted whole).
//
// Pure: the app places its views on these frames, and the tests check the same
// frames for overlaps and the safe areas.

/// The safe area's insets, in points.
public struct ScreenInsets: Equatable, Sendable {
  public var top, left, bottom, right: CGFloat
  public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
    self.top = top
    self.left = left
    self.bottom = bottom
    self.right = right
  }
}

public enum WideLayout {
  /// H / W above this is a tall screen (the web's `tallFrom`, the projection's rule).
  public static let tallFrom: CGFloat = 1.05
  /// pt from the edges, plus the safe area (the web's `margin`).
  public static let margin: CGFloat = 14
  /// The turn rail's plate at the top left, and MENU's at the top right.
  public static let railSize = CGSize(width: 300, height: 62)
  public static let menuSize = CGSize(width: 50, height: 50)
  /// pt from the safe area's top and sides to the rail and MENU (the web's 10).
  public static let edge: CGFloat = 10
  /// pt between the plan block and the meter's box, and above its foot (hud.js place).
  public static let planGap: CGFloat = 6
  public static let planLift: CGFloat = 10

  public static func isWide(_ size: CGSize) -> Bool {
    size.width > 0 && size.height > 0 && !(size.height > size.width * tallFrom)
  }

  /// The clock's box on a wide screen: S = min(0.28 W, 0.5 H on a phone, else
  /// 0.46 H, 380), 1.2 S tall, `margin` in from the chosen side, its foot half a
  /// margin over the bottom safe area.
  public static func clockBox(size: CGSize, safe: ScreenInsets, side: MeterSide) -> CGRect {
    let phone = min(size.width, size.height) < 520
    let s = min(size.width * 0.28, size.height * (phone ? 0.5 : 0.46), 380)
    let h = s * 1.2
    let x = side == .left ? safe.left + margin : size.width - safe.right - margin - s
    return CGRect(x: x, y: size.height - safe.bottom - margin * 0.5 - h, width: s, height: h)
  }

  /// The clock in its box (the web's dialGeometry): room for the prompt above it.
  public static func clock(size: CGSize, safe: ScreenInsets, side: MeterSide) -> ClockMeter {
    let b = clockBox(size: size, safe: safe, side: side)
    let pad = min(b.width, b.height) * 0.04
    let r = max(4, min((b.width - 2 * pad) / 2.12, (b.height - 2 * pad) / (2.12 + 0.42)))
    return ClockMeter(center: CGPoint(x: b.midX, y: b.maxY - pad - r * 1.06), radius: r)
  }

  /// The box the meter takes: the clock's box, or the linear meter's body and shadow.
  public static func meterBox(_ meter: MeterLayout, size: CGSize, safe: ScreenInsets, side: MeterSide)
    -> CGRect
  {
    switch meter {
    case .clock: return clockBox(size: size, safe: safe, side: side)
    case .linear(let m): return CGRect(x: m.left, y: m.top, width: m.width + m.shadow, height: m.bottom + m.shadow - m.top)
    }
  }

  /// The minimap in the bottom corner the meter leaves: max(56, min(118, 0.085 W,
  /// 0.16 H)) wide, as tall as the iPhone's map is (1.65 of its width).
  public static func minimap(size: CGSize, safe: ScreenInsets, side: MeterSide) -> CGRect {
    let w = max(56, min(118, size.width * 0.085, size.height * 0.16))
    let h = w * 1.65
    let x = side == .left ? size.width - safe.right - margin - w : safe.left + margin
    return CGRect(x: x, y: size.height - safe.bottom - margin - h, width: w, height: h)
  }

  /// The turn rail, top left.
  public static func rail(size: CGSize, safe: ScreenInsets) -> CGRect {
    CGRect(
      x: safe.left + edge, y: safe.top + edge,
      width: min(railSize.width, size.width * 0.4), height: railSize.height)
  }

  /// MENU, top right.
  public static func menu(size: CGSize, safe: ScreenInsets) -> CGRect {
    CGRect(
      x: size.width - safe.right - edge - menuSize.width, y: safe.top + edge,
      width: menuSize.width, height: menuSize.height)
  }

  /// Where a slider's or STAND's caption, the verdict and SLOW MOTION go: the
  /// top between the rail and MENU (and any tray beside it), its top level with theirs.
  public static func caption(size: CGSize, safe: ScreenInsets, trayWidth: CGFloat = 0) -> CGRect {
    let r = rail(size: size, safe: safe)
    let m = menu(size: size, safe: safe)
    let left = r.maxX + edge
    let right = m.minX - edge - trayWidth
    return CGRect(x: left, y: r.minY, width: max(0, right - left), height: r.height)
  }

  /// The plan's block of `block` size, on the meter's inner side `planGap` off
  /// its box, the block's foot `planLift` above the box's foot (hud.js place).
  public static func plans(
    block: CGSize, meter: MeterLayout, size: CGSize, safe: ScreenInsets, side: MeterSide
  ) -> CGRect {
    let b = meterBox(meter, size: size, safe: safe, side: side)
    let x = side == .left ? b.maxX + planGap : b.minX - planGap - block.width
    return CGRect(x: x, y: b.maxY - planLift - block.height, width: block.width, height: block.height)
  }

  /// The plan block's distance in from the screen's edge on the meter's side,
  /// and from the bottom to its foot: how the app pads it.
  public static func plansAnchor(meter: MeterLayout, size: CGSize, safe: ScreenInsets, side: MeterSide)
    -> (edge: CGFloat, bottom: CGFloat)
  {
    let b = meterBox(meter, size: size, safe: safe, side: side)
    let edge = side == .left ? b.maxX + planGap : size.width - (b.minX - planGap)
    return (edge, size.height - (b.maxY - planLift))
  }
}
