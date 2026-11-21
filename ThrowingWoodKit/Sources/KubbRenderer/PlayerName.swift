import Foundation

/// The player's name: one value on the device, typed once and set in Settings (the
/// owner's scopes, 2026-11-20: "Your name", a device setting). A match against the
/// computer and an online pitch both use it; nothing asks for it per game.
///
/// Before 0.5 the solo set-up kept its own (`solo.name`, "You" until changed) and
/// the lobby its own (`pitch.name`). The lobby's key is the device's now; the
/// solo set-up's is read into it once when the lobby never had one.
public enum PlayerName {
  public static let key = "pitch.name"
  static let soloKey = "solo.name"
  /// What a match against the computer calls a player with no name.
  public static let fallback = "You"

  /// The stored name, moved once from the solo set-up's when there is none yet
  /// (its "You" is the fallback, not a name, and is not moved). "" for none.
  public static func load(_ d: UserDefaults) -> String {
    if let v = d.string(forKey: key), !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
    let solo = d.string(forKey: soloKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let v = solo == fallback ? "" : solo
    if !v.isEmpty { d.set(v, forKey: key) }
    return v
  }

  public static func store(_ name: String, in d: UserDefaults) { d.set(name, forKey: key) }

  /// What a set-up screen shows beside the level ("Ada"), or nil with no name.
  public static func shown(_ name: String) -> String? {
    let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}
