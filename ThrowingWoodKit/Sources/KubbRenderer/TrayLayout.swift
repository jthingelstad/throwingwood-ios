import CoreGraphics
import Foundation

/// The set-up tray (the 1.0 design's aim layout, "One tray, three equal plates"): ARC,
/// TILT and STAND are three plates of one size, 86 by 60 on a phone and 104 by 70 on a
/// wide screen, stacked in a column 8 pt apart, each showing a small picture of its own
/// setting. A tap opens that one control large; the other two stay as plates, and a tap
/// outside closes it. SIDE VIEW is no longer a button: it is what ARC open shows.
///
/// Upright the column is at the left edge beside the clock, mirrored when the clock's
/// Meter side is Left or the linear meter is at the left: the other side of the clock
/// stays empty, because that is where the throwing thumb lands. An open plate grows
/// upward in the column, whose foot stays put. On a wide screen the column is at the
/// edge away from the meter (`WideLayout.plan`), and an open plate stands beside it.
///
/// Pure: the app places its views on these frames, and the tests check them.
public enum TrayPlate: String, CaseIterable, Sendable {
  case arc, tilt, stand
}

public enum Tray {
  /// A closed plate on a phone held upright, and on a wide screen (the build list).
  public static let phonePlate = CGSize(width: 86, height: 60)
  public static let widePlate = CGSize(width: 104, height: 70)
  /// pt between the plates.
  public static let gap: CGFloat = 8
  /// Upright: pt in from the safe edge (the design's 10; the SE's clock rim leaves 11)
  /// and the column's foot above the safe bottom.
  public static let edge: CGFloat = 10
  public static let foot: CGFloat = 8

  public static func plate(wide: Bool) -> CGSize { wide ? widePlate : phonePlate }

  /// The column of three closed plates.
  public static func column(wide: Bool) -> CGSize {
    let p = plate(wide: wide)
    return CGSize(width: p.width, height: p.height * 3 + gap * 2)
  }

  /// An open plate's height: ARC's track (the design's ARC open is 256 tall with its
  /// High and Flat words; the app's slider marks its ends), TILT's slider and STAND's
  /// throwing line large.
  public static func openHeight(_ p: TrayPlate, wide: Bool) -> CGFloat {
    switch p {
    case .arc: wide ? 230 : 220
    case .tilt: wide ? 112 : 104
    case .stand: wide ? 140 : 128
    }
  }

  /// Upright, the edge the column is at: the left, unless the meter is at the left
  /// (the linear meter there, or the clock with Meter side Left), so the meter's other
  /// side, the throwing thumb's, stays empty.
  public static func uprightEdge(meter: MeterLayout, side: MeterSide) -> MeterSide {
    if let m = meter.linear { return m.side == .left ? .right : .left }
    return side == .left ? .right : .left
  }

  /// The closed column upright: `edge` in from the safe edge, its foot `foot` above the
  /// safe bottom.
  public static func upright(size: CGSize, safe: ScreenInsets, meter: MeterLayout, side: MeterSide) -> CGRect {
    let c = column(wide: false)
    let x =
      uprightEdge(meter: meter, side: side) == .left
      ? safe.left + edge : size.width - safe.right - edge - c.width
    return CGRect(x: x, y: size.height - safe.bottom - foot - c.height, width: c.width, height: c.height)
  }

  /// The three plates' frames in a column whose foot is at `foot` and left edge at `x`,
  /// with `open` grown upward to its open height (ARC on top, then TILT, then STAND).
  public static func stack(x: CGFloat, foot: CGFloat, wide: Bool, open: TrayPlate? = nil) -> [TrayPlate: CGRect] {
    let p = plate(wide: wide)
    var y = foot
    var frames: [TrayPlate: CGRect] = [:]
    for plate in TrayPlate.allCases.reversed() {
      let h = plate == open ? openHeight(plate, wide: wide) : p.height
      y -= h
      frames[plate] = CGRect(x: x, y: y, width: p.width, height: h)
      y -= gap
    }
    return frames
  }

  /// Upright: the plates, the open one grown upward in the column.
  public static func uprightPlates(
    size: CGSize, safe: ScreenInsets, meter: MeterLayout, side: MeterSide, open: TrayPlate? = nil
  ) -> [TrayPlate: CGRect] {
    let c = upright(size: size, safe: safe, meter: meter, side: side)
    return stack(x: c.minX, foot: c.maxY, wide: false, open: open)
  }

  /// Wide: the open plate in the plan's open room, its foot at the room's foot, as tall
  /// as it is open or the room, never shorter than a closed plate.
  public static func openFrame(_ p: TrayPlate, in plan: WideLayout.Plan) -> CGRect {
    let h = max(widePlate.height, min(openHeight(p, wide: true), plan.open.height))
    return CGRect(x: plan.open.minX, y: plan.open.maxY - h, width: plan.open.width, height: h)
  }
}
