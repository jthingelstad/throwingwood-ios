import Foundation
import KubbPitch
import Observation

/// The name row's state (the web's src/ui/name-row.js; kubb-engine docs/NAMES.md section
/// 8; the owner, 2026-11-21: no typed name anywhere): one control for a generated name,
/// used wherever a name is chosen: Settings, the solo card's and the lobby's You row,
/// the host's team names in the lobby and the share card.
///
/// The 1.0 design: the row is the name and SHUFFLE on one line everywhere; Settings adds
/// a stepper per word (previous, the word, next: the engine's `names.step`, the
/// Playdate's crank made a control). There is no KEEP (the owner, 2026-11-21: "KEEP goes
/// from the name row"): stepping one word already keeps the others, and SHUFFLE rolls a
/// whole new name. A team's "The" is text, not a slot. The words VoiceOver reads are
/// here, so they are tested.
@MainActor @Observable public final class NameRowModel {
  public let kind: NameKind
  /// The row's name for VoiceOver: "Your name", "Name on the reel", "Team A's name".
  public let label: String
  public private(set) var text: String
  public private(set) var parts: NameParts
  /// What VoiceOver announces after a change: "Your name: Mighty Maple".
  public private(set) var announcement: String?
  /// Called with the new name after SHUFFLE or a word stepped (never after `set`).
  public var onChange: ((String) -> Void)?
  @ObservationIgnored private let names: Names

  public init(names: Names, kind: NameKind, text: String, label: String) {
    self.names = names
    self.kind = kind
    self.label = label
    let parts = names.valid(kind, text).parts ?? (try? names.roll(kind))?.parts ?? NameParts(shape: "adj", words: [])
    self.parts = parts
    self.text = (try? names.make(kind, parts)) ?? text
  }

  /// The literal first word of the shape ("The"), shown as text before the steppers.
  public var prefix: String? { names.prefix(kind, shape: parts.shape) }

  // MARK: - VoiceOver

  /// "Shuffle your name", "Shuffle name on the reel", "Shuffle Team A's name".
  public var shuffleLabel: String {
    "Shuffle " + (label.hasPrefix("Team ") ? label : label.prefix(1).lowercased() + label.dropFirst())
  }
  /// "first", "second": a team's "The ___" counts its "The" first.
  private func ordinal(_ slot: Int) -> String {
    let ordinals = ["first", "second", "third"]
    let n = prefix == nil ? slot : slot + 1
    return n < ordinals.count ? ordinals[n] : "word \(n + 1)"
  }
  /// A word's stepper, read as one element with the word as its value: "Your name,
  /// first word".
  public func wordLabel(_ slot: Int) -> String { "\(label), \(ordinal(slot)) word" }
  /// The stepper's group: "First word" (the web's name-row.js).
  public func groupLabel(_ slot: Int) -> String {
    let o = ordinal(slot)
    return o.prefix(1).uppercased() + o.dropFirst() + " word"
  }
  /// Its two buttons: "Previous first word", "Next first word" (the design's labels).
  public func stepLabel(_ slot: Int, _ dir: Int) -> String {
    "\(dir < 0 ? "Previous" : "Next") \(ordinal(slot)) word"
  }

  // MARK: - Changes

  /// The next word in `slot` (`dir` 1) or the one before (-1) that makes a name with
  /// the others, round the list (`names.step`). Nothing changes when no other fits.
  public func step(_ slot: Int, _ dir: Int) {
    guard parts.words.indices.contains(slot),
      let r = try? names.step(kind, parts, slot: slot, dir: dir < 0 ? -1 : 1), r.parts != parts
    else { return }
    parts = r.parts
    changed(r.text)
  }

  /// SHUFFLE: a whole new name.
  public func shuffle() {
    guard let r = try? names.roll(kind) else { return }
    parts = r.parts
    changed(r.text)
  }

  /// Another name shown (a change made elsewhere, or by the room). Not announced, and
  /// `onChange` is not called.
  public func set(_ t: String) {
    guard t != text, let p = names.valid(kind, t).parts else { return }
    parts = p
    text = t
  }

  private func changed(_ t: String) {
    text = t
    announcement = "\(label): \(t)"
    onChange?(t)
  }
}
