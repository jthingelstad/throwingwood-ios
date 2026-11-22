import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// A level is the computer's alone. From engine 0.13 a person throws on one meter
/// whatever level is named (kubb-engine docs/notes/throw.md "The person's meter"), and
/// with no older engine carried nothing reads a person's level, so the app keeps none,
/// sends none and shows none.
@MainActor struct ThrowLevelTests {
  private let levels = ["beginner", "club", "pro"]

  /// The solo set-up's level row is the computer's, the match's `computer` option; the
  /// person's player entry names no level.
  @Test func soloGivesTheComputerItsLevelAndThePersonNone() throws {
    let app = try PitchSession(appVersion: "test")
    var choices = app.options.defaults
    choices["computer"] = "beginner"
    try app.startSolo(name: "Mighty Maple", selections: choices, save: nil)
    let snapshot = try JSONNode.parse(app.engine.call("snapshot"))
    #expect(snapshot["opts"]?["computer"]?.string == "beginner")
    let ada = try #require(snapshot["opts"]?["teams"]?["A"]?["players"]?.items.first)
    #expect(ada["name"]?.string == "Mighty Maple" && ada["level"] == nil)
  }

  /// The bars of a person's practice throw at each level (the engine's setLevel),
  /// straight through the session calls: the meter's whatever level is set, so the app
  /// has no reason to send one.
  @Test func onTheNewestEveryLevelThrowsOnTheOneMeter() throws {
    let engine = try Engine(appVersion: "test")
    _ = try engine.call("new", json: #"{"mode":"practice","surface":"grass"}"#)
    let none = try #require(JSONNode.parse(engine.call("view"))["dial"])
    let got = try levels.map { level in
      _ = try engine.call("setLevel", json: #"{"level":"\#(level)"}"#)
      let dial = try #require(JSONNode.parse(engine.call("view"))["dial"])
      return ["powerLo", "powerHi", "releaseLo", "releaseHi"].map { dial[$0]?.double }
    }
    #expect(got[0][0] != nil)
    #expect(got.allSatisfy { $0 == got[0] })
    #expect(got[0] == ["powerLo", "powerHi", "releaseLo", "releaseHi"].map { none[$0]?.double })
  }

  /// No screen asks for or shows the player's level: the solo set-up card and the
  /// online lobby show the player's line (the name and the way to Settings), and the
  /// app keeps no level of the player's own.
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
      #expect(!text.contains("throwLevel") && !text.contains("ThrowLevel"), "\(name) keeps the player's level")
      #expect(!text.contains("Your level") && !text.contains("Throwing at"), "\(name) shows the player's level")
      #expect(!text.contains("LevelSetting(") && !text.contains("LevelLine("), "\(name) presents a level")
    }
  }
}
