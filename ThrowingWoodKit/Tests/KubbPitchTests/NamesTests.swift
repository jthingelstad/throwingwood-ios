import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// The engine's names door (Names.swift; kubb-engine docs/SESSION.md "Names").
@MainActor struct NamesTests {
  func names(seed: Int? = nil) throws -> Names {
    let engine = try Engine(appVersion: "0.0-test")
    return seed.map { s in Names(engine: engine, seed: { s }) } ?? Names(engine: engine)
  }

  /// A seed gives one name on every client: the engine's own worked examples.
  @Test func aSeedGivesTheEnginesName() throws {
    #expect(try names(seed: 42).roll(.player)?.text == "Midsummer Myrtle")
    let kept = try names(seed: 7).roll(.team, keep: (shape: "adj", words: [nil, "Lumberjacks"]))
    #expect(kept?.text == "Epic Lumberjacks" && kept?.parts == NameParts(shape: "adj", words: ["Epic", "Lumberjacks"]))
    let n = try names()
    #expect(try n.step(.player, NameParts(shape: "adj", words: ["Mighty", "Maple"]), slot: 1)?.text == "Mighty Myrtle")
    #expect(
      try n.choices(.player, NameParts(shape: "adj", words: ["Magnificent", "Maple"]), slot: 1)
        == ["Ash", "Elm", "Fir", "Oak", "Pear", "Pine", "Plum", "Teak"])
    #expect(try n.make(.player, NameParts(shape: "adj", words: ["Salty", "Walnut"])) == nil)
    #expect(n.prefix(.team, shape: "the") == "The" && n.prefix(.team, shape: "adj") == nil)
  }

  /// Every name rolled from the system's randomness is a generated name.
  @Test func aRolledNameIsAlwaysValid() throws {
    let n = try names()
    for _ in 0..<50 {
      let p = try #require(try n.roll(.player)), t = try #require(try n.roll(.team))
      #expect(n.valid(.player, p.text).ok && n.valid(.team, t.text).ok)
    }
  }

  /// A boundary takes a generated name or one of the engine's defaults; anything typed
  /// fails, and is shown as the default for its place.
  @Test func theCheckTakesGeneratedNamesAndDefaults() throws {
    let n = try names()
    #expect(n.valid(.player, "Mighty Maple").ok && n.passes(.player, "Mighty Maple"))
    for d in ["Computer", "Player 1", "Player 6", "Team A", "Team B"] {
      #expect(n.valid(.player, d).isDefault && !n.valid(.player, d).ok && n.passes(.player, d), "\(d)")
    }
    for typed in ["Ada", "", " Mighty Maple", "mighty maple", "Mighty  Maple", "Salty Walnut", "You", nil] {
      #expect(!n.passes(.player, typed), "\(String(describing: typed))")
    }
    #expect(n.shown(.player, "Ada", fallback: Names.playerDefault(2)) == "Player 2")
    #expect(Names.playerDefault(0) == "Player 1" && Names.playerDefault(9) == "Player 6")
    #expect(Names.teamDefault("B") == "Team B" && Names.teamDefault("x") == "Team A")
    // a side of one plays under its player's name
    #expect(n.teamPasses("Mighty Maple", players: 1) && !n.teamPasses("Mighty Maple", players: 2))
    #expect(n.teamPasses("Birch Batons", players: 3))
  }

  /// A match whose names do not all pass is named by badNames.
  @Test func badNamesOfAMatch() throws {
    let n = try names()
    func setup(_ a: String, _ ap: [String], _ b: String, _ bp: [String]) throws -> JSONNode {
      func side(_ t: String, _ ps: [String]) -> JS {
        .object([("name", .string(t)), ("players", .array(ps.map { .object([("name", .string($0))]) }))])
      }
      return try JSONNode.parse(JS.object([("teams", .object([("A", side(a, ap)), ("B", side(b, bp))]))]).ascii)
    }
    #expect(n.badNames(setup: try setup("Mighty Maple", ["Mighty Maple"], "Computer", ["Computer"])).isEmpty)
    #expect(n.badNames(setup: try setup("Birch Batons", ["Mighty Maple", "Player 2"], "Team B", ["Lucky Larch", "Brave Birch"])).isEmpty)
    #expect(n.badNames(setup: try setup("Ada", ["Ada"], "Computer", ["Computer"])) == ["Ada", "Ada"])
    #expect(n.badNames(setup: try setup("Mighty Maple", ["Mighty Maple", "Lucky Larch"], "Team B", ["Lucky Larch"])) == ["Mighty Maple"])
    #expect(n.badNames(snapshot: "not json").isEmpty)
  }

  /// Two members with one name are told apart in a lobby, never by changing it.
  @Test func twoAlikeAreToldApart() {
    let shown = Names.apart([("a", "Mighty Maple"), ("b", "Lucky Larch"), ("c", "Mighty Maple"), ("d", "Mighty Maple")])
    #expect(shown == ["a": "Mighty Maple", "b": "Lucky Larch", "c": "Mighty Maple II", "d": "Mighty Maple III"])
  }
}
