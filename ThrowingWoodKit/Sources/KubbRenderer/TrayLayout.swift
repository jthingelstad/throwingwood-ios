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
  /// pt between the plates (the web's plateGap).
  public static let gap: CGFloat = 8
  /// Upright: pt in from the safe edge (the design's 10; the SE's clock rim leaves
  /// 11) and the column's foot above the safe bottom. Wide: the web's trayEdge, 12.
  public static let edge: CGFloat = 10
  public static let wideEdge: CGFloat = 12
  public static let foot: CGFloat = 8
  /// pt an open plate keeps under what stands over the column (the web's mapGap).
  public static let ceilingGap: CGFloat = 8
  /// A plate's hard shadow.
  public static let shadow: CGFloat = 3
  /// An open plate grows up from its place, the column's foot staying put (the web's
  /// layout.js tune): ARC to `openArc`, TILT or SPIN to `openSide` and STAND to
  /// `openStand`, the last two also in toward the middle to `openWidth` (never nearer
  /// the throwing line than `WideLayout.planClear`, never over the meter). Where the
  /// room under the ceiling leaves an open plate under `openMin` with the other two
  /// showing, it covers them instead.
  public static func openHeight(_ p: TrayPlate, wide: Bool) -> CGFloat {
    switch p {
    case .arc: wide ? 300 : 256
    case .tilt: 84
    case .stand: wide ? 180 : 150
    }
  }
  public static func openWidth(wide: Bool) -> CGFloat { wide ? 240 : 200 }
  public static let openMin: CGFloat = 100

  public static func plate(wide: Bool) -> CGSize { wide ? widePlate : phonePlate }

  /// The column of three closed plates.
  public static func column(wide: Bool) -> CGSize {
    let p = plate(wide: wide)
    return CGSize(width: p.width, height: p.height * 3 + gap * 2)
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

  /// The tray upright: the column, its ceiling (under the header as measured, `nil`:
  /// the header's usual foot, and under the minimap where it stands over the column)
  /// and how wide TILT and STAND may open (short of the meter).
  public static func uprightFrames(
    size: CGSize, safe: ScreenInsets, meter: MeterLayout, side: MeterSide, headerBottom: CGFloat? = nil
  ) -> TrayFrames {
    let c = upright(size: size, safe: safe, meter: meter, side: side)
    let edge = uprightEdge(meter: meter, side: side)
    let map = WideLayout.uprightMinimap(size: size, safe: safe, headerBottom: headerBottom)
    var ceiling = (headerBottom ?? (safe.top + 61)) + ceilingGap
    if map.minX < c.maxX + shadow, map.maxX > c.minX { ceiling = max(ceiling, map.maxY + ceilingGap) }
    // in toward the middle, short of the meter (the clock's face and shadow, the
    // linear meter's body and tabs) and the throwing line
    var limit = edge == .left ? size.width / 2 - WideLayout.planClear : size.width / 2 + WideLayout.planClear
    switch meter {
    case .clock(let k):
      let r = k.radius * 1.12 + 6
      limit = edge == .left ? min(limit, k.center.x - r) : max(limit, k.center.x + r)
    case .linear(let l):
      let keep = l.cover.union(l.tab).insetBy(dx: -8, dy: 0)
      limit = edge == .left ? min(limit, keep.minX) : max(limit, keep.maxX)
    }
    let w = edge == .left ? limit - c.minX : c.maxX - limit
    return TrayFrames(
      column: c, edge: edge, ceiling: ceiling, wide: false,
      sideWidth: max(phonePlate.width, min(openWidth(wide: false), w - shadow)))
  }

  /// Upright: the plates, the open one grown upward in the column.
  public static func uprightPlates(
    size: CGSize, safe: ScreenInsets, meter: MeterLayout, side: MeterSide, open: TrayPlate? = nil,
    headerBottom: CGFloat? = nil
  ) -> [TrayPlate: CGRect] {
    uprightFrames(size: size, safe: safe, meter: meter, side: side, headerBottom: headerBottom).plates(open: open)
  }

  /// The three plates' frames in a column whose foot is at `foot` and left edge at `x`,
  /// all closed.
  public static func stack(x: CGFloat, foot: CGFloat, wide: Bool) -> [TrayPlate: CGRect] {
    let p = plate(wide: wide)
    var y = foot
    var frames: [TrayPlate: CGRect] = [:]
    for plate in TrayPlate.allCases.reversed() {
      y -= p.height
      frames[plate] = CGRect(x: x, y: y, width: p.width, height: p.height)
      y -= gap
    }
    return frames
  }
}

/// The tray on a screen: its column, the ceiling an open plate grows up to, and how far
/// TILT and STAND open toward the middle (the web's trayAt).
public struct TrayFrames: Equatable, Sendable {
  public var column: CGRect
  /// The screen edge the column is at.
  public var edge: MeterSide
  /// The highest an open plate reaches (under the header, the minimap).
  public var ceiling: CGFloat
  public var wide: Bool
  /// How wide TILT or SPIN and STAND open, toward the middle.
  public var sideWidth: CGFloat
  /// A closed plate: `Tray.plate(wide:)`, shorter (never under 48) on a screen too
  /// short for the column under its ceiling.
  public var plate: CGSize

  public init(column: CGRect, edge: MeterSide, ceiling: CGFloat, wide: Bool, sideWidth: CGFloat, plate: CGSize? = nil) {
    self.column = column
    self.edge = edge
    self.ceiling = ceiling
    self.wide = wide
    self.sideWidth = sideWidth
    self.plate = plate ?? Tray.plate(wide: wide)
  }

  /// An open plate's size and whether it covers the other two (no room above them).
  public func open(_ p: TrayPlate) -> (size: CGSize, cover: Bool) {
    let want = Tray.openHeight(p, wide: wide)
    let room = column.maxY - ceiling
    let rest = 2 * (plate.height + Tray.gap)
    let pushed = min(want, room - rest)
    let width = p == .arc ? plate.width : sideWidth
    if pushed >= min(want, Tray.openMin) { return (CGSize(width: width, height: pushed), false) }
    return (CGSize(width: width, height: max(plate.height, min(want, room))), true)
  }

  /// The plates to draw: all closed, or the open one grown up from its place (the
  /// column's foot staying put) and in toward the middle, the other two closed above
  /// or under it; where it covers them, the open one alone, from the column's foot.
  public func plates(open p: TrayPlate?) -> [TrayPlate: CGRect] {
    guard let p else { return stack() }
    let o = self.open(p)
    func x(_ w: CGFloat) -> CGFloat { edge == .left ? column.minX : column.maxX - w }
    if o.cover {
      return [p: CGRect(x: x(o.size.width), y: column.maxY - o.size.height, width: o.size.width, height: o.size.height)]
    }
    var y = column.maxY
    var frames: [TrayPlate: CGRect] = [:]
    for q in TrayPlate.allCases.reversed() {
      let s = q == p ? o.size : plate
      y -= s.height
      frames[q] = CGRect(x: x(s.width), y: y, width: s.width, height: s.height)
      y -= Tray.gap
    }
    return frames
  }

  /// The closed column's plates.
  public func stack() -> [TrayPlate: CGRect] {
    var y = column.maxY
    var frames: [TrayPlate: CGRect] = [:]
    for q in TrayPlate.allCases.reversed() {
      y -= plate.height
      frames[q] = CGRect(x: column.minX, y: y, width: plate.width, height: plate.height)
      y -= Tray.gap
    }
    return frames
  }

  /// All a plate may take, closed or open: what the captions keep out of.
  public var reach: CGRect {
    TrayPlate.allCases.reduce(column) { r, p in plates(open: p).values.reduce(r) { $0.union($1) } }
  }
}
