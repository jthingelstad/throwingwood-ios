import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// The player's kept level: one value on the device, no longer set on any screen.
/// From engine 0.13 a person throws on one meter whatever level is named (kubb-engine
/// docs/notes/throw.md "The person's meter"); the level is still kept and passed for
/// matches on the carried engines before 0.13, which plan a person's throw at it.
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

  /// The solo set-up's level row is the computer's; the player's kept level still
  /// goes on the player's entry (the engine takes and keeps it).
  @Test func soloSplitsThePlayersLevelFromTheComputers() throws {
    let app = try PitchSession(appVersion: "test")
    var choices = app.options.defaults
    choices["computer"] = "beginner"
    try app.startSolo(name: "Ada", level: "pro", selections: choices, save: nil)
    let snapshot = try app.engine.call("snapshot")
    #expect(snapshot.contains(#""level":"pro""#))
    // since 0.9 the computer's level is the match's own option, not its player entry
    #expect(snapshot.contains(#""computer":"beginner""#))
  }

  /// The bars of a person's practice throw at each level (the engine's setLevel), on
  /// the carried engine `minor`, straight through the session calls the app makes.
  private func bars(minor: String, levels: [String]) throws -> [[Double?]] {
    let engine = try Engine(minor: minor, appVersion: "test")
    _ = try engine.call("new", json: #"{"mode":"practice","surface":"grass"}"#)
    return try levels.map { level in
      _ = try engine.call("setLevel", json: #"{"level":"\#(level)"}"#)
      let dial = try #require(JSONNode.parse(engine.call("view"))["dial"])
      return ["powerLo", "powerHi", "releaseLo", "releaseHi"].map { dial[$0]?.double }
    }
  }

  /// On 0.13 a person's level changes nothing in their throw: the bars are the
  /// meter's whatever level is set.
  @Test func onTheNewestEveryLevelThrowsOnTheOneMeter() throws {
    let got = try bars(minor: Engine.newest, levels: levels)
    #expect(got[0][0] != nil)
    #expect(got.allSatisfy { $0 == got[0] })
  }

  /// No screen asks for or shows the player's level: the solo set-up card and the
  /// online lobby show the player's line (the name and the way to Settings), and
  /// nothing binds the kept level.
  @Test func noScreenPresentsThePlayersLevel() throws {
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
      #expect(try body(file, view).contains("PlayerLine(model: model)"), "\(view) shows the player's line")
    }
    let all = try FileManager.default.contentsOfDirectory(atPath: app.path)
      .filter { $0.hasSuffix(".swift") }
    for name in all {
      let text = try String(contentsOf: app.appending(path: name), encoding: .utf8)
      #expect(!text.contains("$model.throwLevel"), "\(name) binds the player's level")
      #expect(!text.contains("Your level") && !text.contains("Throwing at"), "\(name) shows the player's level")
      #expect(!text.contains("LevelSetting(") && !text.contains("LevelLine("), "\(name) presents a level")
    }
  }
}
