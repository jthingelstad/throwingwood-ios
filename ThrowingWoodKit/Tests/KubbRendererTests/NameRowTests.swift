import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// The name row (NameRow.swift, the web's src/ui/name-row.js) and the device's name
/// (PlayerName.swift, the web's src/game/player-name.js).
@MainActor struct NameRowTests {
  func names() throws -> Names { Names(engine: try Engine(appVersion: "test")) }
  private func defaults(_ values: [String: String] = [:]) -> UserDefaults {
    let name = "names-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    for (k, v) in values { d.set(v, forKey: k) }
    return d
  }

  // MARK: the device's name

  /// The first run rolls a generated name and keeps it at once.
  @Test func aFirstRunRollsAName() throws {
    let n = try names(), d = defaults()
    let name = PlayerName.load(d, names: n)
    #expect(n.valid(.player, name).ok && d.string(forKey: PlayerName.key) == name)
    #expect(PlayerName.load(d, names: n) == name)  // kept
  }

  /// A typed name from before is never shown: replaced on load by a rolled one. The solo
  /// card's old name is dropped unread. A default is not the device's name either.
  @Test func aTypedNameFromBeforeIsReplaced() throws {
    let n = try names()
    for typed in ["Ada", "You", "Player 1", "mighty maple", ""] {
      let d = defaults([PlayerName.key: typed, "solo.name": "Ada"])
      let name = PlayerName.load(d, names: n)
      #expect(name != typed && n.valid(.player, name).ok, "\(typed)")
      #expect(d.string(forKey: PlayerName.key) == name && d.string(forKey: "solo.name") == nil)
    }
    let kept = defaults([PlayerName.key: "Mighty Maple"])
    #expect(PlayerName.load(kept, names: n) == "Mighty Maple")
  }

  /// Only a generated name is kept; anything else leaves the kept one.
  @Test func onlyAGeneratedNameIsKept() throws {
    let n = try names(), d = defaults([PlayerName.key: "Mighty Maple"])
    #expect(PlayerName.store("Lucky Larch", in: d, names: n) == "Lucky Larch")
    #expect(PlayerName.store("Ada", in: d, names: n) == "Lucky Larch")
    #expect(d.string(forKey: PlayerName.key) == "Lucky Larch")
  }

  // MARK: the row

  /// The words VoiceOver reads: the row, SHUFFLE, and each word's stepper with its two
  /// buttons (the design's "Previous first word"). There is no KEEP any more.
  @Test func theRowSpeaksItsWords() throws {
    let row = NameRowModel(names: try names(), kind: .player, text: "Mighty Maple", label: "Your name")
    #expect(row.text == "Mighty Maple" && row.parts.words == ["Mighty", "Maple"] && row.prefix == nil)
    #expect(row.shuffleLabel == "Shuffle your name")
    #expect(row.wordLabel(0) == "Your name, first word" && row.wordLabel(1) == "Your name, second word")
    #expect(row.stepLabel(0, -1) == "Previous first word" && row.stepLabel(1, 1) == "Next second word")
    #expect(row.groupLabel(0) == "First word" && row.groupLabel(1) == "Second word")
    let reel = NameRowModel(names: try names(), kind: .player, text: "Mighty Maple", label: "Name on the reel")
    #expect(reel.shuffleLabel == "Shuffle name on the reel")
    let team = NameRowModel(names: try names(), kind: .team, text: "The Lumberjacks", label: "Team A's name")
    #expect(team.shuffleLabel == "Shuffle Team A's name")
    #expect(team.prefix == "The" && team.parts.words == ["Lumberjacks"])
    #expect(team.wordLabel(0) == "Team A's name, second word")  // "The" is the first
    #expect(team.stepLabel(0, 1) == "Next second word")
  }

  /// No KEEP: the model has no locks, and the app's row draws none (the owner,
  /// 2026-11-21: "KEEP goes from the name row").
  @Test func theRowHasNoKeep() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Sources/KubbRenderer/NameRow.swift").standardized, encoding: .utf8)
    for gone in ["locks", "toggleLock", "lockTitle", "KEPT"] { #expect(!source.contains(gone), "\(gone)") }
    let app = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../ThrowingWood/Settings.swift").standardized, encoding: .utf8)
    for gone in ["KEEP", "KEPT", "Picker(", "Menu {"] { #expect(!app.contains(gone), "Settings.swift keeps \(gone)") }
  }

  /// A word stepped is the engine's next (or previous) word for that slot, the other
  /// word kept, said and passed on; stepping forward then back comes home.
  @Test func aStepMovesOneWordAndKeepsTheOther() throws {
    let n = try names()
    let row = NameRowModel(names: n, kind: .player, text: "Mighty Maple", label: "Your name")
    var changes: [String] = []
    row.onChange = { changes.append($0) }
    let next = try #require(try n.step(.player, row.parts, slot: 1, dir: 1))
    row.step(1, 1)
    #expect(row.text == next.text && row.parts.words[0] == "Mighty" && row.parts.words[1] != "Maple")
    #expect(changes == [next.text] && row.announcement == "Your name: \(next.text)")
    row.step(1, -1)
    #expect(row.text == "Mighty Maple" && changes.count == 2)
    row.step(0, -1)
    #expect(row.parts.words[1] == "Maple" && row.parts.words[0] != "Mighty" && n.valid(.player, row.text).ok)
    row.step(5, 1)  // no such slot: nothing changes
    #expect(changes.count == 3)
  }

  /// SHUFFLE rolls a whole new generated name, each time passed on.
  @Test func shuffleRollsAWholeName() throws {
    let n = try names()
    let row = NameRowModel(names: n, kind: .player, text: "Mighty Maple", label: "Your name")
    var changes: [String] = []
    row.onChange = { changes.append($0) }
    var firsts = Set<String>()
    for _ in 0..<20 {
      row.shuffle()
      #expect(n.valid(.player, row.text).ok)
      firsts.insert(row.parts.words[0])
    }
    #expect(changes.count == 20 && firsts.count > 1)  // no word is held
  }

  /// A name set from elsewhere is shown without being passed on.
  @Test func aNameFromElsewhereIsShownNotPassedOn() throws {
    let row = NameRowModel(names: try names(), kind: .player, text: "Mighty Maple", label: "Your name")
    var changes = 0
    row.onChange = { _ in changes += 1 }
    row.set("Mighty Myrtle")
    #expect(row.text == "Mighty Myrtle" && row.parts.words == ["Mighty", "Myrtle"] && changes == 0)
    row.set("Ada")  // not a name: ignored
    #expect(row.text == "Mighty Myrtle")
  }

  /// A row given a name that is not one starts from a rolled name.
  @Test func aRowNeverShowsATypedName() throws {
    let n = try names()
    let row = NameRowModel(names: n, kind: .player, text: "Ada", label: "Your name")
    #expect(row.text != "Ada" && n.valid(.player, row.text).ok)
  }
}
