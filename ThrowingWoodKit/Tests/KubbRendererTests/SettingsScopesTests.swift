import Foundation
import Testing

@testable import KubbRenderer

/// Every setting lives where its scope says (the owner's sheet, 2026-11-20): the
/// device's (name, sound, haptics, meter and its side, the app icon) together in Settings,
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

  /// The device's controls are made in one file only, and Settings has them all. The
  /// name is the device's too, picked in its name row in Settings and in the You row of a
  /// set-up screen (the solo card, the lobby), as on the web; nothing types it.
  @Test func theDevicesSettingsAreTogetherInSettings() throws {
    let controls = ["FeedbackSettings(", "MeterSettings(", "AppIconSettings("]
    let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
    for name in files where name != "Settings.swift" {
      let text = try file(name)
      for c in controls { #expect(!text.contains(c), "\(name) presents \(c) outside Settings") }
      #expect(!text.contains("$model.name"), "\(name) binds the name")
      #expect(!text.contains("model.nameRow"), "\(name) makes the device's name row outside Settings.swift")
    }
    let settings = try body("Settings.swift", "SettingsCard")
    // the name row (the name and SHUFFLE) and, in Settings alone, a stepper per word
    for c in controls + ["NameRowView(row: row", "NameSteppers(row: row)", "model.nameRow"] {
      #expect(settings.contains(c), "Settings has \(c)")
    }
    #expect(try body("Settings.swift", "PlayerLine").contains("NameRowView(row: row"))
    for name in files where name != "Settings.swift" {
      #expect(!(try file(name)).contains("NameSteppers("), "\(name) steps a name's words outside Settings")
    }
    #expect(try body("MatchCards.swift", "MatchOptionsCard").contains("PlayerLine(model: model)"))
    #expect(try body("OnlineCards.swift", "LobbyCard").contains("PlayerLine(model: model)"))
  }

  /// No name is typed anywhere (the owner, 2026-11-21): the only text fields left are the
  /// pitch code to join and Send feedback's answers, which go privately to the developer.
  @Test func noNameIsTyped() throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
    var fields: [String] = []
    for name in files {
      let text = try file(name)
      for m in text.matches(of: /TextField\("([^"]*)"/) { fields.append(String(m.1)) }
      #expect(!text.contains("NameField"), "\(name) keeps a name field")
    }
    #expect(fields.sorted() == ["", "Pitch link or code"])
    #expect(try file("ThrowReport.swift").contains(#"TextField("", text: value"#))
  }

  /// Settings is reached from home and from inside a match: the match and pitch
  /// menus and the practice menu.
  @Test func settingsIsReachedFromHomeAndEveryMatch() throws {
    #expect(try body("MatchCards.swift", "HomeCard").contains("model.openSettings"))
    // the menus' two by two grid (the 1.0 design) holds SETTINGS
    #expect(try body("MatchCards.swift", "MenuGrid").contains("SettingsButton(model: model)"))
    #expect(try body("MatchCards.swift", "MatchMenu").contains("MenuGrid(model: model)"))
    #expect(try body("OnlineCards.swift", "OnlineMenu").contains("MenuGrid(model: model)"))
    // the practice menu is a card of its own (stage 3: its pop-ups became segmented bars)
    #expect(try body("MatchCards.swift", "PracticeMenu").contains("SettingsButton(model: model)"))
    #expect(try file("GameView.swift").contains("model.screen = .practiceMenu"))
  }

  /// The practice menu's own options, Scene and (where the scene leaves one) Surface,
  /// are the game's, from the engine's card: Scene's seven picture tiles (the web's MENU),
  /// Surface a segmented bar, never a native pop-up (the 1.0 system's controls).
  @Test func thePracticeMenusRowsAreSegmentedBars() throws {
    let menu = try body("MatchCards.swift", "PracticeMenu")
    let view = try file("GameView.swift")
    #expect(menu.contains("options.card(model.practiceScene)"))
    #expect(menu.contains("SceneTiles(") && menu.contains("Segmented("))
    #expect(!menu.contains("Picker("))
    #expect(!view.contains("Picker("))
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
