import Foundation
import KubbEngine
import KubbRooms
import Testing

@testable import KubbRenderer

/// The player's own level is one value on the device (Jamie, 2026-11-20: "Yes
/// this is a device/user setting... not a per game setting.").
@MainActor struct ThrowLevelTests {
  private let levels = ["beginner", "club", "pro"]
  private func defaults(_ values: [String: String]) -> UserDefaults {
    let name = "throw-level-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    for (k, v) in values { d.set(v, forKey: k) }
    return d
  }

  @Test func firstRunKeepsTodaysDefault() {
    let d = defaults([:])
    #expect(ThrowLevel.load(d, choices: levels, soloInProgress: false) == "club")
    #expect(d.string(forKey: ThrowLevel.key) == "club")
  }

  @Test func theStoredLevelWins() {
    let d = defaults([ThrowLevel.key: "pro", "pitch.level": "beginner", "solo.matchLevel": "club"])
    #expect(ThrowLevel.load(d, choices: levels, soloInProgress: true) == "pro")
    ThrowLevel.store("beginner", in: d)
    #expect(ThrowLevel.load(d, choices: levels, soloInProgress: false) == "beginner")
  }

  @Test func migrationTakesTheMostRecentOwnLevel() {
    // a level changed in the kept solo match's menu is the latest
    #expect(
      ThrowLevel.load(
        defaults(["solo.matchLevel": "pro", "solo.option.level": "beginner", "pitch.level": "club"]),
        choices: levels, soloInProgress: true) == "pro")
    // a solo match in progress: the level it was set up with
    #expect(
      ThrowLevel.load(
        defaults(["solo.option.level": "beginner", "pitch.level": "pro"]),
        choices: levels, soloInProgress: true) == "beginner")
    // no solo match: the lobby's, the player's alone
    #expect(
      ThrowLevel.load(
        defaults(["solo.option.level": "beginner", "pitch.level": "pro"]),
        choices: levels, soloInProgress: false) == "pro")
    // only the solo set-up's
    #expect(
      ThrowLevel.load(defaults(["solo.option.level": "beginner"]), choices: levels, soloInProgress: false)
        == "beginner")
    // an unknown value is passed over
    #expect(
      ThrowLevel.load(defaults(["pitch.level": "legend"]), choices: levels, soloInProgress: false)
        == "club")
  }

  @Test func migrationResetsNothingElse() {
    let d = defaults([
      "solo.option.level": "beginner", "pitch.level": "pro", "solo.matchLevel": "club",
      "pitch.meter": "linear", "solo.name": "Ada",
    ])
    _ = ThrowLevel.load(d, choices: levels, soloInProgress: false)
    #expect(d.string(forKey: "solo.option.level") == "beginner")  // the computer's, as before
    #expect(d.string(forKey: "pitch.level") == "pro")
    #expect(d.string(forKey: "solo.matchLevel") == "club")
    #expect(d.string(forKey: "pitch.meter") == "linear")
    #expect(d.string(forKey: "solo.name") == "Ada")
  }

  /// The solo set-up's Level row is the computer's; the player throws at the device's.
  @Test func soloSplitsThePlayersLevelFromTheComputers() throws {
    let app = try PitchSession(appVersion: "test")
    var choices = app.options.defaults
    choices["computer"] = "beginner"
    try app.startSolo(name: "Ada", level: "pro", selections: choices, save: nil)
    let snapshot = try app.engine.call("snapshot")
    #expect(snapshot.contains(#""level":"pro""#))
    // on 0.9 the computer's level is the match's own option, not its player entry
    #expect(snapshot.contains(#""computer":"beginner""#))
    // the player's first throw is planned at the player's level
    let view = try JSONNode.parse(app.engine.call("view"))
    if view["need"]?["cpu"]?.bool == false {
      #expect(view["aim"]?["plan"]?["level"]?.string == "pro")
    }
  }

  /// A change of the setting mid-match applies to the throw in hand (the engine's
  /// setLevel), and the match's record keeps the level it started with.
  @Test func aChangeAppliesFromTheThrowInHand() throws {
    let app = try PitchSession(appVersion: "test")
    var choices = app.options.defaults
    choices["first"] = "A"
    try app.startSolo(name: "Ada", level: "club", selections: choices, save: nil)
    let before = try app.engine.call("snapshot")
    try app.useLevel("pro")
    let view = try JSONNode.parse(app.engine.call("view"))
    if view["need"]?["cpu"]?.bool == false {
      #expect(view["aim"]?["plan"]?["level"]?.string == "pro")
    }
    #expect(try app.engine.call("snapshot").contains(#""level":"club""#))
    _ = before
  }

  /// Practice throws at the device's level too.
  @Test func practiceFollowsTheSetting() throws {
    let app = try PitchSession(appVersion: "test")
    try app.practice()
    try app.useLevel("beginner")
    let view = try JSONNode.parse(app.engine.call("view"))
    #expect(view["aim"]?["plan"]?["level"]?.string == "beginner")
  }

  /// No set-up screen asks for the player's level: the solo set-up card and the
  /// online lobby show the level line, and only Settings and the menus' level row
  /// (LevelSetting) bind it.
  @Test func noSetUpScreenPresentsTheLevelPicker() throws {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../ThrowingWood").standardized
    func body(_ file: String, _ view: String) throws -> String {
      let text = try String(contentsOf: app.appending(path: file), encoding: .utf8)
      let start = try #require(text.range(of: "struct \(view): View"))
      let rest = text[start.upperBound...]
      let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
      return String(rest[..<end])
    }
    for (file, view) in [("MatchCards.swift", "MatchOptionsCard"), ("OnlineCards.swift", "LobbyCard")] {
      let b = try body(file, view)
      #expect(b.contains("LevelLine(model: model)"), "\(view) shows the level line")
      #expect(!b.contains("$model.throwLevel"), "\(view) binds no level")
      #expect(!b.contains("LevelSetting("), "\(view) presents no level picker")
      #expect(!b.contains(#"Picker("Level""#) && !b.contains(#"Picker("Your level""#))
    }
    let all = try FileManager.default.contentsOfDirectory(atPath: app.path)
      .filter { $0.hasSuffix(".swift") }
    let binders = try all.filter {
      try String(contentsOf: app.appending(path: $0), encoding: .utf8).contains("$model.throwLevel")
    }
    #expect(binders == ["LevelSettings.swift"])
  }
}
