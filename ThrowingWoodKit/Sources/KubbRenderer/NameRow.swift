import Foundation
import KubbPitch
import Observation

/// The name row's state (the web's src/ui/name-row.js; kubb-engine docs/NAMES.md section
/// 8; the owner, 2026-11-21: no typed name anywhere): one control for a generated name,
/// used wherever a name is chosen: Settings, the solo card's and the lobby's You row,
/// the host's team names in the lobby and the share card. The app's `NameRowView` draws
/// it with native controls, in this order: the name and SHUFFLE, then each word's
/// picker (every word the slot can take, `names.choices`) and its KEEP.
///
/// SHUFFLE rolls a new name keeping the kept words (`names.roll` with `keep`); a team's
/// SHUFFLE may change its shape unless a word is kept. A team's "The" is text, not a
/// slot. The words VoiceOver reads are here, so they are the web's and tested.
@MainActor @Observable public final class NameRowModel {
  public let kind: NameKind
  /// The row's name for VoiceOver: "Your name", "Name on the reel", "Team A's name".
  public let label: String
  public private(set) var text: String
  public private(set) var parts: NameParts
  /// Which words are kept when shuffling, by slot.
  public private(set) var locks: [Bool]
  /// What VoiceOver announces after a change: "Your name: Mighty Maple".
  public private(set) var announcement: String?
  /// Called with the new name after SHUFFLE or a word picked (never after `set`).
  public var onChange: ((String) -> Void)?
  @ObservationIgnored private let names: Names

  public init(names: Names, kind: NameKind, text: String, label: String) {
    self.names = names
    self.kind = kind
    self.label = label
    let parts = names.valid(kind, text).parts ?? (try? names.roll(kind))?.parts ?? NameParts(shape: "adj", words: [])
    self.parts = parts
    self.text = (try? names.make(kind, parts)) ?? text
    locks = Array(repeating: false, count: parts.words.count)
  }

  /// The literal first word of the shape ("The"), shown as text before the pickers.
  public var prefix: String? { names.prefix(kind, shape: parts.shape) }

  /// Every word `slot` can take with the other words as they are.
  public func choices(_ slot: Int) -> [String] { (try? names.choices(kind, parts, slot: slot)) ?? [parts.words[slot]] }

  // MARK: - VoiceOver (the web's aria labels)

  /// "Shuffle your name", "Shuffle name on the reel", "Shuffle Team A's name".
  public var shuffleLabel: String {
    "Shuffle " + (label.hasPrefix("Team ") ? label : label.prefix(1).lowercased() + label.dropFirst())
  }
  /// "Your name, first word"; a team's "The ___" counts its "The" first.
  public func pickerLabel(_ slot: Int) -> String {
    let ordinals = ["first", "second", "third"]
    let n = prefix == nil ? slot : slot + 1
    return "\(label), \(n < ordinals.count ? ordinals[n] : "word \(n + 1)") word"
  }
  /// "Keep Mighty when shuffling".
  public func lockLabel(_ slot: Int) -> String { "Keep \(parts.words[slot]) when shuffling" }
  /// KEEP, or KEPT when on.
  public func lockTitle(_ slot: Int) -> String { locks[slot] ? "KEPT" : "KEEP" }

  // MARK: - Changes

  /// A word picked for a slot. Nothing changes when the words make no name.
  public func pick(_ slot: Int, _ word: String) {
    guard parts.words.indices.contains(slot), word != parts.words[slot] else { return }
    var next = parts
    next.words[slot] = word
    guard let t = try? names.make(kind, next) else { return }
    parts = next
    changed(t)
  }

  public func toggleLock(_ slot: Int) {
    guard locks.indices.contains(slot) else { return }
    locks[slot].toggle()
  }

  /// SHUFFLE: a new name keeping the kept words.
  public func shuffle() {
    let held: [String?] = parts.words.indices.map { locks[$0] ? parts.words[$0] : nil }
    let keep = held.contains { $0 != nil } ? (shape: parts.shape, words: held) : nil
    guard let r = try? names.roll(kind, keep: keep) else { return }
    parts = r.parts
    locks = r.parts.words.indices.map { $0 < held.count && held[$0] != nil && held[$0] == r.parts.words[$0] }
    changed(r.text)
  }

  /// Another name shown (a change made elsewhere, or by the room); locks stay where the
  /// word is still in its place. Not announced, and `onChange` is not called.
  public func set(_ t: String) {
    guard t != text, let p = names.valid(kind, t).parts else { return }
    let old = parts
    parts = p
    locks = p.words.indices.map { i in
      i < locks.count && locks[i] && old.shape == p.shape && old.words[i] == p.words[i]
    }
    text = t
  }

  private func changed(_ t: String) {
    text = t
    announcement = "\(label): \(t)"
    onChange?(t)
  }
}
