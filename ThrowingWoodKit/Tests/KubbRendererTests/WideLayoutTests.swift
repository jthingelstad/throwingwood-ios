import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// A phone on its side (WideLayout.swift): the web's wide arrangement on both
/// review phones held either way, with both meters and both sides.
@MainActor struct WideLayoutTests {
  /// The review phones on their side, turned left and turned right: the points
  /// and the safe area the iOS 26.2 simulator gives the app (the review's
  /// layout dump, 2026-11-19). The sensor housing's inset is on both sides
  /// whichever way the phone is turned, the home indicator's at the bottom, and
  /// there is no status bar.
  static let phones: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPhone 16e turned left", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 47, bottom: 20, right: 47)),
    ("iPhone 16e turned right", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 47, bottom: 20, right: 47)),
    ("iPhone 17 Pro Max turned left", CGSize(width: 956, height: 440), ScreenInsets(top: 0, left: 62, bottom: 20, right: 62)),
    ("iPhone 17 Pro Max turned right", CGSize(width: 956, height: 440), ScreenInsets(top: 0, left: 62, bottom: 20, right: 62)),
    // a phone whose housing is on one side only, in case iOS ever reports it so
    ("a lopsided phone", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 59, bottom: 21, right: 0)),
  ]
  /// The set-up tray's column as the app frames it (three 104 x 70 plates, 8 apart).
  static let block = Tray.column(wide: true)

  @Test func aPhoneOnItsSideIsWideAndUprightIsNot() {
    for p in Self.phones {
      #expect(WideLayout.isWide(p.size))
      #expect(!WideLayout.isWide(CGSize(width: p.size.height, height: p.size.width)))
    }
  }

  /// Every iPhone iOS 26 supports, on its side: the points and Apple's safe
  /// area in landscape (the sensor housing's inset on both sides, the home
  /// indicator's 21 at the bottom; the SE has none). The review phones above
  /// are the simulator's own; these are the rest, for the meter's room.
  static let iPhones: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPhone SE (2nd, 3rd)", CGSize(width: 667, height: 375), ScreenInsets()),
    ("iPhone 12 mini, 13 mini", CGSize(width: 812, height: 375), ScreenInsets(top: 0, left: 50, bottom: 21, right: 50)),
    ("iPhone 11 Pro", CGSize(width: 812, height: 375), ScreenInsets(top: 0, left: 44, bottom: 21, right: 44)),
    ("iPhone 11, 11 Pro Max", CGSize(width: 896, height: 414), ScreenInsets(top: 0, left: 48, bottom: 21, right: 48)),
    ("iPhone 12 to 14, 16e", CGSize(width: 844, height: 390), ScreenInsets(top: 0, left: 47, bottom: 21, right: 47)),
    ("iPhone 14 Pro, 15, 16", CGSize(width: 852, height: 393), ScreenInsets(top: 0, left: 59, bottom: 21, right: 59)),
    ("iPhone 16 Pro, 17, 17 Pro", CGSize(width: 874, height: 402), ScreenInsets(top: 0, left: 62, bottom: 21, right: 62)),
    ("iPhone Air", CGSize(width: 912, height: 420), ScreenInsets(top: 0, left: 62, bottom: 21, right: 62)),
    ("iPhone 12 Pro Max to 14 Plus", CGSize(width: 926, height: 428), ScreenInsets(top: 0, left: 47, bottom: 21, right: 47)),
    ("iPhone 14 Pro Max to 16 Plus", CGSize(width: 932, height: 430), ScreenInsets(top: 0, left: 59, bottom: 21, right: 59)),
    ("iPhone 16 Pro Max, 17 Pro Max", CGSize(width: 956, height: 440), ScreenInsets(top: 0, left: 62, bottom: 21, right: 62)),
  ]

  private func make(_ kind: MeterKind, _ side: MeterSide, _ size: CGSize, _ s: ScreenInsets) -> MeterLayout {
    MeterLayout.make(
      kind: kind, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: s.top,
      safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
  }

  /// The reported bug (Jamie, 2026-11-19: "On iPhone if I turn on linear and then
  /// rotate it goes back to the circular swing."): Linear chosen is the linear
  /// meter on a phone on its side.
  @Test func linearChosenStaysLinearWhenTheIPhoneTurns() {
    let s = ScreenInsets(top: 0, left: 47, bottom: 20, right: 47)
    for side in MeterSide.allCases {
      #expect(make(.linear, side, CGSize(width: 390, height: 844), ScreenInsets(top: 47, bottom: 34)).linear != nil)
      #expect(make(.linear, side, CGSize(width: 844, height: 390), s).linear != nil, "\(side)")
    }
  }

  /// Every iPhone on its side gives the linear meter its wide room: the whole
  /// safe height at its edge, a track of at least `wideMinTravel`.
  @Test func everyIPhoneOnItsSideShowsTheLinearMeter() throws {
    for p in Self.iPhones + Self.phones {
      for side in MeterSide.allCases {
        let m = try #require(make(.linear, side, p.size, p.safe).linear, "\(p.name) \(side)")
        #expect(m.travel >= LinearMeter.tune.wideMinTravel, "\(p.name)")
        // the whole safe height: MENU's top to the bottom margin
        #expect(abs(m.box.minY - (p.safe.top + WideLayout.edge)) < 0.001, "\(p.name)")
        #expect(abs(m.box.maxY - (p.size.height - p.safe.bottom - LinearMeter.tune.margin)) < 0.001)
        #expect(side == .left ? m.box.minX == p.safe.left + 7 : m.box.maxX == p.size.width - p.safe.right - 7)
        // the clock is still what Clock shows
        #expect(make(.clock, side, p.size, p.safe) == .clock(WideLayout.clock(size: p.size, safe: p.safe, side: side)))
      }
    }
    // the shortest (375 pt with a home indicator) and the tallest, to the tenth
    let mini = try #require(make(.linear, .right, Self.iPhones[1].size, Self.iPhones[1].safe).linear)
    #expect(abs(mini.travel - 265.3) < 0.05)
    let max = try #require(make(.linear, .right, Self.iPhones.last!.size, Self.iPhones.last!.safe).linear)
    #expect(abs(max.travel - 330.3) < 0.05)
  }

  /// Where a wide screen cannot give even `wideMinTravel` (a window no iPhone
  /// has), the clock is shown, and the menu's note says so (MeterSettings).
  @Test func aWideScreenTooShortForTheTrackShowsTheClock() {
    let size = CGSize(width: 700, height: 330)
    for side in MeterSide.allCases {
      let m = make(.linear, side, size, ScreenInsets(top: 0, bottom: 21))
      #expect(m == .clock(WideLayout.clock(size: size, safe: ScreenInsets(top: 0, bottom: 21), side: side)))
    }
  }

  /// What is at the meter's top corner moves in beside it, `edge` off its body: the
  /// header (MENU inside it) with the meter at the left, HOLLER online with it at the
  /// right; the other stays where it was. MENU never leaves the header (the 1.0
  /// design's header: "MENU never leaves it").
  @Test func theHeaderOrShoutMovesInBesideTheLinearMeter() throws {
    for p in Self.iPhones + Self.phones {
      let s = p.safe
      let right = try #require(make(.linear, .right, p.size, s).linear)
      let shout = WideLayout.shout(size: p.size, safe: s, meter: .linear(right))
      #expect(abs(shout.maxX - (right.cover.minX - WideLayout.edge)) < 0.001, "\(p.name)")
      #expect(WideLayout.rail(size: p.size, safe: s, meter: .linear(right)) == WideLayout.rail(size: p.size, safe: s))
      let left = try #require(make(.linear, .left, p.size, s).linear)
      let rail = WideLayout.rail(size: p.size, safe: s, meter: .linear(left))
      #expect(abs(rail.minX - (left.cover.maxX + WideLayout.edge)) < 0.001, "\(p.name)")
      #expect(WideLayout.shout(size: p.size, safe: s, meter: .linear(left)) == WideLayout.shout(size: p.size, safe: s))
      // the clock moves nothing
      let clock = make(.clock, .right, p.size, s)
      #expect(WideLayout.shout(size: p.size, safe: s, meter: clock) == WideLayout.shout(size: p.size, safe: s))
      for meter in [MeterLayout.linear(right), .linear(left), clock] {
        let r = WideLayout.rail(size: p.size, safe: s, meter: meter)
        #expect(r.contains(WideLayout.menu(size: p.size, safe: s, meter: meter)), "\(p.name): MENU inside the header")
      }
    }
  }

  /// The throw zone on a wide screen is the meter's half; a tap there still aims.
  @Test func theWideThrowZoneIsTheMetersHalf() throws {
    for p in Self.iPhones + Self.phones {
      for side in MeterSide.allCases {
        let ml = make(.linear, side, p.size, p.safe)
        let mid = p.size.width / 2
        let inside = side == .right ? mid + 1 : mid - 1
        let outside = side == .right ? mid - 1 : mid + 1
        for y in [p.size.height * 0.1, p.size.height * 0.5, p.size.height - 2] {
          #expect(ml.after(CGPoint(x: inside, y: y), in: p.size, aimable: true) == .zone, "\(p.name) \(side)")
          #expect(ml.after(CGPoint(x: outside, y: y), in: p.size, aimable: true) == nil, "\(p.name) \(side)")
        }
        // the tray and an open plate are on the other half (the minimap hangs under
        // the header wherever the header is: a picture, it takes no touch)
        let plan = WideLayout.plan(meter: ml, size: p.size, safe: p.safe, side: side)
        for f in [plan.block, plan.reach] {
          #expect(side == .right ? f.maxX < mid : f.minX > mid, "\(p.name) \(side)")
        }
        // a whole stroke fits: from home, the track's full draw back and flick
        // are on the screen for a press level with the knob's home
        let m = try #require(ml.linear)
        #expect(m.yHome - 180 * m.scale >= 0 && m.yHome + 180 * m.scale <= p.size.height - p.safe.bottom)
      }
    }
  }

  @Test func aWideLinearMeterFollowsTheWebsRuleWhereThereIsTheRoom() throws {
    // a tablet-sized wide screen: at its edge, 450 pt on the bottom margin, under the rail or MENU
    let size = CGSize(width: 1180, height: 820)
    let safe = ScreenInsets(top: 24, bottom: 20)
    let left = try #require(
      LinearMeter.layout(size: size, safeTop: 24, safeBottom: 20, side: .left))
    #expect(left.box.minX == 7 && left.box.height == 450)
    #expect(left.box.minY >= WideLayout.rail(size: size, safe: safe).maxY)
    let right = try #require(
      LinearMeter.layout(size: size, safeTop: 24, safeBottom: 20, side: .right))
    #expect(right.box.maxX == size.width - 7)
  }

  @Test func theClockIsTheWebsWideClockInTheChosenCorner() {
    let p = Self.phones[0]
    let r = WideLayout.clockBox(size: p.size, safe: p.safe, side: .right)
    // S = min(0.28 W, 0.5 H, 380) = 195, 1.2 S tall, 14 in, its foot 7 over the safe area
    #expect(abs(r.width - 195) < 1e-9 && abs(r.height - 234) < 1e-9)
    #expect(r.maxX == p.size.width - 47 - 14 && r.maxY == p.size.height - p.safe.bottom - 7)
    let c = WideLayout.clock(size: p.size, safe: p.safe, side: .right)
    #expect(abs(c.radius - (195 - 2 * 7.8) / 2.12) < 1e-9)
    let l = WideLayout.clock(size: p.size, safe: p.safe, side: .left)
    #expect(abs((p.size.width - l.center.x) - c.center.x) < 1e-9 && l.center.y == c.center.y)
    // about the size of the upright 16e's (86)
    #expect(c.radius > 80 && c.radius < 90)
  }

  @Test func nothingOverlapsAndAllIsInsideTheSafeArea() {
    for p in Self.phones + Self.iPhones {
      let safeRect = CGRect(
        x: p.safe.left, y: p.safe.top, width: p.size.width - p.safe.left - p.safe.right,
        height: p.size.height - p.safe.top - p.safe.bottom)
      for kind in MeterKind.allCases {
        for side in MeterSide.allCases {
          let s = p.safe
          let meter = MeterLayout.make(
            kind: kind, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: s.top,
            safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
         for online in [false, true] {
          // MENU is inside the header's plate (checked there), not a frame of its own
          #expect(
            WideLayout.rail(size: p.size, safe: s, meter: meter).contains(WideLayout.menu(size: p.size, safe: s, meter: meter)))
          let plan = WideLayout.plan(
            meter: meter, size: p.size, safe: s, side: side, trayWidth: online ? WideLayout.trayWidth : 0)
          var frames: [(String, CGRect)] = [
            ("rail", WideLayout.rail(size: p.size, safe: s, meter: meter)),
            // the room the caption stack may grow into, not only its line
            ("caption", WideLayout.captionRoom(
              size: p.size, safe: s, trayWidth: online ? WideLayout.trayWidth : 0, meter: meter, side: side)),
            ("minimap", plan.minimap),
            ("meter", WideLayout.meterBox(meter, size: p.size, safe: s, side: side)),
            ("tray", plan.block),
          ]
          // all an open plate may take, beside and over the column, meets nothing else
          frames[4] = ("tray", plan.reach)
          if let m = meter.linear { frames.append(("tab", m.tab)) }
          // online, HOLLER top right (beside a linear meter at the right)
          if online { frames.append(("shout", WideLayout.shout(size: p.size, safe: s, meter: meter))) }
          let what = "\(p.name) \(kind) \(side)\(online ? " online" : "")"
          #expect(!plan.minimap.isNull, "\(what): no minimap")
          for (name, f) in frames {
            #expect(safeRect.contains(f), "\(what): \(name) \(f) outside \(safeRect)")
          }
          for i in frames.indices {
            for j in frames.indices where j > i {
              let (a, fa) = frames[i]
              let (b, fb) = frames[j]
              #expect(!fa.intersects(fb), "\(what): \(a) \(fa) meets \(b) \(fb)")
            }
          }
          // the caption keeps room for a word: at its narrowest, the SE online
          // beside a linear meter, 112.6 pt (the verdict's flag shrinks to fit)
          #expect(frames[1].1.width >= 112, "\(what): caption \(frames[1].1.width)")
         }
          let what = "\(p.name) \(kind) \(side)"
          // the ring and its rim are on the screen, clear of the home indicator
          if let c = meter.clock {
            #expect(c.center.y + c.radius * 1.12 <= p.size.height - s.bottom)
            #expect(c.center.x - c.radius * 1.12 >= s.left && c.center.x + c.radius * 1.12 <= p.size.width - s.right)
          }
          // the tray's column is at the screen's edge away from the meter, 12 in from
          // the safe area, its foot 10 above the meter's box's foot, three plates of
          // 104 by 70 8 apart; an open plate grows up from its place
          let plan = WideLayout.plan(meter: meter, size: p.size, safe: s, side: side)
          let box = WideLayout.meterBox(meter, size: p.size, safe: s, side: side)
          #expect(plan.edge == (side == .right ? .left : .right), "\(what)")
          #expect(plan.block.size == CGSize(width: 104, height: 226))
          #expect(
            side == .right
              ? plan.block.minX == s.left + 12 : plan.block.maxX == p.size.width - s.right - 12, "\(what)")
          #expect(plan.block.maxY == box.maxY - WideLayout.planLift)
          let rail = WideLayout.rail(size: p.size, safe: s, meter: meter)
          for open in TrayPlate.allCases {
            let f = plan.tray.plates(open: open)
            #expect(f[open]!.maxY <= plan.block.maxY && f[open]!.minY >= plan.tray.ceiling, "\(what) \(open)")
            #expect(f[open]!.minY >= rail.maxY + 8 || !f[open]!.intersects(rail))
          }
          // the minimap hangs under the header's right end (the 1.0 design: one home), or,
          // where that end is over the throwing line (beside a linear meter at the left),
          // under the header short of the line, so it does not cover the pitch's middle;
          // on the narrowest phones (SE, the minis, 11 Pro) that place meets the meter's
          // tab and the map stays under the header's right end
          let centre = p.size.width / 2, line = centre - WideLayout.planClear
          let narrowest = p.size.width < 820
          #expect(
            (plan.minimap.maxX == rail.maxX || (rail.maxX > line && plan.minimap.maxX == line))
              && plan.minimap.minY == rail.maxY + 8, "\(what): \(plan.minimap)")
          if !narrowest {
            #expect(plan.minimap.maxX <= line, "\(what): minimap \(plan.minimap) on the throwing line")
          }
          // nothing on the throwing line: the tray and an open plate stop 24 short of
          // the screen's centre, the meter is on the other half
          for f in [plan.block, plan.reach] {
            #expect(side == .right ? f.maxX <= centre - 24 : f.minX >= centre + 24, "\(what): \(f)")
          }
          #expect(side == .right ? box.minX > centre : box.maxX < centre)
          // and clear of the clock's outer touch zone (a press beside the ring)
          if let c = meter.clock {
            #expect(
              distance(c.center, plan.reach) > c.radius * ClockMeter.touchReach, "\(what): \(plan.reach) in the clock's reach")
          }
          // the meter has not moved for it
          #expect(meter == MeterLayout.make(
            kind: kind, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: s.top,
            safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right))
          if let c = meter.clock { #expect(c == WideLayout.clock(size: p.size, safe: s, side: side)) }
        }
      }
    }
  }

  // MARK: The same game on an iPad

  /// The review iPads on their side, as the iOS 26.2 simulator gives them to the
  /// app in full screen (the review's layout dump, 2026-11-19): the status bar's
  /// inset at the top and the home indicator's at the bottom, none at the sides.
  static let iPads: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPad mini (A17 Pro) on its side", CGSize(width: 1133, height: 744), ScreenInsets(top: 32, bottom: 20)),
    ("iPad Pro 13-inch (M5) on its side", CGSize(width: 1376, height: 1032), ScreenInsets(top: 32, bottom: 20)),
  ]

  /// Every frame of the wide arrangement inside the safe area and none meeting
  /// another, the clock's ring and rim on the screen, and the plan block and the
  /// minimap off the throwing line: what holds on a phone holds on any wide screen.
  private func holds(_ name: String, _ size: CGSize, _ s: ScreenInsets, kind: MeterKind, side: MeterSide) {
    let safeRect = CGRect(
      x: s.left, y: s.top, width: size.width - s.left - s.right, height: size.height - s.top - s.bottom)
    let meter = MeterLayout.make(
      kind: kind, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: s.top,
      safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
    let plan = WideLayout.plan(meter: meter, size: size, safe: s, side: side)
    // every frame of the wide layout, solo and online (Codex on PR #25 found
    // the tab, then the caption, missing from this list: keep it whole)
    for online in [false, true] {
      let tray = online ? WideLayout.trayWidth : 0
      let plan = WideLayout.plan(meter: meter, size: size, safe: s, side: side, trayWidth: tray)
      #expect(plan.block.width == WideLayoutTests.block.width && plan.tray.plate.height >= 48)
      let caption = WideLayout.caption(size: size, safe: s, trayWidth: tray, meter: meter, side: side)
      // the stack (wind or a held slider's words over the verdict) is framed to
      // this room, from the caption's line down to the first frame under it
      let room = WideLayout.captionRoom(size: size, safe: s, trayWidth: tray, meter: meter, side: side)
      #expect(WideLayout.rail(size: size, safe: s, meter: meter).contains(WideLayout.menu(size: size, safe: s, meter: meter)))
      var frames: [(String, CGRect)] = [
        ("rail", WideLayout.rail(size: size, safe: s, meter: meter)),
        ("caption", room),
        ("meter", WideLayout.meterBox(meter, size: size, safe: s, side: side)),
        // the column and all an open plate may take
        ("tray", plan.reach),
      ]
      if online { frames.append(("shout", WideLayout.shout(size: size, safe: s, meter: meter))) }
      // a minimap with no room over the block in a narrow window is not drawn
      if !plan.minimap.isNull { frames.append(("minimap", plan.minimap)) }
      // the prompt tab and the coach line hanging under it, in every window
      if let m = meter.linear {
        frames.append(("tab", m.tab))
        frames.append(("coach", WideLayout.coachBand(m, size: size)))
      }
      let what = "\(name) \(Int(size.width)) x \(Int(size.height)) \(kind) \(side)\(online ? " online" : "")"
      #expect(caption.width >= WideLayout.captionMin, "\(what): caption \(caption.width) pt")
      #expect(room.minY == caption.minY && room.width == caption.width && room.height >= caption.height,
        "\(what): caption room \(room) for \(caption)")
      for (n, f) in frames {
        #expect(safeRect.contains(f), "\(what): \(n) \(f) outside \(safeRect)")
      }
      for i in frames.indices {
        for j in frames.indices where j > i {
          #expect(!frames[i].1.intersects(frames[j].1), "\(what): \(frames[i].0) \(frames[i].1) meets \(frames[j].0) \(frames[j].1)")
        }
      }
      // the nudge's fingertip, its whole swing, on the screen and off every
      // control and plate. Never with the coach line (BoardView shows one or the
      // other). Where the meter's half is narrower than the tab and a fingertip
      // (a window under about 600 pt) the fingertip passes over the tab's words.
      if let m = meter.linear {
        let nudge = m.nudgeSweep(
          swing: NudgeSwing(back: NudgeTune().defaultBack, release: NudgeTune().defaultRelease), size: size,
          safeLeft: s.left, safeRight: s.right, ceiling: caption.maxY)
        let R = LinearMeter.nudgeFinger
        let narrow = m.side == .right ? m.tab.minX < size.width / 2 + 2 * R + 4 : m.tab.maxX > size.width / 2 - 2 * R - 4
        #expect(nudge.minY >= 0 && nudge.maxY <= size.height, "\(what): nudge \(nudge)")
        // the ghost may pass over the verdict below the caption's line (a
        // drawing over a drawing), never over the line itself
        // nor over the minimap, a picture under the header's right end, which beside a
        // linear meter at the left reaches the meter's half
        for (n, f) in frames + [("caption line", caption)]
        where n != "coach" && n != "caption" && n != "minimap" && !(n == "tab" && narrow) {
          #expect(!nudge.intersects(f), "\(what): nudge \(nudge) meets \(n) \(f)")
        }
      }
    }
    // the practice pitch's header: inside, clear of the meter, its tab, coach line and nudge
    let header = WideLayout.practiceHeader(size: size, safe: s, meter: meter)
    let what = "\(name) \(Int(size.width)) x \(Int(size.height)) \(kind) \(side)"
    #expect(safeRect.contains(header) && header.width >= 200, "\(what): practice header \(header)")
    var practice = [WideLayout.meterBox(meter, size: size, safe: s, side: side)]
    if let m = meter.linear {
      practice += [
        m.tab, WideLayout.coachBand(m, size: size),
        m.nudgeSweep(
          swing: NudgeSwing(back: 120, release: 90), size: size, safeLeft: s.left, safeRight: s.right,
          ceiling: header.maxY),
      ]
    }
    for f in practice { #expect(!header.intersects(f), "\(what): practice header meets \(f)") }
    if let c = meter.clock {
      #expect(c.center.y + c.radius * 1.12 <= size.height - s.bottom, "\(what)")
      #expect(
        c.center.x - c.radius * 1.12 >= s.left && c.center.x + c.radius * 1.12 <= size.width - s.right, "\(what)")
    }
    // The tray and an open plate beside it are clear of a press beside the ring and
    // off the throwing line. (The minimap, under the header's right end, is a
    // picture: where it could not keep out of the way it is not drawn.)
    if let c = meter.clock {
      #expect(distance(c.center, plan.reach) > c.radius * ClockMeter.touchReach, "\(what): \(plan.reach) in the clock's reach")
    }
    let centre = size.width / 2
    #expect(side == .right ? plan.reach.maxX <= centre - 24 : plan.reach.minX >= centre + 24, "\(what): \(plan.reach)")
  }

  @Test func anIPadOnItsSideIsTheWideArrangementWithTheLinearMetersRoom() throws {
    for p in Self.iPads {
      #expect(WideLayout.isWide(p.size) && !WideLayout.isShort(p.size))
      for side in MeterSide.allCases {
        // the web's linearBox: a wide screen's track is 450 pt, at its edge
        let m = try #require(
          LinearMeter.layout(size: p.size, safeTop: p.safe.top, safeBottom: p.safe.bottom, side: side), "\(p.name)")
        #expect(m.box.height == 450 && m.travel >= 320)
        #expect(side == .left ? m.box.minX == 7 : m.box.maxX == p.size.width - 7)
        // standing on the bottom margin as before: the rail and MENU keep their corners
        #expect(abs(m.box.maxY - (p.size.height - p.safe.bottom - 7)) < 0.001)
        #expect(WideLayout.rail(size: p.size, safe: p.safe, meter: .linear(m)) == WideLayout.rail(size: p.size, safe: p.safe))
        #expect(WideLayout.menu(size: p.size, safe: p.safe, meter: .linear(m)) == WideLayout.menu(size: p.size, safe: p.safe))
        for kind in MeterKind.allCases {
          holds(p.name, p.size, p.safe, kind: kind, side: side)
          // the tray at the edge away from the meter: two hands, as on a phone; ARC
          // open grows to its whole height beside it
          let meter = MeterLayout.make(
            kind: kind, side: side, bounds: CGRect(origin: .zero, size: p.size), safeTop: p.safe.top,
            safeBottom: p.safe.bottom)
          let plan = WideLayout.plan(meter: meter, size: p.size, safe: p.safe, side: side)
          #expect(plan.edge == (side == .right ? .left : .right), "\(p.name) \(kind) \(side)")
          #expect(plan.block.size == Tray.column(wide: true) && !plan.minimap.isNull)
          #expect(plan.tray.open(.arc) == (CGSize(width: 104, height: 300), false))
        }
      }
      // the clock is the web's wide clock: S = min(0.28 W, 0.46 H, 380), not a phone's
      let box = WideLayout.clockBox(size: p.size, safe: p.safe, side: .right)
      #expect(abs(box.width - min(p.size.width * 0.28, p.size.height * 0.46, 380)) < 1e-9)
    }
  }

  @Test func anIPadUprightIsThePhoneLayoutWithTheLinearMeterAtItsCap() throws {
    for p in Self.iPads {
      let size = CGSize(width: p.size.height, height: p.size.width)
      #expect(!WideLayout.isWide(size))
      let m = try #require(LinearMeter.layout(size: size, safeTop: 32, safeBottom: 20, side: .right))
      #expect(abs(m.box.height - 450) < 0.001 && m.travel >= 320)
      // the upright clock keeps the phone's cap: the controls do not grow
      let c = ClockMeter(bounds: CGRect(origin: .zero, size: size), bottomInset: 20)
      #expect(c.radius == 114)
    }
  }

  /// An iPad's window can be any size (iPadOS 26): every wide one from a phone's
  /// on its side to a 13-inch iPad's, in full screen (the status bar's inset)
  /// and in a window (10 pt, or 53 under the window's controls).
  @Test func everyWideWindowHolds() {
    let insets = [
      ScreenInsets(top: 32, bottom: 20), ScreenInsets(top: 10, bottom: 10), ScreenInsets(top: 53, bottom: 10),
    ]
    var checked = 0
    for w in stride(from: CGFloat(480), through: 1400, by: 20) {
      for h in stride(from: CGFloat(380), through: 1040, by: 20) {
        let size = CGSize(width: w, height: h)
        guard WideLayout.isWide(size) else { continue }
        for s in insets {
          for kind in MeterKind.allCases {
            for side in MeterSide.allCases {
              holds("window", size, s, kind: kind, side: side)
              checked += 1
            }
          }
        }
      }
    }
    #expect(checked > 10_000)
  }

  /// Upright windows, from a phone's width to a 13-inch iPad's: the phone's
  /// layout, its clock no bigger than the phone's cap, the linear meter only
  /// with its 320 pt of track and never over 450 pt, both inside the window.
  @Test func everyUprightWindowKeepsThePhonesMeters() {
    for w in stride(from: CGFloat(320), through: 1040, by: 20) {
      for h in stride(from: CGFloat(480), through: 1380, by: 20) {
        let size = CGSize(width: w, height: h)
        guard !WideLayout.isWide(size) else { continue }
        let c = ClockMeter(bounds: CGRect(origin: .zero, size: size), bottomInset: 20)
        #expect(c.radius <= 114)
        #expect(c.center.y + c.radius * 1.12 <= h - 20 && c.center.x - c.radius * 1.12 >= 0)
        for side in MeterSide.allCases {
          if let m = LinearMeter.layout(size: size, safeTop: 53, safeBottom: 10, side: side) {
            #expect(m.travel >= 320 && m.box.height <= 450 + 0.001)
            #expect(m.box.minX >= 0 && m.box.maxX <= w && m.box.minY >= 53 && m.box.maxY <= h - 10)
          }
        }
      }
    }
  }

  /// The whole list on every iPhone on its side, both meters, both sides, solo and online.
  @Test func everyIPhoneOnItsSideHoldsTheWholeList() {
    for p in Self.phones + Self.iPhones {
      for kind in MeterKind.allCases {
        for side in MeterSide.allCases { holds(p.name, p.size, p.safe, kind: kind, side: side) }
      }
    }
  }

  /// Short, narrow windows (Codex on PR #25: 480 x 400 with 10 pt insets put
  /// ARC over the tab): the tray stays at the far edge, and an open plate never
  /// reaches the tab or the coach line.
  @Test func shortNarrowWindowsKeepTheTrayOffTheTab() throws {
    let insets = [
      ScreenInsets(top: 10, bottom: 10), ScreenInsets(top: 32, bottom: 20), ScreenInsets(top: 53, bottom: 10),
    ]
    for w in stride(from: CGFloat(480), through: 620, by: 10) {
      for h in stride(from: CGFloat(360), through: 480, by: 10) {
        let size = CGSize(width: w, height: h)
        guard WideLayout.isWide(size) else { continue }
        for s in insets {
          for side in MeterSide.allCases {
            let drawn = MeterLayout.make(
              kind: .linear, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: s.top,
              safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
            // where the track has no 260 pt the clock is drawn, and its layout
            // is the web's, unchanged here (under 380 tall it is not checked)
            guard drawn.linear != nil || h >= 380 else { continue }
            holds("short window \(Int(s.top))/\(Int(s.bottom))", size, s, kind: .linear, side: side)
            if h >= 380 { holds("short window \(Int(s.top))/\(Int(s.bottom))", size, s, kind: .clock, side: side) }
          }
        }
      }
    }
    // the reported window
    let size = CGSize(width: 480, height: 400), s = ScreenInsets(top: 10, bottom: 10)
    for side in MeterSide.allCases {
      for kind in MeterKind.allCases {
        let meter = MeterLayout.make(
          kind: kind, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: 10, safeBottom: 10)
        let plan = WideLayout.plan(meter: meter, size: size, safe: s, side: side)
        #expect(plan.edge == (side == .right ? .left : .right))
        if let m = meter.linear {
          #expect(!plan.reach.intersects(m.tab) && !plan.reach.intersects(WideLayout.coachBand(m, size: size)))
        }
      }
    }
  }

  /// The nearest a rect comes to a point.
  private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
    hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
  }

  /// The tray's column at the far edge, mirrored for a clock at the left, and the
  /// minimap under the header's right end: the numbers on a 852 x 393 phone (insets
  /// 59 a side and 21 at the bottom). Before the 1.0 tray the block (TILT over STAND
  /// beside ARC over SIDE VIEW, 206 x 212) stood here and the minimap 12 pt on its
  /// inner side, in the clock's corner's y.
  @Test func theTrayIsAtTheFarEdgeMirroredForAClockAtTheLeft() {
    let safe = ScreenInsets(top: 0, left: 59, bottom: 21, right: 59)
    func at(_ size: CGSize, _ side: MeterSide) -> WideLayout.Plan {
      let m = MeterLayout.clock(WideLayout.clock(size: size, safe: safe, side: side))
      return WideLayout.plan(meter: m, size: size, safe: safe, side: side)
    }
    func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.05 }
    func near(_ a: CGRect, _ b: CGRect) -> Bool {
      near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }
    let right = at(CGSize(width: 852, height: 393), .right)
    #expect(right.edge == .left && near(right.block, CGRect(x: 71, y: 129, width: 104, height: 226)))
    // the header: 0.4 of the width, short of the throwing line (852 / 2 - 24 - 69)
    let rail = WideLayout.rail(size: CGSize(width: 852, height: 393), safe: safe)
    #expect(near(rail, CGRect(x: 69, y: 10, width: 333, height: 62)))
    #expect(near(right.minimap.maxX, 402) && near(right.minimap.minY, 80) && near(right.minimap.width, 62.9))
    // ARC open grows up from its place as far as the room under the header row (72 +
    // 8) leaves with the other two showing: 355 - 80 - 2 x 78 = 119, over the web's
    // openMin of 100, so it does not cover them
    #expect(right.tray.ceiling == 80)
    #expect(right.tray.open(.arc) == (CGSize(width: 104, height: 119), false))
    // TILT opens in toward the middle, 240 wide, short of the minimap
    #expect(right.tray.open(.tilt).size.width == 240 || right.tray.open(.tilt).size.width < 240)
    let left = at(CGSize(width: 852, height: 393), .left)
    #expect(left.edge == .right && near(left.block, CGRect(x: 677, y: 129, width: 104, height: 226)))
    // the minimap does not follow the meter: it is the header's
    #expect(left.minimap == right.minimap)
  }

  /// A square window (H = W) keeps the column at the far edge, off the throwing line;
  /// there is no longer a fallback beside the clock (the tray is narrow enough).
  @Test func aSquareWindowKeepsTheTrayAtTheFarEdge() {
    let size = CGSize(width: 420, height: 420)
    for side in MeterSide.allCases {
      let m = MeterLayout.clock(WideLayout.clock(size: size, safe: ScreenInsets(), side: side))
      let plan = WideLayout.plan(meter: m, size: size, safe: ScreenInsets(), side: side)
      #expect(plan.edge == (side == .right ? .left : .right))
      #expect(side == .right ? plan.block.maxX <= 210 - 24 : plan.block.minX >= 210 + 24)
    }
  }

  @Test func theUprightClockIsUnchanged() {
    let b = CGRect(x: 0, y: 0, width: 390, height: 844)
    #expect(
      MeterLayout.make(kind: .clock, side: .left, bounds: b, safeTop: 47, safeBottom: 34)
        == .clock(ClockMeter(bounds: b, bottomInset: 34)))
  }

  private func aiming() throws -> PitchSession {
    let file = try #require(
      Bundle.module.url(forResource: "aim", withExtension: "json", subdirectory: "Fixtures/solo"))
    let app = try PitchSession(appVersion: "test")
    try app.restore(String(contentsOf: file, encoding: .utf8), save: nil)
    app.dismissHandoff()
    return app
  }

  @Test func turningTheScreenLetsGoOfASliderAndTheRestOfThatDragIsIgnored() throws {
    let app = try aiming()
    let arc = app.arcDegrees
    app.slide(.arc, to: 0.9, phase: .down)
    #expect(app.held == .arc)
    app.cancelHeld()
    #expect(app.held == nil)
    // the same finger keeps moving and lifts: nothing is held or sent
    app.slide(.arc, to: 0.1, phase: .move)
    #expect(app.held == nil)
    app.slide(.arc, to: 0.1, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.arcDegrees == arc)
    // a new press works as ever
    app.slide(.arc, to: 0.8, phase: .down)
    #expect(app.held == .arc)
    app.slide(.arc, to: 0.8, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.arcDegrees != arc)
  }

  @Test func turningTheScreenLetsGoOfStand() throws {
    let app = try aiming()
    let before = try #require(app.scene.thrower)
    app.stand(fx: 0.1, fy: 0.9, phase: .down)
    app.cancelHeld()
    #expect(!app.standHeld)
    app.stand(fx: 0.1, fy: 0.9, phase: .move)
    app.stand(fx: 0.1, fy: 0.9, phase: .up)
    try app.tick(1.0 / 60)
    #expect(try #require(app.scene.thrower).x == before.x)
    #expect(!app.standHeld)
  }
}
