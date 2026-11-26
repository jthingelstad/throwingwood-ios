import CoreGraphics

/// Where HOLLER's panel stands (the app's Holler.swift): never over the throw's meter or
/// the set-up tray, inside the safe area, beside its button. The minimap and the
/// captions are pictures, not controls, and may go under it while it is open.
public enum HollerLayout {
  /// pt the panel keeps off the screen's safe edges and off every frame it must not cover.
  public static let gap: CGFloat = 8
  /// The widest a panel is drawn (the web's).
  public static let maxWidth: CGFloat = 460
  /// The least room a panel is shown in: under it the panel scrolls, never cut.
  public static let minSize = CGSize(width: 280, height: 160)

  /// The largest rectangle inside `room` that keeps `gap` off every frame in `keepOut`:
  /// each frame that meets it cuts it at whichever side leaves the most.
  public static func free(room: CGRect, keepOut: [CGRect], gap: CGFloat = gap) -> CGRect {
    var r = room
    for k in keepOut where !k.isNull && !k.isEmpty {
      let f = k.insetBy(dx: -gap, dy: -gap)
      guard f.intersects(r) else { continue }
      let cuts = [
        CGRect(x: r.minX, y: r.minY, width: r.width, height: f.minY - r.minY),  // above it
        CGRect(x: r.minX, y: f.maxY, width: r.width, height: r.maxY - f.maxY),  // under it
        CGRect(x: r.minX, y: r.minY, width: f.minX - r.minX, height: r.height),  // left of it
        CGRect(x: f.maxX, y: r.minY, width: r.maxX - f.maxX, height: r.height),  // right of it
      ].filter { $0.size.width > 0 && $0.size.height > 0 }  // size: `width` reads a negative one as positive
      // a panel needs width for its phrases before height: a cut that leaves it too
      // narrow loses to one that leaves it short
      let wide = cuts.filter { $0.width >= minSize.width }
      r = (wide.isEmpty ? cuts : wide).max { $0.width * $0.height < $1.width * $1.height } ?? .null
      if r.isNull { return r }
    }
    return r
  }

  /// The panel's frame in the free room: at most `maxWidth`, centred across it, at the
  /// room's top (it hangs under HOLLER), at most `height` tall.
  public static func panel(in free: CGRect, height: CGFloat) -> CGRect {
    let w = min(maxWidth, free.width), h = min(height, free.height)
    return CGRect(x: free.midX - w / 2, y: free.minY, width: w, height: h)
  }

  /// The upright room: under HOLLER (`buttonBottom`; it stands at the left under the
  /// header, as on the web), down to the safe bottom, between the safe sides, out of the
  /// meter's box and the tray's column.
  public static func upright(
    size: CGSize, safe: ScreenInsets, buttonBottom: CGFloat, meter: MeterLayout, side: MeterSide
  ) -> CGRect {
    let room = CGRect(
      x: safe.left + 12, y: buttonBottom + gap, width: size.width - safe.left - safe.right - 24,
      height: size.height - safe.bottom - gap - buttonBottom - gap)
    var keep = [Tray.upright(size: size, safe: safe, meter: meter, side: side)]
    switch meter {
    case .clock(let k):
      // the ring a finger turns, and the prompt and distance over it
      let r = k.radius * 1.12 + 6
      keep.append(
        CGRect(x: k.center.x - r, y: k.center.y - r - promptHeight, width: 2 * r, height: 2 * r + promptHeight))
    case .linear(let l): keep += [l.cover, l.tab]
    }
    return free(room: room, keepOut: keep)
  }

  /// pt over the clock's ring that its prompt tab (WIND BACK, the distance) takes.
  public static let promptHeight: CGFloat = 44

  /// On a wide screen: under HOLLER (`button`, top right), down to the safe bottom, out
  /// of the meter's box, the tray's reach and the header.
  public static func wide(
    size: CGSize, safe: ScreenInsets, button: CGRect, meter: MeterLayout, side: MeterSide, trayWidth: CGFloat
  ) -> CGRect {
    let room = CGRect(
      x: safe.left + gap, y: button.maxY + gap, width: size.width - safe.left - safe.right - 2 * gap,
      height: size.height - safe.bottom - gap - button.maxY - gap)
    let plan = WideLayout.plan(meter: meter, size: size, safe: safe, side: side, trayWidth: trayWidth)
    var keep = [WideLayout.meterBox(meter, size: size, safe: safe, side: side), plan.block]
    if let l = meter.linear { keep.append(l.tab) }
    return free(room: room, keepOut: keep)
  }

  /// On a wide screen, how tall the hollers that arrive may stand under HOLLER (`button`)
  /// in a column `width` wide ending at its right: down to the safe bottom, or to the
  /// meter or the linear meter's tab where they come
  /// into the column, so a holler never goes over the meter.
  public static func feedHeight(
    size: CGSize, safe: ScreenInsets, button: CGRect, meter: MeterLayout, side: MeterSide, width: CGFloat
  ) -> CGFloat {
    let top = button.maxY + 6
    let column = CGRect(x: button.maxX - width, y: top, width: width, height: size.height - safe.bottom - top)
    // the clock's box holds its prompt (WideLayout.clockBox)
    let box = WideLayout.meterBox(meter, size: size, safe: safe, side: side)
    var foot = column.maxY
    for k in [box, meter.linear?.tab ?? .null] where !k.isNull {
      let f = k.insetBy(dx: -gap, dy: -gap)
      if f.intersects(column) { foot = min(foot, max(top, f.minY)) }
    }
    return max(0, foot - top)
  }

  /// The newest hollers that fit `height` (each `heights` tall, `spacing` apart), oldest
  /// first: how many to show.
  public static func feedCount(heights: [CGFloat], height: CGFloat, spacing: CGFloat = 6) -> Int {
    var used: CGFloat = 0, n = 0
    for h in heights.reversed() {
      let next = used + (n == 0 ? h : spacing + h)
      if next > height { break }
      used = next
      n += 1
    }
    return n
  }

  /// How many phrases a row and emoji a row the panel's width takes.
  public static func columns(width: CGFloat) -> (phrases: Int, emoji: Int) {
    (width >= 420 ? 3 : 2, width >= 330 ? 6 : 4)
  }
}
