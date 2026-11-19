import Foundation
import Testing

@testable import KubbRenderer

/// STAND (StandPad.swift): the web's tests/game/stand-pad.test.mjs, ported, and
/// the session's once-a-frame setStance.
@MainActor struct StandPadTests {
  let baton = StandAim(projectile: "baton", lineY: 0, forwardY: 0, halfWidth: 2.5, backMax: 3)

  @Test func plateShowsTheLinesWidthBackMaxBehindAndALittleInFront() {
    let s = StandPad.Span(baton)
    #expect([s.x0, s.x1, s.yBack, s.yFront, s.lineY, s.limit] == [-2.5, 2.5, -3, StandPad.front, 0, 0])
    #expect(!s.advantage)
  }

  @Test func withAnAdvantageLineABatonMayStandUpToItAKubbMayNot() {
    var adv = baton
    adv.forwardY = 2
    #expect(StandPad.Span(adv).limit == 2)
    #expect(StandPad.Span(adv).yFront == 2 + StandPad.front)
    #expect(StandPad.Span(adv).advantage)
    adv.projectile = "kubb"
    #expect(StandPad.Span(adv).limit == 0)
  }

  @Test func aPlaceOnThePlateIsAPlaceOnTheGroundAndBack() {
    let s = StandPad.Span(baton)
    let line = s.ground(fx: 0.5, fy: StandPad.front / (3 + StandPad.front))
    #expect(abs(line.x) < 1e-12 && abs(line.y) < 1e-12)
    #expect(s.ground(fx: 0, fy: 1) == (x: -2.5, y: -3))
    #expect(s.ground(fx: 1, fy: 0) == (x: 2.5, y: StandPad.front))
    // off the plate is held to its edges
    #expect(s.ground(fx: -0.4, fy: 1.7) == (x: -2.5, y: -3))
    let f = s.fraction(x: 1.25, y: -1.5)
    let g = s.ground(fx: f.fx, fy: f.fy)
    #expect(abs(g.x - 1.25) < 1e-9 && abs(g.y + 1.5) < 1e-9)
  }

  @Test func standSaysWhereTheThrowerIsInPlainWords() {
    #expect(StandPad.text(x: 0, y: 0, aim: baton) == "MIDDLE, ON THE LINE")
    #expect(StandPad.text(x: -1.23, y: -0.5, aim: baton) == "1.2 M LEFT, 0.5 M BACK")
    #expect(StandPad.text(x: 0.8, y: 1.5, aim: baton) == "0.8 M RIGHT, 1.5 M UP")
    #expect(
      StandPad.caption(x: 1.5, y: -1.7, aim: baton)
        == "1.5 M RIGHT, 1.7 M BACK. STAND ON YOUR LINE OR BEHIND IT.")
    var adv = baton
    adv.forwardY = 2
    #expect(StandPad.caption(x: 0, y: 0, aim: adv).hasSuffix("OR UP TO THE ADVANTAGE LINE."))
    #expect(StandPad.valueText(x: -1.23, y: -0.5, aim: baton) == "1.2 metres left, 0.5 metres back")
  }

  private func aiming() throws -> PitchSession {
    let file = try #require(
      Bundle.module.url(forResource: "aim", withExtension: "json", subdirectory: "Fixtures/solo"))
    let app = try PitchSession(appVersion: "test")
    try app.restore(String(contentsOf: file, encoding: .utf8), save: nil)
    app.dismissHandoff()
    return app
  }

  @Test func aPressPutsTheThrowerUnderTheFingerOnceAFrameAndTheEngineClamps() throws {
    let app = try aiming()
    #expect(app.standAim.halfWidth == 2.5 && app.standAim.backMax == 3)
    let span = app.standSpan
    app.stand(fx: 0.9, fy: 0.9, phase: .down)
    #expect(app.standHeld && app.standCaption != nil && app.wantsFrames)
    // nothing is sent until the frame
    let before = try #require(app.scene.thrower)
    app.stand(fx: 0.1, fy: 0.95, phase: .move)
    #expect(try #require(app.scene.thrower).x == before.x)
    try app.tick(1.0 / 60)
    let want = span.ground(fx: 0.1, fy: 0.95)
    let t = try #require(app.scene.thrower)
    #expect(abs(t.x - want.x) < 1e-6 && abs(t.y - want.y) < 1e-6)
    // the picture's ground is the press's, whatever the stance does
    #expect(app.standSpan == span)
    // off the plate: the engine holds it to the ground the rules allow
    app.stand(fx: 0.5, fy: 0, phase: .move)
    try app.tick(1.0 / 60)
    #expect(try #require(app.scene.thrower).y <= app.standAim.forwardY + 1e-9)
    app.stand(fx: 0.5, fy: 0.5, phase: .up)
    #expect(!app.standHeld && app.standCaption != nil)
    // the caption stays a second, then goes
    for _ in 0..<70 { try app.tick(1.0 / 60) }
    #expect(app.standCaption == nil)
    #expect(app.canAim && !app.playing)
  }

  @Test func voiceOverStepsAQuarterMetre() throws {
    let app = try aiming()
    let x = try #require(app.scene.thrower).x
    try app.standStep(dx: StandPad.keyStep, dy: 0)
    #expect(abs(try #require(app.scene.thrower).x - (x + 0.25)) < 1e-9)
    #expect(app.standCaption != nil)
  }

  @Test func cancelSendsNothingMoreAndAThrowEndsIt() throws {
    let app = try aiming()
    app.stand(fx: 0.2, fy: 0.2, phase: .down)
    app.stand(fx: 0.2, fy: 0.2, phase: .cancel)
    let before = try #require(app.scene.thrower)
    try app.tick(1.0 / 60)
    #expect(try #require(app.scene.thrower).x == before.x)
    #expect(!app.standHeld && app.standCaption == nil)
  }
}
