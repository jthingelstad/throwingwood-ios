import Foundation

/// A person's throw (engine 1.3, kubb-engine docs/notes/throw.md "The person's meter"):
/// Easy, Standard or Hard, the width of the meter's bars, never a hidden miss (the owner,
/// 2026-11-26: what you do shows). Chosen wherever a person throws (the solo card, the
/// practice menu, the lobby's You row) and kept on the device (`pitch.throw`). Standard is
/// the default and goes on no player entry; online it is the member's `me.throw`.
public enum ThrowChoice {
  public static let key = "pitch.throw"
  /// The row's label, the web's.
  public static let label = "Throw"
  public static let standard = "standard"
  /// The engine's ids (`THROW_LEVELS`) and their words.
  public static let choices: [(id: String, name: String)] = [
    ("easy", "Easy"), ("standard", "Standard"), ("hard", "Hard"),
  ]

  /// The kept choice, Standard when none or one this build does not know.
  public static func load(_ defaults: UserDefaults) -> String {
    let v = defaults.string(forKey: key) ?? standard
    return choices.contains { $0.id == v } ? v : standard
  }
  public static func keep(_ v: String, in defaults: UserDefaults) {
    guard choices.contains(where: { $0.id == v }) else { return }
    defaults.set(v, forKey: key)
  }
  /// What a player entry or a practice carries: nil for Standard (the engine's absent).
  public static func sent(_ v: String?) -> String? {
    guard let v, v != standard, choices.contains(where: { $0.id == v }) else { return nil }
    return v
  }
  /// "Easy", "Standard", "Hard": a value the engine does not know reads as Standard.
  public static func name(_ v: String?) -> String {
    choices.first { $0.id == v }?.name ?? "Standard"
  }
}
