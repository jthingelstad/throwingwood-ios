import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// A level (Beginner, Club, Pro) is the computer's alone; a person's throw is Easy,
/// Standard or Hard (engine 1.3, `ThrowChoice`), the width of the meter's bars and never a
/// hidden miss (the owner, 2026-11-26: what you do shows). Standard is the engine's absent.
@MainActor struct ThrowLevelTests {
  private let levels = ["beginner", "club", "pro"]

  /// The solo set-up's level row is the computer's, the match's `computer` option; the
  /// person's entry carries their throw, and Standard goes as nothing.
  @Test func soloGivesTheComputerItsLevelAndThePersonTheirThrow() throws {
    for (chosen, sent) in [("hard", "hard"), ("standard", nil), ("easy", "easy")] as [(String, String?)] {
      let app = try PitchSession(appVersion: "test")
      var choices = app.options.defaults
      choices["computer"] = "beginner"
      try app.startSolo(name: "Mighty Maple", selections: choices, throw: chosen, save: nil)
      let snapshot = try JSONNode.parse(app.engine.call("snapshot"))
      #expect(snapshot["opts"]?["computer"]?.string == "beginner")
      let ada = try #require(snapshot["opts"]?["teams"]?["A"]?["players"]?.items.first)
      #expect(ada["name"]?.string == "Mighty Maple" && ada["level"] == nil)
      #expect(ada["throw"]?.string == sent, "\(chosen)")
    }
  }

  /// The engine's throw levels are the app's choices, in its order, Standard in the middle.
  @Test func theChoicesAreTheEngines() throws {
    let app = try PitchSession(appVersion: "test")
    #expect(app.options.throwLevels == ThrowChoice.choices.map(\.id))
    #expect(ThrowChoice.label == "Throw")
    #expect(ThrowChoice.sent("standard") == nil && ThrowChoice.sent("hard") == "hard")
    #expect(ThrowChoice.sent("pro") == nil && ThrowChoice.name("odd") == "Standard")
    let d = try #require(UserDefaults(suiteName: "throw-\(UUID().uuidString)"))
    #expect(ThrowChoice.load(d) == "standard")
    ThrowChoice.keep("easy", in: d)
    #expect(ThrowChoice.load(d) == "easy")
    ThrowChoice.keep("beginner", in: d)
    #expect(ThrowChoice.load(d) == "easy")
  }

  /// What you do shows: Easy's bars are wider than Standard's, Hard's narrower, on a
  /// practice throw; the computer's levels never touch a person's meter.
  @Test func theThrowIsTheBarsWidth() throws {
    func bars(_ json: String, level: String? = nil) throws -> (Double, Double) {
      let engine = try Engine(appVersion: "test")
      _ = try engine.call("new", json: json)
      if let level { _ = try engine.call("setLevel", json: #"{"level":"\#(level)"}"#) }
      let dial = try #require(JSONNode.parse(engine.call("view"))["dial"])
      let power = try #require(dial["powerHi"]?.double) - (try #require(dial["powerLo"]?.double))
      let release = try #require(dial["releaseHi"]?.double) - (try #require(dial["releaseLo"]?.double))
      return (power, release)
    }
    let base = #"{"mode":"practice","surface":"grass""#
    let standard = try bars(base + "}")
    let easy = try bars(base + #","throw":"easy"}"#)
    let hard = try bars(base + #","throw":"hard"}"#)
    #expect(easy.0 > standard.0 && easy.1 > standard.1)
    // hard keeps standard's power bar (its floor) and narrows the release
    #expect(hard.0 <= standard.0 && hard.1 < standard.1)
    for level in levels { #expect(try bars(base + "}", level: level) == standard, "\(level)") }
  }

  /// The person's practice carries the throw; a new choice starts a new practice.
  @Test func practiceCarriesTheThrow() throws {
    let app = try PitchSession(appVersion: "test")
    try app.practice(throw: "hard")
    #expect(app.practiceThrow == "hard")
    try app.practice(throw: "standard")
    #expect(app.practiceThrow == nil)
  }

  /// The screens: the solo card and the lobby show the player's line and the Throw row;
  /// no screen words a level as the player's difficulty, and the computer's level is
  /// never the person's.
  @Test func theScreensOfferTheThrowNotALevel() throws {
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
      let text = try body(file, view)
      #expect(text.contains("PlayerLine(model: model)"), "\(view) shows the player's line")
      #expect(text.contains("ThrowRow(model: model)"), "\(view) offers the throw")
    }
    let all = try FileManager.default.contentsOfDirectory(atPath: app.path)
      .filter { $0.hasSuffix(".swift") }
    for name in all {
      let text = try String(contentsOf: app.appending(path: name), encoding: .utf8)
      #expect(!text.contains("Your level") && !text.contains("Throwing at"), "\(name) shows the player's level")
      #expect(!text.contains("LevelSetting(") && !text.contains("LevelLine("), "\(name) presents a level")
      #expect(!text.contains("pitch.throwLevel"), "\(name) reads the old kept level")
    }
  }
}
