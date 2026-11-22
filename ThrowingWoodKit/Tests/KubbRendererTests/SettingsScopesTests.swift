import Foundation
import Testing

@testable import KubbRenderer

/// Every setting lives where its scope says (the owner's sheet, 2026-11-20): the
/// device's (name, sound, haptics, meter and its side) together in Settings,
/// reached from home and from inside a match; the game's on the match options (the
/// solo options, the practice menu, the lobby) and nowhere else.
@MainActor struct SettingsScopesTests {
  private func defaults(_ values: [String: String]) -> UserDefaults {
    let name = "player-name-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    for (k, v) in values { d.set(v, forKey: k) }
    return d
  }

  // MARK: the name, one value on the device

  @Test func aFirstRunHasNoName() {
    let d = defaults([:])
    #expect(PlayerName.load(d) == "")
    #expect(d.string(forKey: PlayerName.key) == nil)
    #expect(PlayerName.shown("") == nil && PlayerName.shown("  ") == nil)
  }

  @Test func theLobbysNameIsTheDevices() {
    #expect(PlayerName.load(defaults([PlayerName.key: "Birch", "solo.name": "Ada"])) == "Birch")
  }

  /// A player who only ever played the computer keeps the name typed there, moved
  /// once; its "You" was the fallback, not a name.
  @Test func theSoloNameIsMovedOnce() {
    let d = defaults(["solo.name": "Ada"])
    #expect(PlayerName.load(d) == "Ada")
    #expect(d.string(forKey: PlayerName.key) == "Ada")
    #expect(d.string(forKey: "solo.name") == nil)  // read once, then gone
    #expect(PlayerName.load(defaults(["solo.name": "You"])) == "")
    #expect(PlayerName.load(defaults([PlayerName.key: "", "solo.name": "Ada"])) == "Ada")
  }

  /// A name cleared in Settings stays cleared: the solo set-up's old name does not
  /// come back at the next launch.
  @Test func aClearedNameStaysCleared() {
    let d = defaults(["solo.name": "Ada"])
    #expect(PlayerName.load(d) == "Ada")
    PlayerName.store("", in: d)
    #expect(PlayerName.load(d) == "")
    let never = defaults(["solo.name": "Ada"])
    PlayerName.store("", in: never)  // cleared before it was ever read
    #expect(PlayerName.load(never) == "")
  }

  @Test func aStoredNameWins() {
    let d = defaults(["solo.name": "Ada"])
    PlayerName.store("Cedar", in: d)
    #expect(PlayerName.load(d) == "Cedar")
    #expect(PlayerName.shown(" Cedar ") == "Cedar")
  }

  /// A match against the computer started with no name is "You", as before.
  @Test func noNameIsYouAgainstTheComputer() throws {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "", level: "club", selections: app.options.defaults, save: nil)
    #expect(try app.engine.call("snapshot").contains(#""name":"You""#))
  }

  // MARK: where each setting is presented (the app's screens)

  private var app: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../ThrowingWood").standardized
  }
  private func file(_ name: String) throws -> String {
    try String(contentsOf: app.appending(path: name), encoding: .utf8)
  }
  private func body(_ name: String, _ view: String) throws -> String {
    let text = try file(name)
    let start = try #require(text.range(of: "struct \(view): View"), "\(view) in \(name)")
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
  }

  /// The device's controls are made in one file only, and Settings has them all.
  @Test func theDevicesSettingsAreTogetherInSettings() throws {
    let controls = ["FeedbackSettings(", "MeterSettings(", "NameField("]
    let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
    for name in files where name != "Settings.swift" {
      let text = try file(name)
      for c in controls { #expect(!text.contains(c), "\(name) presents \(c) outside Settings") }
      #expect(!text.contains("$model.name"), "\(name) binds the name")
      #expect(!text.contains(#"TextField("Your name""#), "\(name) asks the name")
    }
    let settings = try body("Settings.swift", "SettingsCard")
    for c in controls { #expect(settings.contains(c), "Settings has \(c)") }
  }

  /// Settings is reached from home and from inside a match: the match and pitch
  /// menus and the practice menu.
  @Test func settingsIsReachedFromHomeAndEveryMatch() throws {
    #expect(try body("MatchCards.swift", "HomeCard").contains("model.openSettings"))
    #expect(try body("MatchCards.swift", "MatchMenu").contains("SettingsButton(model: model)"))
    #expect(try body("OnlineCards.swift", "OnlineMenu").contains("SettingsButton(model: model)"))
    #expect(try file("GameView.swift").contains("action: model.openSettings"))
  }

  /// No game setting hides in Settings: the options rows, the scene, the surface and
  /// Raising are the game's.
  @Test func noGameSettingIsInSettings() throws {
    let settings = try body("Settings.swift", "SettingsCard")
    for game in ["selections", "optionRows", "Surface", "practiceScene", "RaisingSetting", "raiseAutomatically", "online.option"] {
      #expect(!settings.contains(game), "Settings holds \(game)")
    }
  }
}
