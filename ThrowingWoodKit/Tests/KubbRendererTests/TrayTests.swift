import CoreGraphics
import Foundation
import Testing

@testable import KubbRenderer

/// Stage 3 of the 1.0 design, the play screens: the set-up tray's place in each layout
/// and meter side, an open plate (one at a time), the minimap's home, the meter's
/// distance tab, the verdict's order and arrows, the hand-off's line, the computer's turn
/// with no card, the header's words and the coach's.
@MainActor struct TrayTests {
  /// The review phones upright, as the iOS 26.2 simulator gives them to the app.
  static let upright: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("iPhone 16e", CGSize(width: 390, height: 844), ScreenInsets(top: 47, bottom: 34)),
    ("iPhone 17 Pro Max", CGSize(width: 440, height: 956), ScreenInsets(top: 62, bottom: 34)),
    ("iPhone SE", CGSize(width: 375, height: 667), ScreenInsets(top: 20, bottom: 0)),
    ("iPad mini upright", CGSize(width: 744, height: 1133), ScreenInsets(top: 32, bottom: 20)),
  ]

  private func meter(_ kind: MeterKind, _ side: MeterSide, _ size: CGSize, _ s: ScreenInsets) -> MeterLayout {
    MeterLayout.make(
      kind: kind, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: s.top,
      safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
  }

  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  // MARK: The tray's place

  /// Upright the column is at the left edge beside the clock, mirrored when the meter
  /// is at the left (the clock's Meter side Left, or the linear meter there): the other
  /// side of the meter, where the throwing thumb lands, stays empty. Three 86 by 60
  /// plates 8 apart, 10 in from the safe edge, the foot 8 over the safe bottom.
  @Test func uprightTheColumnIsBesideTheClockAwayFromTheThumb() {
    for p in Self.upright {
      for kind in MeterKind.allCases {
        for side in MeterSide.allCases {
          let m = meter(kind, side, p.size, p.safe)
          let what = "\(p.name) \(kind) \(side)"
          let c = Tray.upright(size: p.size, safe: p.safe, meter: m, side: side)
          #expect(c.size == CGSize(width: 86, height: 196), "\(what)")
          #expect(c.maxY == p.size.height - p.safe.bottom - 8, "\(what)")
          let atLeft = m.linear.map { $0.side == .right } ?? (side == .right)
          #expect(atLeft ? c.minX == 10 : c.maxX == p.size.width - 10, "\(what): \(c)")
          let plates = Tray.uprightPlates(size: p.size, safe: p.safe, meter: m, side: side)
          #expect(plates.count == 3)
          let arc = plates[.arc]!, tilt = plates[.tilt]!, stand = plates[.stand]!
          #expect(arc.maxY + 8 == tilt.minY && tilt.maxY + 8 == stand.minY && stand.maxY == c.maxY, "\(what)")
          #expect([arc, tilt, stand].allSatisfy { $0.size == Tray.phonePlate })
          // clear of the meter: the clock's face and rim, the linear meter and its tabs
          switch m {
          case .clock(let k):
            let face = CGRect(
              x: k.center.x - k.radius * 1.12, y: k.center.y - k.radius * 1.12, width: k.radius * 2.24,
              height: k.radius * 2.24)
            #expect(!c.intersects(face), "\(what): tray \(c) meets the clock \(face)")
            // the thumb's side of the clock is empty
            #expect(atLeft ? c.maxX < k.center.x - k.radius : c.minX > k.center.x + k.radius, "\(what)")
          case .linear(let l):
            #expect(!c.intersects(l.cover) && !c.intersects(l.tab), "\(what): \(c) meets \(l.cover) or \(l.tab)")
          }
        }
      }
    }
  }

  /// An open plate grows upward in its place (the column's foot staying put), TILT
  /// and STAND also in toward the middle where the meter leaves room; the other two
  /// stay closed over or under it; under the header and the minimap.
  @Test func uprightAnOpenPlateGrowsUpwardInTheColumn() {
    for p in Self.upright {
      for kind in MeterKind.allCases {
        for side in MeterSide.allCases {
          let m = meter(kind, side, p.size, p.safe)
          let tray = Tray.uprightFrames(size: p.size, safe: p.safe, meter: m, side: side)
          let closed = tray.plates(open: nil)
          for open in TrayPlate.allCases {
            let f = tray.plates(open: open)
            let what = "\(p.name) \(kind) \(side) \(open)"
            #expect(f[open]!.height == Tray.openHeight(open, wide: false), "\(what)")
            #expect(f.count == 3, "\(what): room for all three")
            #expect(f[.stand]!.maxY == closed[.stand]!.maxY, "the foot stays")
            for other in TrayPlate.allCases where other != open { #expect(f[other]!.size == Tray.phonePlate) }
            #expect(f.values.allSatisfy { $0.minY >= tray.ceiling }, "\(what)")
            // never over the meter: the clock's face and shadow, the linear meter and its tabs
            switch m {
            case .clock(let k):
              let face = CGRect(
                x: k.center.x - k.radius * 1.12, y: k.center.y - k.radius * 1.12, width: k.radius * 2.24,
                height: k.radius * 2.24)
              #expect(f.values.allSatisfy { !$0.intersects(face) }, "\(what)")
            case .linear(let l):
              #expect(f.values.allSatisfy { !$0.intersects(l.cover) && !$0.intersects(l.tab) }, "\(what)")
            }
            let map = WideLayout.uprightMinimap(size: p.size, safe: p.safe)
            #expect(f.values.allSatisfy { !$0.intersects(map) }, "\(what)")
          }
        }
      }
    }
  }

  /// On a phone on its side an open plate grows up from its place with the other two
  /// showing, as far as the room under the header row leaves (the web's rule: ARC to
  /// 300 where there is the room, never under 100 with the others showing, else it
  /// covers them); TILT and STAND also open in toward the middle.
  @Test func wideAnOpenPlateGrowsInPlaceOrCoversTheColumn() {
    for p in WideLayoutTests.phones {
      for side in MeterSide.allCases {
        let m = meter(.clock, side, p.size, p.safe)
        let plan = WideLayout.plan(meter: m, size: p.size, safe: p.safe, side: side)
        let stack = plan.tray.plates(open: nil)
        #expect(stack.values.allSatisfy { $0.size == Tray.widePlate && plan.block.contains($0) })
        let arc = plan.tray.plates(open: .arc)
        #expect(arc.count == 3 && arc[.stand]!.maxY == plan.block.maxY && arc[.arc]!.minY == plan.tray.ceiling)
        #expect(arc[.arc]!.height >= Tray.openMin, "\(p.name) \(side)")
        for open in [TrayPlate.tilt, .stand] {
          let f = plan.tray.plates(open: open)
          #expect(f.count == 3 && f[open]!.width > Tray.widePlate.width, "\(p.name) \(side) \(open)")
          #expect(side == .right ? f[open]!.minX == plan.block.minX : f[open]!.maxX == plan.block.maxX)
        }
      }
    }
  }

  // MARK: An open plate, one at a time

  private func aiming() throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    return app
  }

  /// A tap on ARC opens it and the side view with it; a tap on TILT opens TILT and
  /// closes ARC (one at a time) and the side view; a tap on the open plate, or outside
  /// (`nil`), closes it; a press on the meter closes it too, and a throw.
  @Test func onePlateOpensAtATime() throws {
    let app = try aiming()
    #expect(app.openPlate == nil && !app.plan)
    try app.tapPlate(.arc)
    #expect(app.openPlate == .arc && app.plan && app.showsSide)
    try app.tapPlate(.tilt)
    #expect(app.openPlate == .tilt && !app.plan)
    try app.tapPlate(.stand)
    #expect(app.openPlate == .stand && !app.plan)
    try app.tapPlate(.stand)
    #expect(app.openPlate == nil)
    try app.tapPlate(.arc)
    try app.tapPlate(nil)
    #expect(app.openPlate == nil && !app.plan)
    try app.tapPlate(.arc)
    app.beginDial()
    #expect(app.openPlate == nil && !app.plan)
    // SIDE VIEW's old toggle keeps the plate in step (the review's side view)
    try app.togglePlan()
    #expect(app.openPlate == .arc)
    try app.togglePlan()
    #expect(app.openPlate == nil)
  }

  /// Nothing opens while the player cannot aim (the hand-off up).
  @Test func noPlateOpensUnderTheHandOff() throws {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "You", selections: app.options.defaults, save: nil)
    #expect(app.handoff != nil)
    try app.tapPlate(.arc)
    #expect(app.openPlate == nil && !app.plan)
  }

  // MARK: The minimap

  /// Upright the minimap hangs under the header's right end: 12 in from the safe edge,
  /// at least 75 under the safe top and 10 under the header as measured; the same
  /// whatever is held or where the circle is.
  @Test func uprightTheMinimapIsUnderTheHeadersRightEnd() {
    for p in Self.upright {
      let map = WideLayout.uprightMinimap(size: p.size, safe: p.safe)
      let w = min(78, p.size.width * 0.19)
      #expect(map == CGRect(x: p.size.width - 12 - w, y: p.safe.top + 75, width: w, height: w * 1.95))
      // a taller header (a larger text size) pushes it down, never sideways
      let tall = WideLayout.uprightMinimap(size: p.size, safe: p.safe, headerBottom: p.safe.top + 140)
      #expect(tall.minX == map.minX && tall.minY == p.safe.top + 148)
      // clear of the tray and the meter
      for kind in MeterKind.allCases {
        for side in MeterSide.allCases {
          let m = meter(kind, side, p.size, p.safe)
          let open = Tray.uprightFrames(size: p.size, safe: p.safe, meter: m, side: side).reach
          #expect(!open.intersects(map), "\(p.name) \(kind) \(side)")
          if let l = m.linear { #expect(l.cover.minY >= map.maxY + 10 - 0.001) }
        }
      }
    }
  }

  /// The minimap tells the teams apart by shape as well as colour: Team A circles, Team
  /// B squares, the king a square with a crown; and reads as one image with the web's
  /// summary.
  @Test func theMinimapsTeamsAreShapes() throws {
    func piece(_ team: String?, _ kind: String = "kubb") throws -> Piece {
      let t = team.map { #""team":"\#($0)","# } ?? ""
      return try JSONDecoder().decode(
        Piece.self,
        from: Data(#"{"id":"x","kind":"\#(kind)",\#(t)"x":0,"y":0,"z":0.15,"qw":1,"qx":0,"qy":0,"qz":0}"#.utf8))
    }
    #expect(PitchScene.mapShape(try piece("A")) == .circle)
    #expect(PitchScene.mapShape(try piece("B")) == .square)
    #expect(PitchScene.mapShape(try piece(nil, "king")) == .crown)
    #expect(
      MeterWords.mapSummary(standing: ["A": 5, "B": 4], teams: ["A": "Mighty Maple", "B": "Computer"], metres: 7.8)
        == "Map of the pitch: Mighty Maple 5 kubbs standing, Computer 4. The target is 8 metres out.")
    #expect(MeterWords.mapSummary(standing: ["A": 1, "B": 0], teams: nil, metres: nil)
      == "Map of the pitch: Team A 1 kubb standing, Team B 0.")
    #expect(MeterWords.mapSummary(standing: nil, teams: nil, metres: nil) == "Map of the pitch.")
  }

  /// The meter's own words, the web's stand-ins.
  @Test func theMeterIsReadByItsMarks() {
    #expect(MeterWords.spokenMeter(linear: false, watching: false)
      == "Clock meter. Draw back to the stripes, then flick and let go on the solid mark.")
    #expect(MeterWords.spokenMeter(linear: true, watching: true) == "Linear meter, shown for watching only.")
    #expect(PlanScale.sideAmountText(7.4, kubb: false) == "7 degrees right")
    #expect(PlanScale.sideAmountText(0, kubb: false) == "none")
    #expect(PlanScale.sideAmountText(-1.25, kubb: true) == "1.25 left")
  }

  // MARK: The distance tab

  @Test func theDistanceTabIsTheThrowsDistanceToTheMetre() throws {
    #expect(MeterWords.distance(7.6) == "8 M")
    #expect(MeterWords.distance(8.49) == "8 M")
    #expect(MeterWords.distance(4.5) == "5 M")
    #expect(MeterWords.distance(0.3) == "1 M")
    #expect(MeterWords.distance(nil) == nil && MeterWords.distance(0) == nil && MeterWords.distance(.nan) == nil)
    for p in ["WIND BACK", "DRAW BACK", "FLICK!", "FLING!"] { #expect(MeterWords.showsDistance(p)) }
    #expect(!MeterWords.showsDistance("CRANK DOWN") && !MeterWords.showsDistance(nil))
    #expect(MeterWords.spokenPrompt("WIND BACK", metres: 7.6) == "Wind back, 8 metres")
    #expect(MeterWords.spokenPrompt("WIND BACK", metres: 1.2) == "Wind back, 1 metre")
    #expect(MeterWords.spokenPrompt("FLICK!", metres: 7.6) == "Flick, 8 metres")
    #expect(MeterWords.spokenPrompt("CRANK DOWN", metres: 7.6) == "Crank down")
    // the session's distance is the engine's plan, and follows the circle
    let app = try aiming()
    let d0 = try #require(app.distance)
    #expect(d0 > 3 && d0 < 12)
    let size = CGSize(width: 390, height: 844)
    let m = try #require(app.marker(in: size))
    try app.target(CGPoint(x: m.x, y: m.y + 120), size: size, snap: false)
    #expect(try #require(app.distance) < d0)
  }

  /// The linear meter's tab room holds the prompt and the distance tab beside it, and
  /// the nudge's fingertip keeps clear of both.
  @Test func theLinearTabHasRoomForTheDistance() throws {
    let m = try #require(LinearMeter.layout(size: CGSize(width: 390, height: 844), safeTop: 47, safeBottom: 34, side: .right))
    #expect(m.tab.width == m.promptHeight * 6)
    let p = m.nudgePath(
      swing: NudgeSwing(back: 120, release: 90), size: CGSize(width: 390, height: 844), safeLeft: 0, safeRight: 0)
    #expect(p.x + LinearMeter.nudgeFinger < m.tab.minX)
    // and clear of the tray at the left edge
    let tray = Tray.upright(size: CGSize(width: 390, height: 844), safe: ScreenInsets(top: 47, bottom: 34), meter: .linear(m), side: .right)
    #expect(p.x - LinearMeter.nudgeFinger > tray.maxX)
  }

  // MARK: The verdict

  private func result(_ json: String) throws -> ThrowResult {
    try JSONDecoder().decode(ThrowResult.self, from: Data(json.utf8))
  }

  /// The off words come first, each with its arrow; the on-target words after.
  @Test func theVerdictLeadsWithTheOffWordsAndTheirArrows() throws {
    let r = try result(
      #"{"flag":"MISS","restText":"","verdicts":{"power":"SHORT","release":"ON","steady":"SHAKY","side":"PULLED LEFT"}}"#)
    #expect(r.words.map(\.text) == ["SHORT", "SHAKY", "PULLED LEFT", "ARC ON"])
    #expect(r.words.map(\.offTarget) == [true, true, true, false])
    #expect(VerdictWords.spoken(flag: r.flag, words: r.words) == "Short. Shaky. Pulled left. Miss. Arc on.")
    let one = try result(#"{"flag":"MISS","verdicts":{"power":"SHORT","release":"ON","steady":"STEADY","side":"STRAIGHT"}}"#)
    #expect(VerdictWords.spoken(flag: one.flag, words: one.words) == "Short. Miss. Arc on, steady, straight.")
    let arrows: [String: VerdictWords.Arrow] = [
      "SHORT": .down, "LOW": .down, "LONG": .up, "HIGH": .up, "PULLED LEFT": .left, "PULLED RIGHT": .right,
      "SHAKY": .wavy, "SLOW": .clock,
    ]
    for (w, a) in arrows { #expect(VerdictWords.arrow(w) == a, "\(w)") }
    for w in ["POWER ON", "ARC ON", "STEADY", "STRAIGHT"] { #expect(VerdictWords.arrow(w) == nil) }
    let good = try result(#"{"flag":"TOK!","verdicts":{"power":"ON","release":"ON","steady":"STEADY","side":"STRAIGHT"}}"#)
    #expect(good.words.allSatisfy { !$0.offTarget })
    #expect(VerdictWords.spoken(flag: good.flag, words: good.words) == "Tok. Power on, arc on, steady, straight.")
  }

  // MARK: The hand-off

  /// The card's one line (the owner's table, 2026-11-22): counts in words up to ten,
  /// singular and plural right.
  @Test func eachHandOffLine() {
    #expect(HandoffWords.line(batons: 6, kubbs: 0, at: "FIELD 2") == "Six batons. Two field kubbs to clear first.")
    #expect(HandoffWords.line(batons: 6, kubbs: 0, at: "FIELD 1") == "Six batons. One field kubb to clear first.")
    #expect(HandoffWords.line(batons: 6, kubbs: 0, at: "BASE 5") == "Six batons. Aim for the base kubbs.")
    #expect(HandoffWords.line(batons: 6, kubbs: 0, at: nil) == "Six batons. Aim for the base kubbs.")
    #expect(HandoffWords.line(batons: 6, kubbs: 0, at: "KING") == "Six batons. Go for the king.")
    #expect(HandoffWords.line(batons: 1, kubbs: 0, at: "FIELD 10") == "One baton. Ten field kubbs to clear first.")
    #expect(HandoffWords.line(batons: 6, kubbs: 0, at: "FIELD 11") == "Six batons. 11 field kubbs to clear first.")
    #expect(HandoffWords.line(batons: 6, kubbs: 3, at: nil) == "Throw three kubbs into the other half.")
    #expect(HandoffWords.line(batons: 6, kubbs: 1, at: nil) == "Throw one kubb into the other half.")
    #expect(HandoffWords.line(batons: 6, kubbs: 0, at: "FIELD 2", raise: true) == "Stand your kubbs up.")
  }

  /// The solo match's first hand-off is the player's own ("Your turn"), its line from
  /// the engine's rail; the computer's turn shows no card at all.
  @Test func theComputersTurnShowsNoCard() throws {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "You", selections: app.options.defaults, save: nil)
    let c = try #require(app.handoff)
    #expect(HandoffWords.title(c, own: true) == "Your turn")
    #expect(HandoffWords.title(c, own: false) == "\(c.toName)’s turn")
    #expect(HandoffWords.title(name: "Golden Kubblets", own: false) == "Golden Kubblets’ turn")
    #expect(HandoffWords.title(name: " ", own: false) == "Their turn")
    let batons = CountWords.sentence(CountWords.count(c.batons, "baton", "batons")) + "."
    #expect(HandoffWords.line(c, at: app.railAt).hasPrefix(c.kubbs > 0 ? "Throw " : batons))
    // a match where the computer is throwing
    let cpu = try PitchSession(appVersion: "test")
    try cpu.restore(fixture("computer"), save: nil)
    #expect(cpu.need?.cpu == true && cpu.need?.kind == "throw")
    #expect(cpu.handoff == nil && !cpu.canAim)
    for _ in 0..<40 { try cpu.tick(1.0 / 60) }
    #expect(cpu.handoff == nil)
  }

  // MARK: The header and the coach

  @Test func theHeaderSaysWhatTheThrowerAimsAt() {
    #expect(HeaderWords.line(turn: 4, n: 2, of: 6, projectile: "baton", watching: false, at: "FIELD 2")
      == "Turn 4 · baton 2 of 6 · 2 field kubbs")
    #expect(HeaderWords.line(turn: 4, n: 2, of: 6, projectile: "baton", watching: false, at: "FIELD 1")
      == "Turn 4 · baton 2 of 6 · 1 field kubb")
    #expect(HeaderWords.line(turn: 9, n: 5, of: 6, projectile: "baton", watching: false, at: "KING")
      == "Turn 9 · baton 5 of 6 · at the king")
    // the base kubbs are what the numbers show: nothing added
    #expect(HeaderWords.line(turn: 4, n: 2, of: 6, projectile: "baton", watching: false, at: "BASE 5")
      == "Turn 4 · baton 2 of 6")
    #expect(HeaderWords.aimsAt("2.3 M") == nil && HeaderWords.aimsAt(nil) == nil)
  }

  /// The coach names the meter's marks by shape (the owner's decision): the stripes and
  /// the solid mark; the other lines keep their words.
  @Test func theCoachNamesTheMarksByShape() {
    #expect(Coach.lines[.rest] == "PULL BACK TO THE STRIPES")
    #expect(Coach.lines[.band] == "NOW FLICK FAST AND STOP ON THE SOLID MARK")
    #expect(Coach.lines[.winding] == "NO RUSH GOING BACK")
    #expect(Coach.slowLine == "SLOW FLICK. FLICK FASTER.")
    for line in Coach.lines.values {
      #expect(!line.contains("ORANGE") && !line.contains("BLUE"))
    }
  }
}
