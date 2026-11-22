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

  /// The words VoiceOver reads are the web's.
  @Test func theRowSpeaksTheWebsWords() throws {
    let row = NameRowModel(names: try names(), kind: .player, text: "Mighty Maple", label: "Your name")
    #expect(row.text == "Mighty Maple" && row.parts.words == ["Mighty", "Maple"] && row.prefix == nil)
    #expect(row.shuffleLabel == "Shuffle your name")
    #expect(row.pickerLabel(0) == "Your name, first word" && row.pickerLabel(1) == "Your name, second word")
    #expect(row.lockLabel(0) == "Keep Mighty when shuffling" && row.lockTitle(0) == "KEEP")
    row.toggleLock(0)
    #expect(row.lockTitle(0) == "KEPT")
    let reel = NameRowModel(names: try names(), kind: .player, text: "Mighty Maple", label: "Name on the reel")
    #expect(reel.shuffleLabel == "Shuffle name on the reel")
    let team = NameRowModel(names: try names(), kind: .team, text: "The Lumberjacks", label: "Team A's name")
    #expect(team.shuffleLabel == "Shuffle Team A's name")
    #expect(team.prefix == "The" && team.parts.words == ["Lumberjacks"])
    #expect(team.pickerLabel(0) == "Team A's name, second word")  // "The" is the first
  }

  /// A word picked is a new name, said and passed on; SHUFFLE keeps the kept words.
  @Test func pickAndShuffleKeepTheKeptWords() throws {
    let row = NameRowModel(names: try names(), kind: .player, text: "Mighty Maple", label: "Your name")
    var changes: [String] = []
    row.onChange = { changes.append($0) }
    let words = row.choices(1)
    #expect(words.contains("Maple") && words.count > 1)
    let other = try #require(words.first { $0 != "Maple" })
    row.pick(1, other)
    #expect(row.text == "Mighty \(other)" && changes == ["Mighty \(other)"])
    #expect(row.announcement == "Your name: Mighty \(other)")
    row.pick(1, "Nonsense")  // not a word of the slot: nothing changes
    #expect(row.text == "Mighty \(other)" && changes.count == 1)
    row.toggleLock(0)
    for _ in 0..<20 {
      row.shuffle()
      #expect(row.parts.words[0] == "Mighty" && row.locks[0] && !row.locks[1])
    }
    #expect(changes.count == 21)
  }

  /// A name set from elsewhere is shown without being passed on, and a lock stays only
  /// where its word is still in place.
  @Test func aNameFromElsewhereKeepsLocksInPlace() throws {
    let row = NameRowModel(names: try names(), kind: .player, text: "Mighty Maple", label: "Your name")
    var changes = 0
    row.onChange = { _ in changes += 1 }
    row.toggleLock(0)
    row.toggleLock(1)
    row.set("Mighty Myrtle")
    #expect(row.text == "Mighty Myrtle" && row.locks == [true, false] && changes == 0)
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
