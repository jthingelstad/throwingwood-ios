import CoreGraphics
import Foundation

// The throw's meter, the player's choice (Jamie, 2026-11-19: "I'm considering a
// player preference for a circular meter (clock) versus a linear meter ... The
// logic is the same to me. Just a choice if you want to spin your thumb or crank
// -- or use a different hand to flick."). Both meters only turn a finger into the
// arm in degrees that the clock has always sent through `ThrowInput`: 0 is six
// o'clock, the backswing negative, the forward swing positive, ±180 twelve. So a
// throw is judged alike on either and nothing in the engine changes.
//
// This file is the geometry and the touch rules, pure and testable. The app
// draws them (ThrowingWood/PracticeHUD.swift, LinearMeterHUD.swift).

public enum MeterKind: String, CaseIterable, Sendable { case clock, linear }

/// The screen edge the linear meter sits at (MENU, Meter side), and the bottom corner a
/// wide screen's clock takes. A tall screen's clock stays centred.
public enum MeterSide: String, CaseIterable, Sendable { case left, right }

/// The arm (degrees) as the unit point `ThrowInput.sample` takes: the point on a
/// dial of radius 1 that the clock's hand points at.
public func meterPoint(arm: Double) -> CGPoint {
  let a = arm * .pi / 180
  return CGPoint(x: sin(a), y: cos(a))
}

// MARK: - The clock

/// The clock (the dial): lower centre on a tall screen, the same place and size as it
/// has always had; lower left or right on a wide one (`WideLayout.clock`).
public struct ClockMeter: Equatable, Sendable {
  /// A press within this many radii of the centre is on the ring.
  public static let grabSlop: CGFloat = 1.25
  /// A press beside the ring, out to this many radii, turns the arm as the ring
  /// does (Jamie, 2026-11-19: "if you can have the control and the touch be
  /// slightly distant from each other, that could make that better").
  public static let touchReach: CGFloat = 2.1

  public let center: CGPoint, radius: CGFloat

  public init(center: CGPoint, radius: CGFloat) {
    self.center = center
    self.radius = radius
  }

  /// The clock on a screen of `bounds` with `bottomInset` of safe area.
  public init(bounds: CGRect, bottomInset: CGFloat) {
    radius = min(bounds.width * 0.22, bounds.height * 0.12, 114)
    center = CGPoint(x: bounds.midX, y: bounds.maxY - bottomInset - 42 - radius)
  }

  func distance(_ p: CGPoint) -> CGFloat { hypot(p.x - center.x, p.y - center.y) }
  /// Is the press on the ring (or its face)?
  public func onRing(_ p: CGPoint) -> Bool { distance(p) <= radius * Self.grabSlop }
  /// Is it beside the ring, where a finger hides nothing?
  public func beside(_ p: CGPoint) -> Bool {
    let d = distance(p)
    return d > radius * Self.grabSlop && d <= radius * Self.touchReach
  }
  /// The press as the unit point the input takes: the angle about the centre at any radius.
  public func unit(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (p.x - center.x) / radius, y: (p.y - center.y) / radius)
  }
  public func arm(at p: CGPoint) -> Double {
    atan2(Double(p.x - center.x), Double(p.y - center.y)) * 180 / .pi
  }
  public func point(arm: Double, radius r: CGFloat) -> CGPoint {
    let a = arm * .pi / 180
    return CGPoint(x: center.x + CGFloat(sin(a)) * r, y: center.y + CGFloat(cos(a)) * r)
  }
}

// MARK: - The linear meter

/// The linear meter: the dial unrolled into a straight track at the screen's
/// edge. The clock's 6 is the middle of the track, the knob's home; the
/// backswing runs down toward the player and the forward swing up toward the
/// target, on one scale both ways (the flick's speed is degrees a second on
/// either meter). The body is two columns in one ink frame: the lane, toward
/// the screen's centre, carries the targets; the channel, toward the edge,
/// carries the knob, so the knob and the finger on it never hide a target.
public struct LinearMeter: Equatable, Sendable {
  public struct Tune: Sendable {
    public var range = 180.0  // degrees each way: the ends are 12 o'clock
    public var bodyMax: CGFloat = 88  // pt: the body is never wider than this
    public var lane: CGFloat = 0.3  // the lane's width, of the body's
    public var knob: CGFloat = 0.4  // the knob's radius, of the channel's width
    public var frame: CGFloat = 0.07  // the ink frame, of the body's width
    public var shadow: CGFloat = 0.075  // the hard drop shadow, of the body's width
    public var corner: CGFloat = 0.12  // the body's corner radius, of its width
    public var endPad: CGFloat = 0.02  // past the knob at either end, of the width
    public var slot: CGFloat = 0.17  // the slot the knob runs in, of the channel's width
    public var promptH: CGFloat = 0.3  // the prompt tab's height, of the body's width
    public var promptMin: CGFloat = 18
    public var grabTouch: CGFloat = 46  // pt up or down from the knob that a finger grabs it
    // The box. Three quarters of the web's old finger travel (a tester: "Make it
    // 1/4 shorter", and Jamie agreed), the same as the web's from 2026-11-19:
    // 0.47 of the height, 390 to 450 pt (about 330 pt of track on a tall
    // phone), and a track never shorter than `minTravel`. The straight trial of
    // 2026-11-18 had about 300 pt for the whole swing and was, in Jamie's
    // words, "too cramped and visually looked janky": a screen that cannot
    // give `minTravel` gets the clock.
    public var heightShare: CGFloat = 0.47
    public var heightMin: CGFloat = 390
    public var heightMax: CGFloat = 450
    public var minTravel: CGFloat = 320
    // The smallest track on a wide screen (a phone on its side). The player's
    // choice of meter holds when the phone turns, so the wide box takes the whole
    // safe height at its edge (`WideLayout.edge` under the safe area's top to
    // `margin` over its bottom) and MENU or the rail moves inward beside it. The
    // shortest iPhones on their side (375 pt with a 21 pt home indicator: the
    // 12 and 13 mini, the 11 Pro) give that box 337 pt and 265.3 pt of track;
    // the SE (375, no insets) 286.3, the 16e 281.3, the 17 Pro Max 331.3 (both
    // with the simulator's 20 pt). So the wide floor is 260, a little under every
    // supported iPhone, where upright it stays 320: a phone on its side has no
    // taller track to give, and the swing spans the whole safe height, unlike
    // the 2026-11-18 trial's 300 pt in a corner.
    public var wideMinTravel: CGFloat = 260
    public var widthShare: CGFloat = 0.2  // the box's width, of the screen's
    public var widthMin: CGFloat = 64
    public var widthMax: CGFloat = 96
    public var margin: CGFloat = 7  // pt from the screen's edge and the bottom safe area
  }
  public static let tune = Tune()

  public let side: MeterSide
  public let box: CGRect
  /// The body (the shadow falls right and down beyond it).
  public let left, right, top, bottom, width, shadow, frame: CGFloat
  /// The lane's and the channel's left edges and widths, and the line between them.
  public let laneLeft, laneWidth, channelLeft, channelWidth, divider: CGFloat
  /// The direction the prompt tab hangs: -1 to the left (a meter at the right edge).
  public let tabDirection: CGFloat
  /// The knob's column, the lane's centre and the knob's radius.
  public let knobX, laneX, knobRadius, promptHeight: CGFloat
  /// The forward end (arm +range), the back end (-range) and home (0).
  public let yForward, yBack, yHome: CGFloat
  /// Track length and points per degree.
  public let travel, scale: CGFloat

  public init(box: CGRect, side: MeterSide, tune t: Tune = LinearMeter.tune) {
    self.side = side
    self.box = box
    let w = min(t.bodyMax, box.width * 0.92)
    let sh = w * t.shadow
    let fr = max(1.5, w * t.frame)
    let onLeft = side == .left
    // the hard shadow falls right and down: on the left edge the body starts at
    // the box's edge, on the right it stops short of it by the shadow
    let right = onLeft ? box.minX + w : box.maxX - sh
    let left = right - w
    let laneW = w * t.lane
    let chanW = w - laneW
    let laneLeft = onLeft ? right - laneW : left
    let chanX = onLeft ? left : left + laneW
    width = w
    shadow = sh
    frame = fr
    self.left = left
    self.right = right
    top = box.minY
    bottom = box.maxY - sh
    laneWidth = laneW
    self.laneLeft = laneLeft
    channelLeft = chanX
    channelWidth = chanW
    divider = onLeft ? laneLeft : chanX
    tabDirection = onLeft ? 1 : -1
    knobX = chanX + chanW / 2
    laneX = laneLeft + laneW / 2
    knobRadius = chanW * t.knob
    promptHeight = max(t.promptMin, w * t.promptH)
    // the knob at either end just meets the frame
    let cap = knobRadius + fr + w * t.endPad
    yForward = top + cap
    yBack = bottom - cap
    yHome = (yForward + yBack) / 2
    travel = max(0, yBack - yForward)
    scale = max(0.01, (yBack - yForward) / CGFloat(2 * t.range))
  }

  /// The y of an arm angle (degrees).
  public func y(arm: Double) -> CGFloat { yHome - CGFloat(arm) * scale }
  /// The arm at a y, kept on the track.
  public func arm(atY y: CGFloat) -> Double {
    let r = Self.tune.range
    return min(r, max(-r, Double((yHome - y) / scale)))
  }
  /// Is a press on the knob at its home? (Within `grabTouch` up or down.)
  public func knobHit(_ p: CGPoint, reach: CGFloat = LinearMeter.tune.grabTouch) -> Bool {
    p.x >= left - 6 && p.x <= right + 6 && abs(p.y - yHome) <= reach
  }
  /// Is it anywhere on the body? (The body keeps a press from the pitch behind it.)
  public func bodyHit(_ p: CGPoint) -> Bool {
    p.x >= left - 6 && p.x <= right + shadow + 6 && p.y >= top && p.y <= bottom + shadow
  }

  /// The linear meter on a screen, or nil where its track would be shorter than
  /// `minTravel` upright or `wideMinTravel` on a wide screen (then the clock is
  /// shown). On a tall screen the box starts under the HUD's header and the
  /// minimap; on a wide one it has the whole safe height at its edge.
  public static func layout(
    size: CGSize, safeTop: CGFloat, safeBottom: CGFloat, safeLeft: CGFloat = 0,
    safeRight: CGFloat = 0, side: MeterSide, tune t: Tune = LinearMeter.tune
  ) -> LinearMeter? {
    let w = max(t.widthMin, min(t.widthMax, size.width * t.widthShare))
    let bottom = size.height - safeBottom - t.margin
    let h: CGFloat
    let least: CGFloat
    if WideLayout.isWide(size) {
      // a phone on its side: from MENU's top (`WideLayout.edge` under the safe
      // area) to the bottom margin, at most `heightMax`. MENU or the rail, the
      // plate at that corner, moves inward beside it (`WideLayout.menu`, `rail`).
      // A wide iPad has more than `heightMax`, so its box stands on the bottom
      // margin as before and nothing moves.
      h = min(bottom - (safeTop + WideLayout.edge), t.heightMax)
      least = t.wideMinTravel
    } else {
      // the header plate and the minimap (BoardView: top + 75, 1.65 of its width)
      let mapW = min(74, size.width * 0.18)
      let ceiling = safeTop + 75 + mapW * 1.65 + 10
      // the web's (layout.js linearBox): 0.47 of the height, never under
      // `heightMin` where there is the room nor over `heightMax`
      h = min(bottom - ceiling, max(size.height * t.heightShare, t.heightMin), t.heightMax)
      least = t.minTravel
    }
    guard h > 0 else { return nil }
    let x = side == .left ? safeLeft + t.margin : size.width - safeRight - t.margin - w
    let meter = LinearMeter(box: CGRect(x: x, y: bottom - h, width: w, height: h), side: side, tune: t)
    return meter.travel >= least - 0.001 ? meter : nil
  }

  /// The body and its shadow: what the meter covers on the screen.
  public var cover: CGRect { CGRect(x: left, y: top, width: width + shadow, height: bottom + shadow - top) }
}

// MARK: - Which touches the meter claims

/// The meter on the screen: the clock, or the linear meter where the player
/// chose it and the screen has its room.
public enum MeterLayout: Equatable, Sendable {
  case clock(ClockMeter)
  case linear(LinearMeter)

  /// The throw zone (linear meter only): a drag that starts this far down the
  /// screen or lower strokes the knob as a grab of it does. Targets are always
  /// in the far half of the pitch and on a phone held upright the centre line is
  /// at about 0.54 of the height, so below 0.6 there is nothing to aim at.
  public static let zoneFrom: CGFloat = 0.6
  /// The throw zone on a wide screen: a drag that starts on the meter's side of
  /// this share of the width (the centre line, the throwing line) strokes the
  /// knob. The lower 40% of a phone on its side is about 156 pt, too shallow for
  /// a whole draw back and flick, so the zone is the meter's half, top to
  /// bottom: a thumb there has the screen's height for the stroke, and the plan
  /// block and the minimap are on the other half. A tap there still aims (the
  /// clock's outer reach's rule: where a tap could aim, only a drag throws), and
  /// a drag on the other half still moves the aim.
  public static let wideZone: CGFloat = 0.5

  public static func make(
    kind: MeterKind, side: MeterSide, bounds: CGRect, safeTop: CGFloat, safeBottom: CGFloat,
    safeLeft: CGFloat = 0, safeRight: CGFloat = 0
  ) -> MeterLayout {
    if kind == .linear,
      let m = LinearMeter.layout(
        size: bounds.size, safeTop: safeTop, safeBottom: safeBottom, safeLeft: safeLeft,
        safeRight: safeRight, side: side)
    {
      return .linear(m)
    }
    if WideLayout.isWide(bounds.size) {
      // lower left or right by Meter side, the minimap in the other corner
      let safe = ScreenInsets(top: safeTop, left: safeLeft, bottom: safeBottom, right: safeRight)
      return .clock(WideLayout.clock(size: bounds.size, safe: safe, side: side))
    }
    return .clock(ClockMeter(bounds: bounds, bottomInset: safeBottom))
  }

  public var linear: LinearMeter? {
    if case .linear(let m) = self { return m }
    return nil
  }
  public var clock: ClockMeter? {
    if case .clock(let c) = self { return c }
    return nil
  }

  /// What a press claims for the throw. The host asks in two steps, so the
  /// claims merge with whatever else the pitch takes:
  ///
  /// 1. `first(_:)`, before anything else (the target circle, the
  ///    thrower): the clock's ring (within 1.25 radii), the linear meter's knob
  ///    (46 pt up or down from home, across the body), then the rest of its body,
  ///    which takes the press and does nothing.
  /// 2. `after(_:in:aimable:)`, only when nothing else took the press (after the
  ///    target circle and the thrower, before a tap on the pitch): beside the
  ///    clock's ring (1.25 to 2.1 radii), or the linear meter's throw zone (the
  ///    lower 40% of a tall screen, the meter's half of a wide one). These wait to see whether they are a tap
  ///    (then the pitch's tap rules apply, as before) or a drag (then the throw).
  ///    Beside the clock where a tap could not aim, the press is the throw at once.
  public enum Claim: Equatable, Sendable {
    /// The throw now. `grab` is the linear meter's offset from home (the knob
    /// is grabbed relatively); 0 on the clock.
    case meter(grab: CGFloat)
    /// The throw now, from beside the clock's ring (draw the finger's spoke).
    case beside
    /// The linear meter's body away from its knob: swallowed, never a throw.
    case body
    /// A tap or the throw: decided by the first move past `tapSlop`.
    case zone
    /// A tap or the throw from beside the ring.
    case besidePending
  }

  /// pt a press may move and still be a tap.
  public static let tapSlop: CGFloat = 10

  public func first(_ p: CGPoint) -> Claim? {
    switch self {
    case .clock(let c): return c.onRing(p) ? .meter(grab: 0) : nil
    case .linear(let m):
      if m.knobHit(p) { return .meter(grab: p.y - m.yHome) }
      return m.bodyHit(p) ? .body : nil
    }
  }

  public func after(_ p: CGPoint, in size: CGSize, aimable: Bool) -> Claim? {
    switch self {
    case .clock(let c):
      guard c.beside(p) else { return nil }
      return aimable ? .besidePending : .beside
    case .linear(let m):
      if WideLayout.isWide(size) {
        let line = size.width * Self.wideZone
        return (m.side == .right ? p.x >= line : p.x <= line) ? .zone : nil
      }
      return p.y >= size.height * Self.zoneFrom ? .zone : nil
    }
  }

  /// The unit point the input takes for a finger at `p`. On the linear meter
  /// `grab` is the press's offset from the knob's home: the press point is home.
  public func unit(_ p: CGPoint, grab: CGFloat) -> CGPoint {
    switch self {
    case .clock(let c): return c.unit(p)
    case .linear(let m): return meterPoint(arm: m.arm(atY: p.y - grab))
    }
  }
}

extension PitchSession {
  /// Would a tap at `point` put the target circle there? (`target(tap: true)`'s rule.)
  public func tapCouldAim(_ point: CGPoint, size: CGSize) -> Bool {
    guard canAim, let g = scene.projection(size, camera).ground(point) else { return false }
    return g.y > 0.5
  }
}
