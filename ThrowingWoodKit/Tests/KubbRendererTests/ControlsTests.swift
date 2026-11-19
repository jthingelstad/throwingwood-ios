import CoreGraphics
import Foundation
import KubbEngine
import KubbRooms
import Testing
import simd

@testable import KubbRenderer

/// The plan sliders, the aim drag and automatic raising.
@MainActor struct ControlsTests {
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }
  private func aiming() throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    return app
  }

  // MARK: The sliders' arithmetic

  @Test func arcScaleRunsTheEnginesReleaseRange() {
    #expect(PlanScale.release(at: 0) == 15)
    #expect(PlanScale.release(at: 1) == 165)
    #expect(PlanScale.release(at: 0.5) == 90)
    #expect(PlanScale.release(at: -3) == 15 && PlanScale.release(at: 7) == 165)
    #expect(PlanScale.release(at: .nan) == 15)
    for deg in stride(from: 15.0, through: 165, by: 7.5) {
      #expect(abs(PlanScale.release(at: PlanScale.arcFraction(deg)) - deg) < 1e-9)
    }
    #expect(PlanScale.arcFraction(nil) == 0.5)
    let marks = PlanScale.arcMarks
    #expect(marks.count == 5 && marks.filter(\.long).map(\.f) == [0.5])
    #expect(PlanScale.arcLabel(loft: 46) == "ARC 46°")
  }

  @Test func sideScaleSettlesOnTheEnginesSteps() {
    #expect(PlanScale.sideSteps(kubb: false) == 4 && PlanScale.sideSteps(kubb: true) == 3)
    #expect(PlanScale.sideStep(at: 0, kubb: false) == -4)
    #expect(PlanScale.sideStep(at: 1, kubb: false) == 4)
    #expect(PlanScale.sideStep(at: 0.5, kubb: true) == 0)
    // the knob settles on the nearest detent
    #expect(PlanScale.sideStep(at: 0.5 + 0.06, kubb: false) == 0)
    #expect(PlanScale.sideStep(at: 0.5 + 0.07, kubb: false) == 1)
    #expect(PlanScale.sideStep(at: 0.83, kubb: true) == 2)
    for kubb in [false, true] {
      let n = PlanScale.sideSteps(kubb: kubb)
      for step in -n...n {
        #expect(PlanScale.sideStep(at: PlanScale.sideFraction(step, kubb: kubb), kubb: kubb) == step)
      }
      let marks = PlanScale.sideMarks(kubb: kubb)
      #expect(marks.count == 2 * n + 1 && marks.filter(\.long).map(\.f) == [0.5])
    }
    #expect(PlanScale.steps(of: 10, kubb: false) == 2 && PlanScale.steps(of: -2, kubb: true) == -2)
    #expect(PlanScale.sideLabel(10, kubb: false) == "TILT 10R")
    #expect(PlanScale.sideLabel(-2, kubb: true) == "SPIN 2L")
    #expect(PlanScale.sideLabel(0, kubb: false) == "TILT 0")
    #expect(PlanScale.sideValueText(-15, kubb: false) == "Tilt 15 degrees left")
    #expect(PlanScale.sideValueText(0, kubb: true) == "Spin none")
  }

  @Test func arcSliderIsContinuousSentOnceAFrameAndPeeksTheSideView() throws {
    let app = try aiming()
    let before = try #require(app.release)
    app.slide(.arc, to: 0.8, phase: .down)
    app.slide(.arc, to: 0.9, phase: .move)
    app.slide(.arc, to: 0.7, phase: .move)
    // nothing is sent until the frame
    #expect(app.release == before)
    #expect(app.showsSide && !app.plan && app.wantsFrames)
    try app.tick(1.0 / 60)
    #expect(abs(try #require(app.release) - PlanScale.release(at: 0.7)) < 1e-9)
    // a place between the clock's half hours: the engine takes it as it is
    app.slide(.arc, to: 0.31, phase: .move)
    try app.tick(1.0 / 60)
    #expect(abs(try #require(app.release) - PlanScale.release(at: 0.31)) < 1e-9)
    let loftLow = try #require(app.arcDegrees)
    app.slide(.arc, to: 1, phase: .up)
    try app.tick(1.0 / 60)
    let loftHigh = try #require(app.arcDegrees)
    #expect(app.release == 165 && loftHigh > loftLow)
    #expect(app.showsSide && app.held == nil)
    for _ in 0..<40 { try app.tick(1.0 / 60) }
    #expect(!app.showsSide)
    for _ in 0..<90 { try app.tick(1.0 / 60) }
    #expect(app.mix == 0 && !app.wantsFrames)
  }

  @Test func tiltSliderMovesByTheStepDifference() throws {
    let app = try aiming()
    #expect(!app.throwsKubb && app.sideSteps == 0)
    app.slide(.side, to: 1, phase: .down)
    #expect(app.heldFraction == 1)
    try app.tick(1.0 / 60)
    #expect(app.sideStep == 20 && app.sideSteps == 4)
    app.slide(.side, to: 0.36, phase: .move)
    try app.tick(1.0 / 60)
    #expect(app.sideStep == -5)
    app.slide(.side, to: 0.62, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.sideStep == 5 && app.heldFraction == nil)
    try app.stepPlan(.side, by: 1)
    #expect(app.sideStep == 10)
  }

  @Test func aHeldSliderThatIsCancelledLetsTheSideViewGo() throws {
    let app = try aiming()
    app.slide(.arc, to: 0.6, phase: .down)
    try app.tick(1.0 / 60)
    let kept = try #require(app.release)
    #expect(app.held == .arc && app.showsSide && app.wantsFrames)
    // the menu opened under the finger, or the app left the foreground: no release comes
    app.slide(.arc, to: 0, phase: .cancel)
    #expect(app.held == nil && app.heldFraction == nil)
    #expect(!app.showsSide && !app.wantsFrames)
    try app.tick(1.0 / 60)
    // the plan stays where the last frame left it
    #expect(app.release == kept)
    app.cancelSlide()
    #expect(!app.showsSide)
  }

  @Test func slidersAreIgnoredWhenTheThrowIsNotOurs() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    // the handoff card is up
    app.slide(.arc, to: 1, phase: .down)
    #expect(app.held == nil && !app.showsSide)
  }

  // MARK: Aiming

  @Test func aimDragMovesTheCircleByTheFingersTravelNotUnderIt() throws {
    for size in [CGSize(width: 390, height: 844), CGSize(width: 440, height: 956)] {
      let app = try aiming()
      let start = try #require(app.scene.marker)
      // 20 one-point moves to the right, as touchesMoved delivers them
      for _ in 0..<20 { try app.nudgeAim(by: CGVector(dx: 1, dy: 0)) }
      var m = try #require(app.scene.marker)
      #expect(abs((m.x - start.x) - 0.2) < 1e-6, "\(size)")
      #expect(abs(m.y - start.y) < 1e-6)
      // up the screen is further down the pitch, at the same scale
      for _ in 0..<10 { try app.nudgeAim(by: CGVector(dx: 0, dy: -1)) }
      m = try #require(app.scene.marker)
      #expect(abs((m.y - start.y) - 0.1) < 1e-6)
      // back again: the move is reversible, whatever the camera did meanwhile
      try app.nudgeAim(by: CGVector(dx: -20, dy: 10))
      m = try #require(app.scene.marker)
      #expect(abs(m.x - start.x) < 1e-6 && abs(m.y - start.y) < 1e-6)
    }
  }

  @Test func aimDragFollowsTheSideViewsAxes() throws {
    let app = try aiming()
    try app.togglePlan()
    for _ in 0..<90 { try app.tick(1.0 / 60) }
    let size = CGSize(width: 390, height: 844)
    let before = try #require(app.marker(in: size))
    try app.nudgeAim(by: CGVector(dx: 10, dy: 0))
    let after = try #require(app.marker(in: size))
    // a finger moved right moves the circle right on the screen too
    #expect(after.x > before.x)
  }

  @Test func tapOnAStandingKubbAimsAtIt() throws {
    let app = try aiming()
    let size = CGSize(width: 390, height: 844)
    let p = app.scene.projection(size, app.camera)
    let kubb = try #require(
      app.scene.items.first { k in
        guard k.kind == "kubb", k.y > 4, abs(k.x) > 0.5, let s = p.project(k.center) else { return false }
        return s.x > 30 && s.x < size.width - 30
      })
    // on the kubb's drawn top: the ground under it lies too far behind for the engine's snap
    let body = try #require(p.project(V3(kubb.x, kubb.y, kubb.z * 2)))
    let behind = try #require(p.ground(body))
    #expect(behind.y - kubb.y > 0.25)
    try app.tapAim(at: CGPoint(x: body.x + 6, y: body.y), size: size)
    let m = try #require(app.scene.marker)
    #expect(abs(m.x - kubb.x) < 1e-6 && abs(m.y - kubb.y) < 1e-6)
    // open grass far from any kubb: the circle goes under the tap
    let grass = try #require(p.project(V3(kubb.x > 0 ? -0.5 : 0.5, 6, 0)))
    try app.tapAim(at: grass, size: size)
    let g = try #require(app.scene.marker)
    #expect(abs(g.y - 6) < 0.05)
  }

  // MARK: Automatic raising

  @Test func autoRaiseWaitsItsGapForEachKubb() {
    var a = AutoRaise()
    func tick(_ dt: Double, _ key: String?) -> Bool { a.tick(dt, raising: key) }
    #expect(!a.seen)
    #expect(!tick(1, "1:k:1"))
    #expect(a.seen)  // the menu shows Raising from now on
    a.setGame(true)
    #expect(!tick(0.05, "1:k:1"))
    #expect(a.waiting)
    #expect(!tick(0.6, "1:k:1"))
    #expect(tick(0.1, "1:k:1"))
    #expect(!tick(1, "1:k:1"))  // once for each kubb
    // a card over it: the wait starts again
    #expect(!tick(0.05, nil))
    #expect(!a.waiting)
    #expect(!tick(0.05, "1:k:1"))
    // the engine would not raise it: back to the player, as the web's refused()
    a.refused()
    #expect(!a.on && !a.game)
    #expect(!tick(10, "1:k:2"))
    #expect(!a.waiting)
    var rest = AutoRaise()
    rest.restOfTurn()
    #expect(rest.on && !rest.game)
    rest.turnEnded()
    #expect(!rest.on)
    // BY HAND ends AUTO ALL too; REST OF GAME keeps going past the turn
    rest.restOfTurn()
    rest.setGame(false)
    #expect(!rest.on)
    rest.restOfTurn()
    rest.setGame(true)
    rest.turnEnded()
    #expect(rest.on && rest.game)
  }

  @Test func automaticRaisingIsForThisMatchOnly() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    #expect(!app.raiseSeen)
    try app.tick(0.05)
    #expect(app.raiseSeen && !app.raiseAutomatically)
    app.raiseAutomatically = true
    // the next match (or the same one opened again) raises by hand
    try app.restore(fixture("raise-many"), save: nil)
    #expect(!app.raiseAutomatically && !app.raiseSeen)
  }

  @Test func automaticRaisingStandsEveryKubbByTheEnginesChoice() throws {
    for mode in ["setting", "autoAll"] {
      let app = try PitchSession(appVersion: "test")
      let reference = try Engine(appVersion: "test")
      let start = try fixture("raise-many")
      try app.restore(start, save: nil)
      _ = try reference.call("restore", json: start)
      let first = try #require(app.need)
      try #require(first.kind == "raise" && (first.of ?? 0) >= 2 && first.n == 1)
      if mode == "setting" { app.raiseAutomatically = true } else { app.raiseRest() }
      #expect(app.raisingRest == (mode == "autoAll"))
      var raised = 0, clock = 0.0, lastAt = 0.0
      for _ in 0..<400 where app.need?.kind == "raise" {
        let n = app.need?.n
        try app.tick(0.05)
        clock += 0.05
        if app.need?.n != n || app.need?.kind != "raise" {
          raised += 1
          #expect(clock - lastAt >= AutoRaise.gap - 1e-9)
          lastAt = clock
          _ = try reference.call("apply", json: #"{"type":"raise"}"#)
          #expect(try app.engine.hash() == reference.hash())
        }
      }
      #expect(raised == first.of)
      try app.tick(0.05)
      #expect(!app.raisingRest)
    }
  }

  @Test func noAutomaticRaiseUnderACardOrForTheOtherSide() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    app.raiseAutomatically = true
    let hash = try app.engine.hash()
    app.acceptsInput = false  // online: the other side's raise
    for _ in 0..<40 { try app.tick(0.05) }
    #expect(try app.engine.hash() == hash)
    app.acceptsInput = true
    app.raiseByHand()
    for _ in 0..<40 { try app.tick(0.05) }
    #expect(try app.engine.hash() == hash && !app.raiseAutomatically)
  }

  // MARK: Raising by touch (RaiseTouch)

  @Test func raiseTouchGeometryMatchesTheWeb() throws {
    // the web's tests/game/raise-touch.test.mjs pose: end 1 allowed, end 2 refused
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise"), save: nil)
    let need = try #require(app.need)
    let size = CGSize(width: 390, height: 844)
    let g = try #require(app.raiseGeometry(in: size))
    let a = g.caps[0], b = g.caps[1]
    let mid = CGPoint.between(a, b, 0.5)
    #expect(RaiseTouch.on(g, mid))
    let top = g.outline.map(\.y).min()!
    #expect(RaiseTouch.on(g, CGPoint(x: mid.x, y: top - 20)))
    #expect(!RaiseTouch.on(g, CGPoint(x: mid.x, y: top - RaiseTouch.margin - 4)))
    #expect(RaiseTouch.nearerEnd(g, .between(a, b, 0.2)) == 0)
    #expect(RaiseTouch.nearerEnd(g, .between(a, b, 0.8)) == 1)
    let L = a.distance(to: b)
    let travel = max(RaiseTouch.travelMin, L * RaiseTouch.travelK)
    let u = CGPoint(x: (a.x - b.x) / L, y: (a.y - b.y) / L)
    let half = RaiseTouch.drag(g, from: .zero, to: CGPoint(x: u.x * travel / 2, y: u.y * travel / 2))
    #expect(half.i == 0 && abs(half.t - 0.5) < 1e-9)
    #expect(RaiseTouch.drag(g, from: .zero, to: CGPoint(x: -u.x * travel * 3, y: -u.y * travel * 3)).t == 1)
    #expect(RaiseTouch.drag(g, from: .zero, to: CGPoint(x: -u.x, y: -u.y)).i == 1)
    // tipped all the way: on end i's footprint, upright, its middle at half its length
    let lying = try #require(need.pose).piece(id: try #require(need.kubb))
    for i in 0..<2 {
      let f = try #require(need.ends?[i].pose)
      let up = RaiseTouch.tilt(need, lying: lying, i: i, t: 1)
      #expect(hypot(up.x - f.x, up.y - f.y) < 1e-9)
      #expect(abs(up.z - 0.075) < 1e-9)
      #expect(abs(abs(up.rotation.act(V3(0, 0, 1)).z) - 1) < 1e-9)
      #expect(RaiseTouch.tilt(need, lying: lying, i: i, t: 0.5).z > lying.z)
    }
    #expect(RaiseTouch.tilt(need, lying: lying, i: 0, t: 0).center == lying.center)
  }

  /// The computer's throws of a seeded match (both sides, raising automatically), then
  /// a pass and play match that raises by hand played with those throws up to its nth
  /// raise: the engine's own raise, in the raising team's frame, as the web's test does.
  private func realRaises(count: Int = 60) throws -> [String] {
    let cpu = try Engine(appVersion: "test")
    _ = try cpu.call("new", json: realRaiseOptions(cpu: #""both""#, raising: "auto"))
    var acts: [String] = []
    for _ in 0..<200_000 where acts.count < count {
      let out = try JSONNode.parse(cpu.call("frame", json: #"{"dt":0.05}"#))
      if let a = out["action"], !a.isNull { acts.append(a.raw.text) }
      if out["need"]?["kind"]?.string == "over" { break }
    }
    return acts
  }
  private func realRaiseOptions(cpu: String, raising: String) -> String {
    #"{"mode":"match","seed":5,"cpu":\#(cpu),"raising":"\#(raising)","first":"A","start":{"year":2026,"month":11,"day":19,"hour":9,"min":0},"teams":{"A":{"name":"North","players":[{"name":"North"}]},"B":{"name":"South","players":[{"name":"South"}]}}}"#
  }
  /// The nth raise of the hand-raising match, opened on a session that raises both sides.
  private func atRealRaise(_ acts: [String], _ nth: Int) throws -> PitchSession? {
    let prep = try Engine(appVersion: "test")
    _ = try prep.call("new", json: realRaiseOptions(cpu: "[]", raising: "hand"))
    var k = 0, seen = 0
    for _ in 0..<600 {
      let need = try JSONNode.parse(prep.call("view"))["need"]
      switch need?["kind"]?.string {
      case "throw":
        guard k < acts.count else { return nil }
        _ = try prep.call("apply", json: acts[k])
        k += 1
      case "raise":
        if seen == nth {
          let app = try PitchSession(appVersion: "test")
          try app.restore(prep.call("snapshot"), save: nil)
          _ = try app.engine.call("setControl", json: #"{"sides":["A","B"],"cpu":false}"#)
          try app.adopt(app.read("view"))
          return app
        }
        seen += 1
        _ = try prep.call("apply", json: #"{"type":"raise"}"#)
      case "punish":
        let c = try #require(need?["cursor"])
        _ = try prep.call(
          "apply", json: #"{"type":"punish","x":\#(c["x"]!.double!),"y":\#(c["y"]!.double!)}"#)
      default: return nil
      }
    }
    return nil
  }
  /// Where the kubb stands after the raise: on end i's footprint (the next view may be in
  /// the other team's frame: the mirror x, 8 - y).
  private func standsOn(_ app: PitchSession, _ need: MatchNeed, _ i: Int) throws -> Bool {
    let items = try JSONNode.parse(app.engine.call("view"))["items"]?.items ?? []
    let id = try #require(need.kubb)
    guard let piece = items.first(where: { $0["id"]?.string == id }),
      piece["toppled"]?.bool != true, let x = piece["x"]?.double, let y = piece["y"]?.double,
      let f = need.ends?[i].pose
    else { return false }
    return min(hypot(x - f.x, y - f.y), hypot(x + f.x, y - (8 - f.y))) < 0.005
  }

  @Test func raisingByTouchOnTheEnginesOwnRaises() throws {
    let acts = try realRaises()
    let size = CGSize(width: 390, height: 844)
    func nearestFoot(_ app: PitchSession, _ p: CGPoint) -> Int {
      let feet = app.raiseEnds(in: size)
      return feet[0].footprint.distance(to: p) < feet[1].footprint.distance(to: p) ? 0 : 1
    }
    var picked: [String: Set<Int>] = [:]
    var refusedSeen = false, dragged = false
    for nth in 0..<16 {
      guard let probe = try atRealRaise(acts, nth), let need = probe.need,
        let side = need.side
      else { break }
      let oks = need.ends?.map { $0.ok != false } ?? []
      if oks == [true, true] {
        // a tap on each half: the end drawn nearer the finger, standing on its footprint
        for t in [0.25, 0.75] {
          let app = try #require(try atRealRaise(acts, nth))
          let g = try #require(app.raiseGeometry(in: size))
          let at = CGPoint.between(g.caps[0], g.caps[1], t)
          let want = nearestFoot(app, at)
          let i = try #require(app.raisePick(at: at, size: size))
          #expect(i == want, "\(side) raise \(nth), tap at \(t)")
          #expect(try app.raiseTap(i))
          #expect(try standsOn(app, need, want), "\(side) raise \(nth) stands on end \(want + 1)")
          picked[side, default: []].insert(want)
        }
        if !dragged {
          // a drag toward the end drawn farther from where it starts
          dragged = true
          let app = try #require(try atRealRaise(acts, nth))
          let g = try #require(app.raiseGeometry(in: size))
          let a = g.caps[0], b = g.caps[1]
          let from = CGPoint.between(a, b, 0.2)
          let want = nearestFoot(app, b)
          let L = a.distance(to: b)
          let go = max(90, L * 1.1)
          let hash = try app.engine.hash()
          // short of half way: nothing is sent, the kubb lies back down
          try app.raiseDrag(g, from: from, to: CGPoint(x: from.x + (b.x - a.x) / L * go * 0.4, y: from.y + (b.y - a.y) / L * go * 0.4))
          #expect(app.raiseDragging?.i == want)
          try app.raiseLetGo()
          #expect(try app.engine.hash() == hash && app.raiseDragging == nil)
          for k in 0...6 {
            let f = go * 0.8 * Double(k) / 6
            try app.raiseDrag(g, from: from, to: CGPoint(x: from.x + (b.x - a.x) / L * f, y: from.y + (b.y - a.y) / L * f))
          }
          let shown = try #require(app.scene.items.first { $0.id == need.kubb })
          #expect(shown.z > 0.035)  // drawn tipped up
          try app.raiseLetGo()
          #expect(try standsOn(app, need, want), "the drag's end")
        }
      } else if oks.contains(false) && oks.contains(true) && !refusedSeen {
        // the rules refuse one end: a tap nearer it sends nothing and lights the other
        refusedSeen = true
        let app = probe
        let g = try #require(app.raiseGeometry(in: size))
        let refused = try #require(oks.firstIndex(of: false))
        let near = try #require([0.2, 0.8].first {
          nearestFoot(app, .between(g.caps[0], g.caps[1], $0)) == refused
        })
        let hash = try app.engine.hash()
        let i = try #require(app.raisePick(at: .between(g.caps[0], g.caps[1], near), size: size))
        #expect(i == refused)
        #expect(try !app.raiseTap(i))
        #expect(try app.engine.hash() == hash)
        #expect(app.raiseEnds(in: size).first { $0.lit }?.index == 1 - refused)
        #expect(app.wantsFrames)
        for _ in 0..<25 { try app.tick(0.05) }
        #expect(!app.raiseEnds(in: size).contains { $0.lit })  // lit for a second
        let j = try #require(app.raisePick(at: .between(g.caps[0], g.caps[1], 1 - near), size: size))
        #expect(try app.raiseTap(j))
        #expect(try standsOn(app, need, 1 - refused))
      }
    }
    #expect(picked["A"] == [0, 1] && picked["B"] == [0, 1], "both teams' frames, each half its own end")
    #expect(dragged && refusedSeen)
  }

  /// Writes Fixtures/solo/raise-many.json: the first raise of two or more kubbs
  /// for side A in a synthetic match (no names but You and Computer). Run with
  /// TW_WRITE_RAISE_FIXTURE=1; the planner engine throws for side A.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TW_WRITE_RAISE_FIXTURE"] == "1"))
  func writeRaiseManyFixture() throws {
    let match = try Engine(appVersion: "test"), planner = try Engine(appVersion: "test")
    for seed in 1001..<1040 {
      _ = try match.call(
        "new",
        json:
          #"{"mode":"match","seed":\#(seed),"first":"A","cpu":"B","raising":"hand","surface":"grass","opening":"2-4-6","wind":"off","set":"classic","teams":{"A":{"name":"You","players":[{"name":"You","level":"club"}]},"B":{"name":"Computer","players":[{"name":"Computer","level":"club"}]}},"start":{"year":2026,"month":11,"day":17,"hour":12,"min":0}}"#
      )
      _ = try match.call("setControl", json: #"{"sides":["A"],"cpu":true}"#)
      for _ in 0..<3000 {
        let need = try JSONNode.parse(match.call("need"))
        let kind = need["kind"]?.string
        if kind == "over" { break }
        if kind == "raise", need["side"]?.string == "A", (need["of"]?.int ?? 0) >= 2,
          need["n"]?.int == 1
        {
          let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/solo/raise-many.json")
          try Data(match.call("snapshot").utf8).write(to: out, options: .atomic)
          print("raise-many: seed \(seed), \(need["of"]?.int ?? 0) kubbs")
          return
        }
        let action: String
        if kind == "raise" {
          action = #"{"type":"raise"}"#
        } else if kind == "punish", let c = need["cursor"] {
          action = #"{"type":"punish","x":\#(c["x"]!.double!),"y":\#(c["y"]!.double!)}"#
        } else if kind == "throw", need["cpu"]?.bool == true {
          let frame = try JSONNode.parse(match.call("frame", json: #"{"dt":0.1}"#))
          _ = frame
          continue
        } else {
          var snap =
            try JSONSerialization.jsonObject(with: Data(match.call("snapshot").utf8))
            as! [String: Any]
          var opts = snap["opts"] as! [String: Any]
          opts["cpu"] = ["A", "B"]
          snap["opts"] = opts
          _ = try planner.call(
            "restore",
            json: String(decoding: try JSONSerialization.data(withJSONObject: snap), as: UTF8.self))
          var found: String?
          for _ in 0..<400 where found == nil {
            found = try JSONNode.parse(planner.call("frame", json: #"{"dt":0.1}"#))["action"]?.raw
              .text
          }
          action = try #require(found)
        }
        let r = try JSONNode.parse(match.call("apply", json: action))
        try #require(r["ok"]?.bool == true, "seed \(seed) stopped")
      }
    }
    Issue.record("no raise of two or more kubbs for side A")
  }
}
