import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
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

  /// On 0.9 the slider sends where the finger is (`setTilt`): any value, no steps.
  @Test func tiltSliderTakesAnyValue() throws {
    let app = try aiming()
    #expect(app.engine.minor == Engine.newest)
    let c = try #require(app.sideControl)
    #expect(c.min == -20 && c.max == 20 && c.tick == 1 && c.step == 5 && c.scope == "throw")
    #expect(try #require(app.arcControl).min == 15)
    app.slide(.side, to: 0.36, phase: .down)
    try app.tick(1.0 / 60)
    #expect(abs(try #require(app.sideStep) - -5.6) < 1e-9)
    #expect(abs(app.sidePlace - 0.36) < 1e-9)
    #expect(PlanScale.sideLabel(-5.6, kubb: false) == "TILT 6L")
    app.slide(.side, to: 1.3, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.sideStep == 20)
    // a press (VoiceOver) still steps
    try app.stepPlan(.side, by: -1)
    #expect(app.sideStep == 15)
    // ARC is free in the engine's range too
    app.slide(.arc, to: 0.123, phase: .up)
    try app.tick(1.0 / 60)
    #expect(abs(try #require(app.release) - (15 + 0.123 * 150)) < 1e-9)
    // marks: 1 degree ticks would be 1.6 pt apart on 64 pt, so one every 5
    #expect(app.sideMarks(run: 64).count == 9)
    #expect(app.sideMarks(run: 64).filter(\.long).count == 1)
  }

  @Test func marksComeFromTheTick() {
    let spin = PlanControl(min: -3, max: 3, value: 0, tick: 0.25, step: 1)
    // quarter taps are 2.7 pt apart on 64 pt: every half tap
    #expect(spin.marks(run: 64) == stride(from: -3.0, through: 3, by: 0.5).map { $0 })
    // with room, every tick
    #expect(spin.marks(run: 200).count == 25)
    let arc = PlanControl(min: 15, max: 165, value: 90, tick: 5, step: 15)
    #expect(arc.marks(run: 88) == stride(from: 15.0, through: 165, by: 15).map { $0 })
    #expect(PlanScale.sideLabel(1.25, kubb: true) == "SPIN 1.25R")
    #expect(PlanScale.sideLabel(-0.5, kubb: true) == "SPIN 0.5L")
    #expect(PlanScale.sideValueText(2, kubb: true) == "Spin 2 right")
  }

  private func armPoints(_ d: DialState) throws -> [CGPoint] {
    let dt = 1.0 / 60
    let back = try #require(d.powerLo.flatMap { lo in d.powerHi.map { (lo + $0) / 2 } })
    let stop = try #require(d.releaseLo.flatMap { lo in d.releaseHi.map { (lo + $0) / 2 } })
    var a = -5.0
    var angles = [0.0, a]
    while a > -back {
      a = max(-back, a - 400 * dt)
      angles.append(a)
    }
    while a < stop {
      a = min(stop, a + 2400 * dt)
      angles.append(a)
    }
    return angles.map { a in CGPoint(x: sin(a * .pi / 180), y: cos(a * .pi / 180)) }
  }

  /// A kubb's spin is a turn setting on 0.9 (Jamie, 2026-11-20, "Keep between
  /// throws"): the engine starts the side's next kubb from it, and the slider shows it.
  @Test func aKubbsSpinIsKeptForTheSidesNextKubb() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("inkast"), save: nil)
    app.dismissHandoff()
    #expect(app.throwsKubb && app.need?.setup?.n == 1 && app.canAim)
    let c = try #require(app.sideControl)
    #expect(c.min == -3 && c.max == 3 && c.scope == "turn")
    app.slide(.side, to: 0.75, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.sideStep == 1.5)
    for _ in 0..<60 { try app.tick(1.0 / 60) }  // the side view's peek goes
    #expect(!app.showsSide && app.sideStep == 1.5)
    for p in try armPoints(app.dial) {
      app.sample(p)
      try app.tick(1.0 / 60)
    }
    app.sample(nil)
    try app.tick(1.0 / 60)
    var ticks = 0
    while !(app.need?.setup?.n == 2 && app.canAim) && ticks < 3000 {
      try app.tick(1.0 / 60)
      ticks += 1
    }
    #expect(app.need?.kind == "throw" && app.need?.setup?.n == 2 && app.throwsKubb)
    #expect(app.sideStep == 1.5 && abs(app.sidePlace - 0.75) < 1e-9)
    #expect(PlanScale.sideLabel(app.sideStep ?? 0, kubb: true) == "SPIN 1.5R")
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

  /// Since 0.13 the meter's bars go by the throw's distance, and since 0.10 the arc's
  /// default does: both change as the circle or the stance moves, and the app has the
  /// engine's own new numbers at once, with no frame from the dial (every meter draws
  /// `dial` on each paint, so a moved plan is drawn with its own bars).
  @Test func theBarsAndTheArcsDefaultFollowThePlan() throws {
    let app = try aiming()
    func engineDial() throws -> JSONNode { try #require(JSONNode.parse(app.engine.call("view"))["dial"]) }
    func same(_ d: DialState, _ e: JSONNode) -> Bool {
      d.powerLo == e["powerLo"]?.double && d.powerHi == e["powerHi"]?.double
        && d.releaseLo == e["releaseLo"]?.double && d.releaseHi == e["releaseHi"]?.double
    }
    func width(_ d: DialState) -> Double { (d.powerHi ?? 0) - (d.powerLo ?? 0) }
    let before = app.dial
    let arcDefault = app.arcControl?.default
    #expect(same(before, try engineDial()))
    // the circle 2 m nearer: wider bars and a higher default arc, read with the move
    try app.nudgeAim(by: CGVector(dx: 0, dy: 200))
    let near = app.dial
    #expect(same(near, try engineDial()))
    #expect(width(near) > width(before))
    #expect(near.releaseHi! - near.releaseLo! > before.releaseHi! - before.releaseLo!)
    #expect(app.arcControl?.default != arcDefault)
    // the thrower a metre back with STAND: narrower bars again, read on the next tick
    let revision = app.revision
    app.stand(fx: 0.5, fy: 1, phase: .down)
    #expect(try app.tick(1.0 / 60))
    #expect(same(app.dial, try engineDial()))
    #expect(width(app.dial) < width(near))
    #expect(app.revision > revision)
    app.stand(fx: 0.5, fy: 1, phase: .up)
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

  /// On a phone on its side the linear meter's whole-height box stands over the
  /// far baseline's outer kubb on its side. A tap on the body there aims at it,
  /// a drag from the same point strokes and aims at nothing, and the knob keeps
  /// its press (the coordinator's call on the review, 2026-11-19).
  @Test func aTapOnTheWideLinearMeterAimsAtTheKubbBehindIt() throws {
    let phones: [(String, CGSize, ScreenInsets)] = [
      ("13 mini", CGSize(width: 812, height: 375), ScreenInsets(top: 0, left: 50, bottom: 21, right: 50)),
      ("17 Pro Max", CGSize(width: 956, height: 440), ScreenInsets(top: 0, left: 62, bottom: 21, right: 62)),
    ]
    for (name, size, safe) in phones {
      for side in [MeterSide.left, .right] {
        let tag = "\(name) \(side)"
        let app = try aiming()
        let ml = MeterLayout.make(
          kind: .linear, side: side, bounds: CGRect(origin: .zero, size: size), safeTop: safe.top,
          safeBottom: safe.bottom, safeLeft: safe.left, safeRight: safe.right)
        let m = try #require(ml.linear, "\(tag)")
        let p = app.scene.projection(size, app.camera)
        // the far baseline's outermost standing kubb on the meter's side
        let far = app.scene.items.filter { $0.kind == "kubb" && $0.y > 4 && $0.rotation.act(V3(0, 0, 1)).z > 0.9 }
        let kubb = try #require(
          side == .right ? far.max(by: { $0.x < $1.x }) : far.min(by: { $0.x < $1.x }), "\(tag)")
        // the middle of its drawn body
        let body = try #require(p.project(V3(kubb.x, kubb.y, kubb.z)), "\(tag)")
        #expect(m.bodyHit(body) && m.knobHit(body), "\(tag): the meter's body covers the kubb, in the upright grab band")
        #expect(!m.knobHit(body, wide: true), "\(tag): in the lane, off the knob's channel")
        let start = try #require(app.scene.marker)
        // a drag from the same point strokes, from the press as the knob's home
        let claim = try #require(ml.first(body, wide: true), "\(tag)")
        #expect(claim == .zone, "\(tag)")
        #expect(ml.press(claim, from: body, moved: true) == .stroke(grab: body.y - m.yHome), "\(tag)")
        let still = try #require(app.scene.marker)
        #expect(still.x == start.x && still.y == start.y, "\(tag): a drag aims at nothing")
        // a tap aims at the kubb behind the body
        #expect(ml.press(claim, from: body, moved: false) == .tapAims, "\(tag)")
        try app.tapAim(at: body, size: size)
        let mk = try #require(app.scene.marker)
        #expect(abs(mk.x - kubb.x) < 1e-6 && abs(mk.y - kubb.y) < 1e-6, "\(tag)")
        // a tap on the knob is the throw, never an aim
        let knob = CGPoint(x: m.knobX, y: m.yHome)
        let k = try #require(ml.first(knob, wide: true))
        #expect(ml.press(k, from: knob, moved: false) == .stroke(grab: 0), "\(tag)")
        // the upright rules (a tall screen): the band across the body grabs, the
        // rest of the body keeps its press
        #expect(ml.first(body, wide: false) == .meter(grab: body.y - m.yHome), "\(tag)")
        let low = CGPoint(x: m.laneX, y: m.yHome + 80)
        #expect(ml.first(low, wide: false) == .body && ml.first(low, wide: true) == .zone, "\(tag)")
        #expect(ml.press(.body, from: low, moved: false) == .nothing)
      }
    }
  }

  // MARK: Automatic raising

  @Test func autoRaiseStartsOnceForEachKubb() {
    var a = AutoRaise()
    func tick(_ dt: Double, _ key: String?) -> Bool { a.tick(dt, raising: key) }
    #expect(!a.seen)
    #expect(!tick(1, "1:k:1"))
    #expect(a.seen)  // the menu shows Raising from now on
    a.setGame(true)
    // the watched raise starts at once (its kubb lies a moment in RaiseShow)
    #expect(tick(0.05, "1:k:1"))
    #expect(!tick(1, "1:k:1"))  // once for each kubb
    // a card over it: it starts again after
    #expect(!tick(0.05, nil))
    #expect(tick(0.05, "1:k:1"))
    // the engine would not raise it: back to the player, as the web's refused()
    a.refused()
    #expect(!a.on && !a.game)
    #expect(!tick(10, "1:k:2"))
    var rest = AutoRaise()
    rest.restOfTurn()
    #expect(rest.on && !rest.game)
    rest.hurryUp()
    rest.turnEnded()
    #expect(!rest.on && !rest.hurry)
    // BY HAND ends AUTO ALL too; REST OF GAME keeps going past the turn
    rest.restOfTurn()
    rest.setGame(false)
    #expect(!rest.on)
    rest.restOfTurn()
    rest.setGame(true)
    rest.turnEnded()
    #expect(rest.on && rest.game)
  }

  /// The web's lift.js pace: the first kubb lies 0.4 s, then half a second a kubb (its tip
  /// 70% of it), quicker with many so a whole raise never passes four seconds, never under
  /// 0.18 s a kubb.
  @Test func aWatchedRaiseKeepsItsPace() {
    #expect(Pacing.autoRaiseWait == 0.4)
    #expect(Pacing.raiseBeat(1) == 0.5 && Pacing.raiseBeat(7) == 0.5)
    #expect(abs(Pacing.raiseBeat(9) - 0.4) < 1e-12)
    #expect(Pacing.raiseBeat(40) == 0.18)
    for n in 1...20 { #expect(Pacing.autoRaiseWait + Double(n) * Pacing.raiseBeat(n) <= Pacing.autoRaiseMost + 1e-9) }
    var s = RaiseShow(i: 0, pending: nil, lead: 0.4, beat: 0.5)
    #expect(abs(s.total - 0.9) < 1e-12)
    s.age = 0.3
    #expect(s.up(reduced: false) == 0)  // still lying
    s.age = 0.4 + 0.35 / 2
    #expect(abs(s.up(reduced: false) - 0.5) < 1e-9)  // half way through its eased tip
    // Reduce Motion: no tip; lying the first half of the beat, standing the second
    #expect(s.up(reduced: true) == 0)
    s.age = 0.4 + 0.3
    #expect(s.up(reduced: true) == 1)
    s.age = 0.4 + 0.35
    #expect(s.up(reduced: false) == 1)
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
      var raised = 0, clock = 0.0, lastAt = 0.0, tipped = 0
      let beat = Pacing.raiseBeat(first.of ?? 1)
      for _ in 0..<800 where app.need?.kind == "raise" {
        let n = try #require(app.need)
        let end = app.defaultEnd(n)
        let hash = try app.engine.hash()
        try app.tick(0.02)
        clock += 0.02
        // part way up, on the end the engine will choose, drawn with the hand drag's tip
        if let d = app.raiseDragging, d.t > 0, d.t < 1 {
          #expect(d.i == end)
          tipped += 1
        }
        // the action goes as the kubb starts to tip: the same action the engine had before
        if try app.engine.hash() != hash {
          _ = try reference.call("apply", json: #"{"type":"raise"}"#)
          #expect(try app.engine.hash() == reference.hash())
        }
        if app.need?.n != n.n || app.need?.kind != "raise" {
          raised += 1
          // the first lies 0.4 s first; each takes its beat
          let step = beat + (raised == 1 ? Pacing.autoRaiseWait : 0)
          #expect(clock - lastAt >= step - 0.021, "\(clock - lastAt)")
          #expect(clock - lastAt <= step + 0.041, "\(clock - lastAt)")
          lastAt = clock
        }
      }
      #expect(raised == first.of)
      #expect(tipped > 0)
      #expect(clock <= Pacing.autoRaiseMost + 0.1)
      try app.tick(0.05)
      #expect(!app.raisingRest)
    }
  }

  /// AUTO watches its one kubb tip up; a tap skips the rest of an AUTO ALL at once, every
  /// action the same and in the same order.
  @Test func aWatchedRaiseCanBeSkipped() throws {
    let app = try PitchSession(appVersion: "test")
    let reference = try Engine(appVersion: "test")
    let start = try fixture("raise-many")
    try app.restore(start, save: nil)
    _ = try reference.call("restore", json: start)
    let first = try #require(app.need)
    try app.raiseWatched()
    #expect(app.raiseShowing)
    // AUTO tips at once: its action has gone
    _ = try reference.call("apply", json: #"{"type":"raise"}"#)
    #expect(try app.engine.hash() == reference.hash())
    for _ in 0..<40 where app.raiseShowing { try app.tick(0.02) }
    #expect(!app.raiseShowing && app.need?.n == 2 && !app.raisingRest)
    app.raiseRest()
    try app.tick(0.02)
    #expect(app.raiseShowing)
    try app.skipRaise()
    var ticks = 0
    while app.need?.kind == "raise" && ticks < 20 {
      try app.tick(0.001)
      ticks += 1
    }
    #expect(app.need?.kind != "raise", "the rest stood in \(ticks) ticks")
    for _ in 2...(first.of ?? 2) { _ = try reference.call("apply", json: #"{"type":"raise"}"#) }
    #expect(try app.engine.hash() == reference.hash())
  }

  /// One line for VoiceOver for a whole automatic raise, not a line a kubb.
  @Test func aWatchedRaiseIsOneLine() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    app.raiseAutomatically = true
    var lines: Set<Int> = []
    for _ in 0..<400 where app.need?.kind == "raise" {
      try app.tick(0.02)
      if let n = app.raiseNews { lines.insert(n.id) }
    }
    #expect(lines.count == 1)
    #expect(app.raiseNews?.text.contains("automatically") == true)
  }

  /// The computer's raises (no raise need of this device's: the engine stands them as the
  /// turn changes) are watched after the throw that sent the kubbs over, one after
  /// another in the raise scene, before the next view; with Reduce Motion each stands
  /// with no tip. The match's actions and hashes are the engine's own.
  @Test func theComputersRaisesAreWatched() throws {
    for reduced in [false, true] {
      // the computer plays both sides, so its kubbs land and are raised by it
      let app = try PitchSession(appVersion: "test")
      try app.openMatch("new", json: #"{"mode":"match","seed":11,"cpu":"both"}"#, save: nil)
      app.reduceMotion = reduced
      var seen = false, tipped = false, kubbs = 0
      for _ in 0..<(60 * 60 * 6) {
        if app.need?.kind == "over" { break }
        try app.tick(1.0 / 60)
        if let s = app.stoodShow {
          seen = true
          kubbs = max(kubbs, s.kubbs.count)
          #expect(app.raiseShowing && !app.canAim)
          #expect(s.inPlace || app.scene.stillZoom == RaiseCamera.zoom)
          let k = s.kubbs[s.k]
          if let shown = app.scene.items.first(where: { $0.id == k.id }), shown.z > 0.04, shown.z < 0.07 {
            tipped = true
          }
        } else if seen {
          break
        }
      }
      #expect(seen, "reduced \(reduced)")
      #expect(kubbs >= 1)
      #expect(tipped != reduced, "reduced \(reduced)")
      // afterwards the board shows the engine's own view
      if app.need?.kind == "throw" {
        let v: ViewOutput = try app.read("view")
        #expect(Set(v.items.map(\.id)) == Set(app.scene.items.map(\.id)))
      }
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

  @Test func raiseTouchHoldsOnTheIPads() throws {
    // the kubb and its two ends on the screen, a press on the kubb its own, and
    // the drag's travel the same rule, upright and on its side
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise"), save: nil)
    for size in [
      CGSize(width: 744, height: 1133), CGSize(width: 1133, height: 744),
      CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032),
    ] {
      let g = try #require(app.raiseGeometry(in: size))
      let screen = CGRect(origin: .zero, size: size)
      for p in g.outline + g.caps { #expect(screen.contains(p), "\(size): \(p)") }
      let mid = CGPoint.between(g.caps[0], g.caps[1], 0.5)
      #expect(RaiseTouch.on(g, mid))
      #expect(RaiseTouch.nearerEnd(g, .between(g.caps[0], g.caps[1], 0.2)) == 0)
    }
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

  /// Writes Fixtures/solo/raise-refused.json: the first raise of the seed 5 match
  /// (invented teams North and South, pass and play) where the rules refuse one end,
  /// for the review picture of a refused tap. Run with TW_WRITE_RAISE_FIXTURE=refused.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TW_WRITE_RAISE_FIXTURE"] == "refused"))
  func writeRaiseRefusedFixture() throws {
    let acts = try realRaises()
    for nth in 0..<16 {
      guard let app = try atRealRaise(acts, nth), let need = app.need else { break }
      let oks = need.ends?.map { $0.ok != false } ?? []
      guard oks.contains(false) && oks.contains(true) else { continue }
      let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/solo/raise-refused.json")
      try Data(app.engine.call("snapshot").utf8).write(to: out, options: .atomic)
      print("raise-refused: raise \(nth), side \(need.side ?? "?"), ends \(oks)")
      return
    }
    Issue.record("no raise with a refused end")
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

  /// Writes Fixtures/solo/inkast.json: side A about to throw the first of two or more
  /// kubbs in a synthetic match (no names but You and Computer), engine 0.9. Run with
  /// TW_WRITE_INKAST_FIXTURE=1; the planner engine throws for side A.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TW_WRITE_INKAST_FIXTURE"] == "1"))
  func writeInkastFixture() throws {
    let match = try Engine(appVersion: "test"), planner = try Engine(appVersion: "test")
    for seed in 1001..<1040 {
      _ = try match.call(
        "new",
        json:
          #"{"mode":"match","seed":\#(seed),"first":"A","cpu":"B","raising":"auto","surface":"grass","opening":"2-4-6","wind":"off","set":"classic","teams":{"A":{"name":"You","players":[{"name":"You","level":"club"}]},"B":{"name":"Computer","players":[{"name":"Computer"}]}},"start":{"year":2026,"month":11,"day":17,"hour":12,"min":0}}"#
      )
      _ = try match.call("setControl", json: #"{"sides":["A"],"cpu":true}"#)
      for _ in 0..<3000 {
        let need = try JSONNode.parse(match.call("need"))
        let kind = need["kind"]?.string
        if kind == "over" { break }
        if kind == "throw", need["side"]?.string == "A", need["setup"]?["projectile"]?.string == "kubb",
          need["setup"]?["n"]?.int == 1, (need["setup"]?["of"]?.int ?? 0) >= 2
        {
          let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/solo/inkast.json")
          try Data(match.call("snapshot").utf8).write(to: out, options: .atomic)
          print("inkast: seed \(seed), \(need["setup"]?["of"]?.int ?? 0) kubbs")
          return
        }
        let action: String
        if kind == "raise" {
          action = #"{"type":"raise"}"#
        } else if kind == "punish", let c = need["cursor"] {
          action = #"{"type":"punish","x":\#(c["x"]!.double!),"y":\#(c["y"]!.double!)}"#
        } else if kind == "throw", need["cpu"]?.bool == true {
          _ = try match.call("frame", json: #"{"dt":0.1}"#)
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
    Issue.record("no inkast of two or more kubbs for side A")
  }
}
