import CoreGraphics
import Foundation

// A phone on its side (Jamie, 2026-11-19: "Given we have a widescreen view for
// web, can we extend that to support iPhone rotated display?"). The web's wide
// arrangement (src/game/layout.js, its numbers): the clock lower right or lower
// left by Meter side, the set-up tray (ARC, TILT and STAND, three plates in a
// column, the 1.0 design) at the other edge, the minimap under the header's right
// end (`plan`; on an iPad on its side at the tray's edge, `edgeMap`), the header (the turn rail) top left with MENU inside
// its plate (the 1.0 design: "MENU never leaves it"), and online HOLLER top right. The
// player's choice of meter holds on a phone on its side: the linear meter goes
// at its edge with the whole safe height (`LinearMeter.layout`, its track at
// least `LinearMeter.Tune.wideMinTravel`, which every iPhone on its side has),
// and what is at that top corner, the header or HOLLER, moves inward beside it.
// The camera is the thrower's view as ever: the projection's wide rule (the
// 400 x 240 frame fitted whole).
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
  /// The header's plate at the top left (the web's rail, 300 x 62), and MENU, the word,
  /// inside it at its right end (`menuInset` in from the plate's outer edge).
  public static let railSize = CGSize(width: 300, height: 62)
  public static let menuSize = CGSize(width: 72, height: 44)
  public static let menuInset: CGFloat = 8
  /// pt from the safe area's top and sides to the rail and MENU (the web's 10).
  public static let edge: CGFloat = 10
  /// pt the tray's column stands above the meter box's foot (hud.js place).
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
    case .linear(let m): return m.cover
    }
  }

  /// The turn rail, top left; beside the linear meter, `edge` off its body, where
  /// the meter is at the left and would meet it there.
  public static func rail(size: CGSize, safe: ScreenInsets, meter: MeterLayout? = nil) -> CGRect {
    var r = CGRect(x: safe.left + edge, y: safe.top + edge, width: 0, height: railSize.height)
    if let m = meter?.linear, m.side == .left,
      CGRect(x: r.minX, y: r.minY, width: railSize.width, height: r.height).intersects(m.cover.insetBy(dx: -edge, dy: -edge))
    {
      r.origin.x = m.cover.maxX + edge
    }
    r.size.width = railWidth(size: size, x: r.minX)
    return r
  }

  /// The header's width on a wide screen (the web's headerBox): 0.4 of the screen,
  /// kept between `railMinWidth` and `railMaxWidth` and, where it can, `planClear`
  /// short of the throwing line, so the minimap under its right end stays off it. A
  /// fixed width for the layout: the minimap never moves. The app's floor is its old
  /// width, min(300, 0.4 W), not the web's 260: its header holds the line beside the
  /// numbers and MENU, not across the top, and 260 cut "Turn 1 · baton 1 of 2" short.
  public static let railMinWidth: CGFloat = 300
  public static let railMaxWidth: CGFloat = 400
  static func railWidth(size: CGSize, x: CGFloat) -> CGFloat {
    max(min(railMinWidth, size.width * 0.4), min(railMaxWidth, size.width * 0.4, size.width / 2 - planClear - x))
  }

  /// MENU, inside the header's plate at its right end, wherever the header is.
  public static func menu(size: CGSize, safe: ScreenInsets, meter: MeterLayout? = nil) -> CGRect {
    let r = rail(size: size, safe: safe, meter: meter)
    return CGRect(
      x: r.maxX - menuInset - menuSize.width, y: r.midY - menuSize.height / 2,
      width: menuSize.width, height: menuSize.height)
  }

  /// The top row's right edge: `edge` in from the safe area, or `edge` off the linear
  /// meter's body where the meter is at the right and would meet the top row there.
  static func topRight(size: CGSize, safe: ScreenInsets, meter: MeterLayout?) -> CGFloat {
    let x = size.width - safe.right - edge
    let corner = CGRect(x: x - shoutSize.width, y: safe.top + edge, width: shoutSize.width, height: railSize.height)
    if let m = meter?.linear, m.side == .right, corner.intersects(m.cover.insetBy(dx: -edge, dy: -edge)) {
      return m.cover.minX - edge
    }
    return x
  }

  /// Online, HOLLER at the top right: the button's plate (the app's WoodButton, about
  /// 88 x 50 with its shadow) and the gap the captions keep from it. The shouts hang
  /// under it.
  public static let shoutSize = CGSize(width: 88, height: 50)
  public static let shoutGap: CGFloat = 8
  /// The width the caption gives up for it.
  public static var trayWidth: CGFloat { shoutSize.width + shoutGap }

  /// HOLLER, top right, level with the header's top (moved in beside a linear meter at
  /// the right, `edge` off its body).
  public static func shout(size: CGSize, safe: ScreenInsets, meter: MeterLayout? = nil) -> CGRect {
    let x = topRight(size: size, safe: safe, meter: meter)
    return CGRect(
      x: x - shoutSize.width, y: safe.top + edge, width: shoutSize.width, height: shoutSize.height)
  }

  /// The caption strip's narrowest: a slider's caption plate, the wind words or
  /// the verdict (its flag shrinks to fit this). The iPhones' narrowest strip,
  /// the SE online beside a linear meter, is 112.6 pt.
  public static let captionMin: CGFloat = 112

  /// Where a slider's or STAND's caption, the verdict and SLOW MOTION go: the
  /// top between the header and the screen's right (and HOLLER there online), its top
  /// level with theirs. Where that strip is narrower than `captionMin` (a narrow iPad
  /// window, Codex on PR #25: 0.4 pt online at 480 x 400 beside a linear meter)
  /// the captions take a line of their own `edge` under the header row, as
  /// wide as the meter, its tab and coach line, and the plan block leave.
  public static func caption(
    size: CGSize, safe: ScreenInsets, trayWidth: CGFloat = 0, meter: MeterLayout? = nil,
    side: MeterSide? = nil
  ) -> CGRect {
    let strip = topStrip(size: size, safe: safe, trayWidth: trayWidth, meter: meter)
    // the minimap at the tray's edge under the strip (the meter at the left): the strip
    // stops `edge` short of it, so the stack can grow down beside it
    if let meter, let map = edgeMap(meter: meter, size: size, safe: safe, side: side ?? meter.linear?.side ?? .right, trayWidth: trayWidth) {
      return cut(strip, by: map, size: size)
    }
    guard strip.width < captionMin, let meter else { return strip }
    let r = rail(size: size, safe: safe, meter: meter)
    let m = menu(size: size, safe: safe, meter: meter)
    let side = side ?? meter.linear?.side ?? .right
    var row = CGRect(
      x: safe.left + edge, y: max(r.maxY, m.maxY) + edge,
      width: size.width - safe.left - safe.right - 2 * edge, height: r.height)
    var keepOut = [meterBox(meter, size: size, safe: safe, side: side), tray(meter: meter, size: size, safe: safe, side: side, trayWidth: trayWidth).reach]
    if let lm = meter.linear { keepOut += [lm.tab, coachBand(lm, size: size)] }
    for k in keepOut where k.minY < row.maxY && k.maxY > row.minY {
      if k.midX >= size.width / 2 {
        row.size.width = max(0, min(row.maxX, k.minX - edge) - row.minX)
      } else {
        let x = min(row.maxX, max(row.minX, k.maxX + edge))
        row.size.width = row.maxX - x
        row.origin.x = x
      }
    }
    return row
  }

  /// The strip cut `edge` short of `f` where `f` stands under it (its x span meets the
  /// strip's): from the right where `f` is on the right half, from the left otherwise.
  static func cut(_ strip: CGRect, by f: CGRect, size: CGSize) -> CGRect {
    guard f.minX < strip.maxX, f.maxX > strip.minX else { return strip }
    var s = strip
    if f.midX >= size.width / 2 {
      s.size.width = max(0, min(s.maxX, f.minX - edge) - s.minX)
    } else {
      let x = min(s.maxX, max(s.minX, f.maxX + edge))
      s.size.width = s.maxX - x
      s.origin.x = x
    }
    return s
  }

  /// The caption strip in the header row: between the header and the screen's right (and
  /// HOLLER there online), short of a linear meter whose top comes up beside it.
  static func topStrip(size: CGSize, safe: ScreenInsets, trayWidth: CGFloat, meter: MeterLayout?) -> CGRect {
    let r = rail(size: size, safe: safe, meter: meter)
    let left = r.maxX + edge
    let right = topRight(size: size, safe: safe, meter: meter) - trayWidth
    var strip = CGRect(x: left, y: r.minY, width: max(0, right - left), height: r.height)
    // a linear meter standing on the bottom margin whose top comes up beside
    // MENU (a window a little taller than its 450 pt): the strip stops short of it
    if let lm = meter?.linear, lm.cover.minY - edge < strip.maxY {
      if lm.side == .right {
        strip.size.width = max(0, min(strip.maxX, lm.cover.minX - edge) - strip.minX)
      } else {
        let x = min(strip.maxX, max(strip.minX, lm.cover.maxX + edge))
        strip.size.width = strip.maxX - x
        strip.origin.x = x
      }
    }
    return strip
  }

  /// pt the caption stack keeps above the next frame under it (its plate's
  /// shadow reaches 4 pt below the plate).
  public static let captionGap: CGFloat = 6

  /// The room the caption stack may fill (MatchScreen.wide frames it to this):
  /// the caption's x and width, from its top down to `captionGap` above the
  /// first frame under it (the meter's box, the plan block, the minimap, the
  /// linear meter's tab and coach line) or `edge` above the safe bottom, and
  /// never shorter than the caption itself. `caption` is the line the layout
  /// places the rest by; this is how far down the stack (wind or a held
  /// slider's words over the verdict) may grow.
  public static func captionRoom(
    size: CGSize, safe: ScreenInsets, trayWidth: CGFloat = 0, meter: MeterLayout, side: MeterSide? = nil
  ) -> CGRect {
    let side = side ?? meter.linear?.side ?? .right
    let c = caption(size: size, safe: safe, trayWidth: trayWidth, meter: meter, side: side)
    let p = plan(meter: meter, size: size, safe: safe, side: side, trayWidth: trayWidth)
    var under = [meterBox(meter, size: size, safe: safe, side: side), p.reach]
    if !p.minimap.isNull { under.append(p.minimap) }
    if let lm = meter.linear { under += [lm.tab, coachBand(lm, size: size)] }
    var foot = size.height - safe.bottom - edge
    for f in under where f.minX < c.maxX && f.maxX > c.minX && f.maxY > c.minY {
      foot = min(foot, f.minY - captionGap)
    }
    return CGRect(x: c.minX, y: c.minY, width: c.width, height: max(c.height, foot - c.minY))
  }

  /// Is the caption a line of its own under the header row?
  public static func captionHasItsOwnLine(_ c: CGRect, size: CGSize, safe: ScreenInsets, meter: MeterLayout?) -> Bool {
    c.minY > rail(size: size, safe: safe, meter: meter).minY
  }

  /// The coach line under the linear meter's tab on a wide screen (CoachHUD:
  /// 8 pt under it, at most 76 pt deep, in the meter's half `planClear` short
  /// of the centre line).
  public static func coachBand(_ m: LinearMeter, size: CGSize) -> CGRect {
    let t = m.tab
    let centre = size.width / 2
    let lo = m.side == .right ? centre + planClear : m.cover.maxX
    let hi = m.side == .right ? m.left : centre - planClear
    return CGRect(x: lo, y: t.maxY + 8, width: max(0, hi - lo), height: 76)
  }

  /// The practice pitch's header on a wide screen (GameView.practice): 14 pt in
  /// from the safe sides, `edge` under the safe top, about 56 pt tall with its
  /// shadow, and 10 pt short of a linear meter's body (its meterRoom).
  public static let practiceHeaderHeight: CGFloat = 56
  public static func practiceHeader(size: CGSize, safe: ScreenInsets, meter: MeterLayout) -> CGRect {
    var lo = safe.left + 14, hi = size.width - safe.right - 14
    if let m = meter.linear {
      if m.side == .right { hi = min(hi, m.left - 10) } else { lo = max(lo, m.cover.maxX + 10) }
    }
    return CGRect(x: lo, y: safe.top + edge, width: max(0, hi - lo), height: practiceHeaderHeight)
  }

  // MARK: The set-up tray at the far edge

  /// The tray and an open plate keep this many pt short of the throwing line, the
  /// screen's centre (tune.planClear).
  public static let planClear: CGFloat = 24
  /// pt the minimap hangs under the header (the web's mapGap).
  public static let mapGap: CGFloat = 8

  /// Where the set-up tray and the minimap go on a wide screen.
  public struct Plan: Equatable, Sendable {
    /// The tray: its column (ARC, TILT and STAND, three plates 8 pt apart, their
    /// shadows inside it), its ceiling, how its plates open.
    public var tray: TrayFrames
    /// The tray's closed column.
    public var block: CGRect { tray.column }
    /// The screen edge the column is at: the one away from the meter.
    public var edge: MeterSide { tray.edge }
    /// The minimap: under the header's right end (the 1.0 design, "one home"),
    /// `mapGap` under it, or under the captions' own line where they have one; at the
    /// tray's edge under the header row where the tray keeps its room (`edgeMap`);
    /// `.null` (not drawn) where it would meet the meter, the tray or the bottom. It
    /// is a picture, never a control: it gives way first.
    public var minimap: CGRect
    /// The column and all an open plate may take: what the captions keep out of.
    public var reach: CGRect { tray.reach }
  }

  /// The minimap's size (the web's minimapBox): max(56, min(118, 0.085 W, 0.16 H))
  /// wide, twice as tall less a twentieth (1.95).
  public static let mapTall: CGFloat = 1.95
  static func mapSize(_ size: CGSize) -> CGSize {
    let w = max(56, min(118, size.width * 0.085, size.height * 0.16))
    return CGSize(width: w, height: w * mapTall)
  }

  /// The tray on a wide screen (the web's trayAt): the column at the edge away from
  /// the meter, `Tray.wideEdge` inside the safe area, its foot `planLift` above the
  /// meter box's foot (Jamie, 2026-11-19: "in landscape the tilt, arc, stand controls
  /// should be pushed to the left hand side of the screen so the user can control
  /// those with the left hand and the throw with the right hand"); its ceiling under
  /// the header row and the minimap where they stand over it; TILT and STAND opening
  /// in toward the middle, short of the throwing line, the minimap and the meter. A
  /// window too short for the column under its ceiling brings its foot down toward
  /// the safe bottom, then shortens its plates (never under 48).
  static func tray(
    meter: MeterLayout, size: CGSize, safe: ScreenInsets, side: MeterSide, trayWidth: CGFloat = 0
  ) -> TrayFrames {
    let map =
      edgeMap(meter: meter, size: size, safe: safe, side: side, trayWidth: trayWidth)
      ?? nominalMap(
        size: size, rail: rail(size: size, safe: safe, meter: meter), menu: menu(size: size, safe: safe, meter: meter))
    return tray(meter: meter, size: size, safe: safe, side: side, map: map)
  }

  /// The tray under the header row and `map`, the minimap wherever it stands.
  static func tray(meter: MeterLayout, size: CGSize, safe: ScreenInsets, side: MeterSide, map: CGRect) -> TrayFrames {
    let box = meterBox(meter, size: size, safe: safe, side: side)
    let edge: MeterSide = side == .right ? .left : .right
    var plate = Tray.plate(wide: true)
    let x = edge == .left ? safe.left + Tray.wideEdge : size.width - safe.right - Tray.wideEdge - plate.width
    var colH = plate.height * 3 + Tray.gap * 2
    var foot = box.maxY - planLift
    let r = rail(size: size, safe: safe, meter: meter), m = menu(size: size, safe: safe, meter: meter)
    let over = [r, m, map]
    func across(_ f: CGRect, _ x0: CGFloat, _ w: CGFloat) -> Bool { f.minX < x0 + w && x0 < f.maxX }
    // under the header row across the screen (the header, the captions' strip,
    // HOLLER), and under the minimap where it stands over the column
    var ceiling = max(r.maxY, m.maxY) + Tray.ceilingGap
    for f in over where across(f, x, plate.width + Tray.shadow) { ceiling = max(ceiling, f.maxY + Tray.ceilingGap) }
    if foot - colH < ceiling { foot = min(size.height - safe.bottom - 6, ceiling + colH) }
    if foot - colH < ceiling {
      plate.height = max(48, (foot - ceiling - 2 * Tray.gap) / 3)
      colH = plate.height * 3 + Tray.gap * 2
    }
    let column = CGRect(x: x, y: foot - colH, width: plate.width, height: colH)
    // in toward the middle: short of the throwing line, then of anything lower than the
    // ceiling beside it (the minimap, the meter, its tab and coach line)
    var sideW = max(
      plate.width,
      min(Tray.openWidth(wide: true), edge == .left ? size.width / 2 - planClear - x : x + plate.width - (size.width / 2 + planClear)))
    var lower = over.filter { $0.maxY + Tray.ceilingGap > ceiling } + [box]
    if let lm = meter.linear { lower += [lm.tab, coachBand(lm, size: size)] }
    for f in lower where f.maxY > ceiling {
      let x0 = edge == .left ? x : x + plate.width - sideW
      guard across(f, x0, sideW + Tray.shadow) else { continue }
      sideW = edge == .left ? f.minX - Tray.ceilingGap - Tray.shadow - x : x + plate.width - (f.maxX + Tray.ceilingGap)
    }
    return TrayFrames(
      column: column, edge: edge, ceiling: ceiling, wide: true, sideWidth: max(plate.width, sideW), plate: plate)
  }

  /// The minimap's place under the header's right end before the captions are placed;
  /// where that end stands over the throwing line (the header moved in beside a linear
  /// meter at the left), under the header `planClear` short of the line, so the map
  /// never covers the pitch's middle, where the target usually is.
  /// `offLine` false: under the header's right end wherever it is (where short of the
  /// line the map would meet the linear meter's tab or coach line, on the narrower phones).
  static func nominalMap(size: CGSize, rail r: CGRect, menu m: CGRect, offLine: Bool = true) -> CGRect {
    let s = mapSize(size)
    let line = size.width / 2 - planClear
    let x = offLine ? min(r.maxX, max(line, r.minX + s.width)) - s.width : r.maxX - s.width
    return CGRect(x: x, y: max(r.maxY, m.maxY) + mapGap, width: s.width, height: s.height)
  }

  /// The minimap at the set-up tray's edge (the owner, 2026-11-27, from an iPad on its
  /// side: "The map of the pitch should be all the way to the left and under the other
  /// control. It is in the way in landscape on iPad."): at the edge away from the meter,
  /// its outer side in line with the tray column's, `mapGap` under the header row (the
  /// header where it is over it, else the captions' strip and HOLLER), above the tray.
  /// Only where that leaves the tray its full plates on its own foot, ARC its whole open
  /// height with the other two showing, and the captions' strip `captionMin` beside it,
  /// and where it meets nothing: an iPad on its side and big windows. Elsewhere nil, and
  /// the minimap keeps its place under the header's right end (`nominalMap`): every
  /// iPhone on its side and short windows.
  static func edgeMap(
    meter: MeterLayout, size: CGSize, safe: ScreenInsets, side: MeterSide, trayWidth: CGFloat
  ) -> CGRect? {
    let s = mapSize(size)
    let trayEdge: MeterSide = side == .right ? .left : .right
    let x = trayEdge == .left ? safe.left + Tray.wideEdge : size.width - safe.right - Tray.wideEdge - s.width
    let r = rail(size: size, safe: safe, meter: meter), m = menu(size: size, safe: safe, meter: meter)
    let holler = shout(size: size, safe: safe, meter: meter)
    let map = CGRect(
      x: x, y: max(r.maxY, m.maxY, trayWidth > 0 ? holler.maxY : 0) + mapGap, width: s.width, height: s.height)
    // the captions keep their line in the header row, beside it
    let strip = topStrip(size: size, safe: safe, trayWidth: trayWidth, meter: meter)
    guard strip.width >= captionMin, cut(strip, by: map, size: size).width >= captionMin else { return nil }
    // the tray under it as it would be under the header alone
    let t = tray(meter: meter, size: size, safe: safe, side: side, map: map)
    let box = meterBox(meter, size: size, safe: safe, side: side)
    let full = Tray.plate(wide: true)
    guard t.plate == full, t.column.maxY == box.maxY - planLift,
      t.open(.arc) == (CGSize(width: full.width, height: Tray.openHeight(.arc, wide: true)), false)
    else { return nil }
    let inside = CGRect(
      x: safe.left, y: safe.top, width: size.width - safe.left - safe.right, height: size.height - safe.top - safe.bottom)
    var keepOut = [r, box, t.reach]
    if trayWidth > 0 { keepOut.append(holler) }
    if let lm = meter.linear { keepOut += [lm.tab, coachBand(lm, size: size)] }
    guard inside.contains(map), !keepOut.contains(where: { $0.intersects(map) }) else { return nil }
    return map
  }

  /// The set-up tray at the edge away from the meter and the minimap under the
  /// header's right end, or at the tray's edge on an iPad on its side (`edgeMap`) (the 1.0 design's aim layout, "Wide": the column at the edge
  /// away from the meter, the header top left, the minimap under the header's right
  /// end).
  ///
  /// `trayWidth`: HOLLER's online, which can push the captions to a line of their own
  /// under the header row: the minimap goes under that line.
  public static func plan(
    meter: MeterLayout, size: CGSize, safe: ScreenInsets, side: MeterSide, trayWidth: CGFloat = 0
  ) -> Plan {
    // at the tray's edge where it fits (an iPad, a big window)
    if let map = edgeMap(meter: meter, size: size, safe: safe, side: side, trayWidth: trayWidth) {
      return Plan(tray: tray(meter: meter, size: size, safe: safe, side: side, map: map), minimap: map)
    }
    let t = tray(meter: meter, size: size, safe: safe, side: side, trayWidth: trayWidth)
    let r = rail(size: size, safe: safe, meter: meter), m = menu(size: size, safe: safe, meter: meter)
    let cap = caption(size: size, safe: safe, trayWidth: trayWidth, meter: meter, side: side)
    var keepOut = [meterBox(meter, size: size, safe: safe, side: side), t.reach]
    if let lm = meter.linear { keepOut += [lm.tab, coachBand(lm, size: size)] }
    func placed(offLine: Bool) -> CGRect {
      var map = nominalMap(size: size, rail: r, menu: m, offLine: offLine)
      if captionHasItsOwnLine(cap, size: size, safe: safe, meter: meter), cap.minX < map.maxX, cap.maxX > map.minX {
        map.origin.y = cap.maxY + mapGap
      }
      if map.maxY > size.height - safe.bottom || map.minX < safe.left || keepOut.contains(where: { $0.intersects(map) }) {
        return .null
      }
      return map
    }
    let map = placed(offLine: true)
    return Plan(tray: t, minimap: map.isNull ? placed(offLine: false) : map)
  }

  /// The minimap on an upright screen: under the header's right end (12 pt in from
  /// the safe edge, as the header), at least 75 pt under the safe top and `mapGap`
  /// under the header as measured (`header`, its maxY; a larger text size grows it),
  /// min(78, 0.19 W) wide and 1.95 of that tall (the web's). It never moves while a
  /// control is held.
  public static func uprightMinimap(size: CGSize, safe: ScreenInsets, headerBottom: CGFloat? = nil) -> CGRect {
    let w = min(78, size.width * 0.19)
    let y = max(safe.top + 75, (headerBottom ?? 0) + mapGap)
    return CGRect(x: size.width - safe.right - 12 - w, y: y, width: w, height: w * mapTall)
  }

  // MARK: The verdict

  /// The last throw's verdict (the flag, its words and the rest; the wind over it) is
  /// never over the place the next throw is aimed at (the owner, 2026-11-22: "the display
  /// stays on the screen for a while keeping the player from being able to aim at
  /// times"): it stops `verdictGap` above the top of the target ring, the kubb in it and
  /// the arc's last 1.5 m (`PitchSession.aimTop`), and gives way as the caption stack
  /// does where that is short (the rest, then the words), never under the flag alone
  /// (`verdictLeast`). It takes no touches, and the first press of the aim takes it away.
  public static let verdictGap: CGFloat = 8
  /// The flag alone (the caption's height on a wide screen).
  public static let verdictLeast: CGFloat = 62
  /// Upright, the most the stack takes at the default text size: the wind's plate (30),
  /// 8, and the verdict with a flag, two rows of words and a line of rest (134; the web's
  /// verdictTall 132).
  public static let verdictTall: CGFloat = 172

  /// Upright: the band under the header (`headerBottom`, as measured, + 8), from the safe
  /// left + 12 to 8 short of the minimap, `tall` deep (the stack's own height), stopped
  /// above the aim. The tray (at the bottom), the meter and the minimap are clear of it.
  public static func verdictBand(
    size: CGSize, safe: ScreenInsets, headerBottom: CGFloat, aimTop: CGFloat?, tall: CGFloat = verdictTall
  ) -> CGRect {
    let map = uprightMinimap(size: size, safe: safe, headerBottom: headerBottom)
    let x = safe.left + 12
    let band = CGRect(x: x, y: headerBottom + 8, width: max(0, map.minX - 8 - x), height: tall)
    return verdictClear(band, aimTop: aimTop)
  }

  /// `room` stopped `verdictGap` above the aim's top (nil: no aim shown), never under
  /// `verdictLeast`.
  public static func verdictClear(_ room: CGRect, aimTop: CGFloat?) -> CGRect {
    guard let a = aimTop else { return room }
    var r = room
    r.size.height = max(verdictLeast, min(room.height, a - verdictGap - room.minY))
    return r
  }

  // MARK: The raise and punishment bar

  /// A wide screen no taller than this shows the raise and punishment panel as a
  /// bar along the bottom (the web's tune.stillShort, game.css max-height 460px).
  public static let stillShort: CGFloat = 460
  /// pt inside the safe area at the sides, and above its bottom (game.css .panel).
  public static let barSide: CGFloat = 12
  public static let barLift: CGFloat = 8
  /// The bar's widest, centred between its sides.
  public static let barMaxWidth: CGFloat = 760
  /// pt the scene's lowest ground the player works on stays above the bar's top
  /// (tune.stillClear).
  public static let stillClear: CGFloat = 8

  /// The app's bar as measured on the review phones (the review's layout dump,
  /// 2026-11-19, both phones alike): one line of words, and two (raising by
  /// hand); its plate's shadow takes 4 pt of the 8 under it. The app reports its own
  /// height to the scene, so a third line from a larger text size still holds.
  public static let barOneLine: CGFloat = 53
  public static let barTwoLines: CGFloat = 65.3

  /// A phone on its side: the raise and punishment panel is a bar.
  public static func isShort(_ size: CGSize) -> Bool {
    isWide(size) && size.height <= stillShort
  }

  /// The bar of `height` pt (the app measures it: the words may wrap).
  public static func bar(height: CGFloat, size: CGSize, safe: ScreenInsets) -> CGRect {
    let left = safe.left + barSide, right = size.width - safe.right - barSide
    let w = max(0, min(barMaxWidth, right - left))
    return CGRect(
      x: left + (right - left - w) / 2, y: size.height - safe.bottom - barLift - height,
      width: w, height: height)
  }

  /// How far the raise or punishment scene moves up so its lowest point stays
  /// `stillClear` above a bar whose top is `floor` pt above the screen's foot:
  /// `lowest` is a frame y (the 400 x 240 frame) and `pad` screen points below
  /// it (an end number's circle). The projection's wide rule, the same scale;
  /// 0 where the scene is clear already (the web's stillFit, its `over`).
  public static func stillLift(size: CGSize, lowest: Double, pad: Double = 0, floor: Double) -> Double {
    guard isShort(size) else { return 0 }
    let k = min(size.width / 400, size.height / 240)
    let oy = (size.height - 240 * k) / 2
    let over = oy + k * lowest + pad - (size.height - floor - stillClear)
    return max(0, over)
  }
}
