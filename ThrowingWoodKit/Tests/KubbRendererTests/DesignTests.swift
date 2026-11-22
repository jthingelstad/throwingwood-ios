import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// The 1.0 design's shared pieces (kubb-sources design, the build list's "Shared by
/// every client" and "iPhone and iPad"): the tokens, the segmented bar's VoiceOver
/// words, the header's words, the Play the computer card's order and the scene table.
@MainActor struct DesignTests {
  // MARK: the tokens

  /// The day's skin is the system's tokens (design/system/tokens.json).
  @Test func theDayIsTheSystemsTokens() {
    let d = SceneSkin.day
    #expect(d.ink == SkinPaint(0x16130f) && d.drop == SkinPaint(0x16130f))
    #expect(d.paper == SkinPaint(0xf7f0de) && d.baton == SkinPaint(0xfbf6ea) && d.field == SkinPaint(0xffffff))
    #expect(d.header == SkinPaint(0xecd09a) && d.muted == SkinPaint(0x5b4a2c))
    #expect(d.accent == SkinPaint(0xf2b705) && d.onAccent == d.ink)
    #expect(d.teamA == SkinPaint(0xf2b705) && d.teamB == SkinPaint(0x8e44ad))
    // one dim over the pitch: ink at 50%
    #expect(d.dim == SkinPaint(0x16130f, 0.5))
  }

  /// Words on their ground are 4.5:1 or better in the day (the scenes' 7:1 is
  /// SceneSkinTests'); the system's own figures: ink on paper 16:1, muted 7.4:1, ink on
  /// marigold 10.2:1 (the system says 11), white on violet 5.6:1. The refused reason's
  /// red chip was 4.4:1 and is now 5:1.
  @Test func theDaysWordsReadAtFourAndAHalf() {
    for pair in SceneSkin.day.textPairs {
      let ratio = SkinPaint.contrast(pair.fg, pair.bg)
      #expect(ratio >= 4.5, "day \(pair.name): \(ratio)")
    }
    let d = SceneSkin.day
    #expect(SkinPaint.contrast(d.ink, d.paper) > 16)
    #expect(SkinPaint.contrast(d.muted, d.paper) > 7.3)
    #expect(SkinPaint.contrast(d.onAccent, d.accent) > 10)
    #expect(SkinPaint.contrast(d.onTeamB, d.teamB) > 5.5)
  }

  // MARK: the segmented bar

  /// Each part reads "Clock, selected, 1 of 2" (the design's VoiceOver words).
  @Test func aSegmentSpeaksItsChoiceStateAndPlace() {
    #expect(SegmentWords.spoken("Clock", index: 0, count: 2, selected: true) == "Clock, selected, 1 of 2")
    #expect(SegmentWords.spoken("Linear", index: 1, count: 2, selected: false) == "Linear, 2 of 2")
    #expect(SegmentWords.value(index: 2, count: 3, selected: true) == "selected, 3 of 3")
  }

  // MARK: the header

  /// "Turn N · baton n of m" where "2 batons left" was; the counts' spoken label.
  @Test func theHeaderCountsTheSameWayEverywhere() {
    #expect(HeaderWords.line(turn: 4, n: 2, of: 6, projectile: "baton", watching: false) == "Turn 4 · baton 2 of 6")
    #expect(HeaderWords.line(turn: 3, n: 1, of: 4, projectile: "kubb", watching: false) == "Turn 3 · kubb 1 of 4")
    #expect(HeaderWords.line(turn: 5, n: 6, of: 6, projectile: "baton", watching: true) == "Watch · turn 5 · baton 6 of 6")
    #expect(HeaderWords.line(turn: 1, n: nil, of: nil, projectile: nil, watching: false) == "Turn 1")
    #expect(
      HeaderWords.counts(a: 5, b: 4, teamA: "Mighty Maple", teamB: "Computer")
        == "Kubbs standing: Mighty Maple 5, Computer 4")
    #expect(HeaderWords.counts(a: 3, b: 5, teamA: nil, teamB: nil) == "Kubbs standing: Team A 3, Team B 5")
    #expect(HeaderWords.menu == "MENU" && HeaderWords.menuLabel == "Menu")
  }

  /// The app's header shows these words and no longer the old ones.
  @Test func theAppsHeaderUsesTheNewWords() throws {
    let text = try String(contentsOf: Self.app.appending(path: "MatchCards.swift"), encoding: .utf8)
    #expect(text.contains("HeaderWords.line(") && text.contains("HeaderWords.counts("))
    for old in ["batons left", "ellipsis.circle", "accessibilityLabel(\"Match menu\")", "You \\(counts"] {
      #expect(!text.contains(old), "MatchCards.swift still has \(old)")
    }
  }

  // MARK: Play the computer

  /// Scene first, then Computer, Opening, Raising, Wind, and Surface as a fifth row;
  /// no Kubbs row (the scene decides the set).
  @Test func theCardsRowsAreInTheDesignsOrder() throws {
    let app = try PitchSession(appVersion: "test")
    #expect(app.options.cardRows.map(\.id) == ["scene", "computer", "opening", "raising", "wind", "surface"])
    #expect(!app.options.cardRows.contains { $0.id == "set" })
    // a set kept from before is not the match's: the scene's is
    var kept = app.options.defaults
    kept["set"] = "usa"
    kept["scene"] = "neon"
    let start = app.options.starting(kept)
    #expect(start["set"] == "classic" && start["scene"] == "neon")
    try app.startSolo(name: "Mighty Maple", selections: start, save: nil)
    let snapshot = try JSONNode.parse(app.engine.call("snapshot"))
    #expect(snapshot["opts"]?["set"]?.string == "classic")
  }

  /// The card in the app draws its rows in that order and its buttons as the design
  /// does: HOME quiet at the left, START go at the right.
  @Test func theAppsCardFollowsTheOrder() throws {
    let text = try String(contentsOf: Self.app.appending(path: "MatchCards.swift"), encoding: .utf8)
    let start = try #require(text.range(of: "struct MatchOptionsCard: View"))
    let body = String(text[start.upperBound...].prefix(4000))
    #expect(body.contains("options.cardRows") && body.contains("SceneTiles("))
    let home = try #require(body.range(of: "QuietButton(\"HOME\""))
    let go = try #require(body.range(of: "\"START\""))
    #expect(home.lowerBound < go.lowerBound)
  }

  // MARK: the scenes' names

  /// The names a player sees are in one table, and the Scene row reads it: Park, Camping
  /// and Techno (the owner, 2026-11-22), the ids unchanged.
  @Test func theScenesNamesAreOneTable() {
    #expect(SceneID.shownNames.map(\.id) == ["day", "night", "neon"])
    #expect(SceneID.shownNames.map(\.name) == ["Park", "Camping", "Techno"])
    #expect(SceneID.row.choices == SceneID.shownNames.map { [$0.id, $0.name] })
    #expect(SceneID.kubbs(of: "night") == "classic" && SceneID.kubbs(of: "sunset") == "classic")
  }

  static var app: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../ThrowingWood").standardized
  }
}
