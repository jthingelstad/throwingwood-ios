import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// Kid matches (engine 0.15, kubb-engine docs/notes/kid-mode.md): the Kid computer makes
/// the match a Kid match; the app offers Kid first, draws the Kid line, words STAND for it
/// and says "Kid match", and never tells a child they were punished or lost.
@MainActor struct KidTests {
  static func kidMatch(scene: String = "day") throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    var chosen = app.options.choosing(scene: scene, app.options.defaults)
    chosen["computer"] = "kid"
    try app.startSolo(name: "Mighty Maple", selections: chosen, save: nil)
    return app
  }

  @Test func kidIsFirstOnTheComputerRow() throws {
    let app = try PitchSession(appVersion: "test")
    let row = try #require(app.options.cardRows(app.options.defaults).first { $0.id == "computer" })
    #expect(row.choices.map { $0[0] } == ["kid", "beginner", "club", "pro"])
    #expect(row.choices.first?.last == "Kid")
    #expect(app.options.levels.first == "kid")
  }

  /// The Kid computer makes a Kid match: three base kubbs a side, the Kid line in the aim
  /// and on the scene, STAND worded for it, the hand-off's kicker.
  @Test func aKidMatch() throws {
    let app = try Self.kidMatch()
    #expect(app.need?.kid == true)
    let base = app.scene.items.filter { $0.kind == "kubb" }
    #expect(base.filter { $0.team == "A" }.count == 3 && base.filter { $0.team == "B" }.count == 3)
    let kid = try #require(app.scene.kidY)
    #expect(abs(kid - 2) < 0.001)
    #expect(app.standAim.kidY == kid)
    #expect(HandoffWords.kid(app.need) == "Kid match · throw from the cones")
    // the stance starts on the Kid line, and STAND says so
    let p = app.standPoint
    #expect(StandPad.caption(x: p.x, y: p.y, aim: app.standAim) == "MIDDLE, ON THE KID LINE. STAND ANYWHERE FROM BEHIND YOUR LINE UP TO THE KID LINE.")
    #expect(StandPad.valueText(x: p.x, y: p.y, aim: app.standAim) == "middle, on the kid line")
    // a kubb's limit is the Kid line too
    let kubb = StandAim(projectile: "kubb", lineY: 0, forwardY: 2, kidY: 2)
    #expect(StandPad.Span(kubb).limit == 2)
    #expect(StandPad.Span(StandAim(projectile: "kubb", lineY: 0, forwardY: 0)).limit == 0)
    // any other match has none of it
    let club = try PitchSession(appVersion: "test")
    try club.startSolo(name: "Mighty Maple", selections: club.options.defaults, save: nil)
    #expect(club.need?.kid != true && club.scene.kidY == nil && HandoffWords.kid(club.need) == nil)
    #expect(club.scene.items.filter { $0.kind == "kubb" && $0.team == "A" }.count == 5)
  }

  @Test func theKicker() throws {
    func need(_ json: String) throws -> MatchNeed { try JSONDecoder().decode(MatchNeed.self, from: Data(json.utf8)) }
    #expect(HandoffWords.kid(try need(#"{"kind":"throw","kid":true,"setup":{"n":1,"of":6,"projectile":"baton","label":"","kingShot":true}}"#)) == "Kid match · the king from your line")
    #expect(HandoffWords.kid(try need(#"{"kind":"raise","kid":true}"#)) == "Kid match")
    #expect(HandoffWords.kid(try need(#"{"kind":"throw"}"#)) == nil)
    for line in [HandoffWords.kidLines.cones, HandoffWords.kidLines.king, HandoffWords.kidLines.plain] {
      for word in ["punish", "lose", "lost", "out"] { #expect(!line.lowercased().contains(word)) }
    }
  }

  /// The flag a Kid ruling shows (the web's flagFor): the king stood back up and a kubb
  /// placed say so; a helicopter that counts shows what it did, never HELICOPTER.
  @Test(arguments: [
    (#"{"flag":"1 DOWN","ruling":{"short":"KING BACK UP","code":"field","parts":[{"code":"field"},{"code":"kingUp"}]}}"#, "KING BACK UP"),
    (#"{"flag":"MISS","ruling":{"short":"KING BACK UP","code":"kingUp","parts":[{"code":"kingUp"}]}}"#, "KING BACK UP"),
    (#"{"flag":"IN","ruling":{"short":"OUT TWICE: PLACED","code":"placed","parts":[{"code":"placed"}]}}"#, "OUT TWICE: PLACED"),
    (#"{"flag":"HELICOPTER","ruling":{"short":"1 DOWN","code":"field","parts":[{"code":"field"},{"code":"helicopterCounts"}]}}"#, "1 DOWN"),
    (#"{"flag":"2 DOWN","ruling":{"short":"2 DOWN","code":"field","parts":[{"code":"field"},{"code":"helicopterCounts"}]}}"#, "2 DOWN"),
    (#"{"flag":"HELICOPTER","ruling":{"short":"HELICOPTER: DOESN'T COUNT","code":"helicopter"}}"#, "HELICOPTER"),
    (#"{"flag":"2 DOWN"}"#, "2 DOWN"),
  ])
  func kidRulingsFlag(json: String, flag: String) throws {
    let r = try JSONDecoder().decode(ThrowResult.self, from: Data(json.utf8))
    #expect(r.shownFlag == flag)
  }

  /// The Kid line drawn: its cones stand on the pitch's picture in every scene, and the
  /// minimap marks it. SCENE_LOOKS_OUT keeps the pictures.
  @Test(arguments: SceneID.catalogue.map(\.id))
  func theKidLineIsDrawn(scene: String) throws {
    let app = try Self.kidMatch(scene: scene)
    app.dismissHandoff()
    // the thrower stands on the line, so the aim's own view is past it: the side view
    // (ARC open) shows it, its cones and the thrower's spot on it
    try app.togglePlan()
    for _ in 0..<60 { try app.tick(1.0 / 60) }
    let size = SceneLooksTests.upright
    let ctx = SceneLooksTests.draw(app, size)
    SceneLooksTests.keep(ctx, "\(scene)-kid-side")
    var without = app.scene
    without.kidY = nil
    let plain = SceneLooksTests.picture(size) { c in
      PitchRenderer.draw(in: c, size: size, camera: app.shownCamera, scene: without, look: scene)
    }
    #expect(SceneLooksTests.pixels(ctx) != SceneLooksTests.pixels(plain))
    // and the minimap marks it
    func map(_ s: PitchScene) -> [UInt8] {
      SceneLooksTests.pixels(SceneLooksTests.picture(CGSize(width: 90, height: 130)) { c in
        s.drawMap(in: c, rect: CGRect(x: 4, y: 4, width: 80, height: 120), look: scene)
      })
    }
    #expect(map(app.scene) != map(without))
  }
}
