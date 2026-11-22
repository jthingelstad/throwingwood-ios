import Foundation
import KubbPitch

/// The player's name: one value on the device (the owner's scopes, 2026-11-20: "Your
/// name", a device setting), and a generated one (kubb-engine docs/NAMES.md; the owner,
/// 2026-11-21: no typed name anywhere). The first run rolls one, with a seed from the
/// system's random source, and keeps its text; the name row (`NameRowModel`) in
/// Settings, the solo card, the lobby and the share card changes it. The web's
/// src/game/player-name.js.
///
/// A name kept from before is typed text. It is never shown: on load, a kept text that
/// is not a generated player name (`names.valid`'s `ok`; a default such as "Player 1"
/// is not one) is replaced by a rolled name, kept at once. The solo card's old
/// `solo.name` is dropped unread.
public enum PlayerName {
  public static let key = "pitch.name"
  static let soloKey = "solo.name"

  /// The device's name: the kept one while it is a generated player name, else a new
  /// one rolled and kept (the first run, or a typed name from before, none of whose
  /// words are kept: it is typed text, and none of it is shown).
  @MainActor public static func load(_ d: UserDefaults, names: Names) -> String {
    d.removeObject(forKey: soloKey)
    if let kept = d.string(forKey: key), names.valid(.player, kept).ok { return kept }
    let text = (try? names.roll(.player))?.text ?? Names.playerDefault(1)
    d.set(text, forKey: key)
    return text
  }

  /// Keeps a generated name on the device; anything else is refused (the kept name
  /// stays). Returns the name kept.
  @MainActor @discardableResult public static func store(_ name: String, in d: UserDefaults, names: Names) -> String {
    guard names.valid(.player, name).ok else { return load(d, names: names) }
    d.set(name, forKey: key)
    d.removeObject(forKey: soloKey)
    return name
  }
}
