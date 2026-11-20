import Foundation

/// The player's own throw level (Beginner, Club or Pro): one value on the device,
/// set in Settings, never asked per game (Jamie, 2026-11-20: "Yes this is a
/// device/user setting... not a per game setting."). Practice, a match against
/// the computer and an online pitch all throw at it. The computer's level is a
/// different thing: it stays the solo set-up's per-game choice.
///
/// The engine reads a thrower's level for each throw (session.lua: every throw
/// takes the thrower's level from the match, and `setLevel` changes the one in
/// hand), and a throw action carries its launch, not the level. So a change
/// applies from the player's next throw; the match keeps the levels it started
/// with in its record.
public enum ThrowLevel {
  public static let key = "pitch.throwLevel"
  /// First run: today's default.
  public static let fallback = "club"

  /// The stored level, moved once from the older per-mode values when there is
  /// none yet. Those had no dates, so the most recent own throws are taken as:
  /// a level changed in the kept solo match's menu (`solo.matchLevel`), then the
  /// solo set-up's level when a solo match is in progress (its throws were the
  /// last), then the online lobby's (`pitch.level`, the player's alone), then
  /// the solo set-up's. The older keys are left as they are; the solo set-up's
  /// stays the computer's level.
  public static func load(_ d: UserDefaults, choices: [String], soloInProgress: Bool) -> String {
    if let v = d.string(forKey: key), choices.contains(v) { return v }
    let solo = d.string(forKey: "solo.option.level")
    let older = [
      d.string(forKey: "solo.matchLevel"), soloInProgress ? solo : nil,
      d.string(forKey: "pitch.level"), solo,
    ]
    let v = older.compactMap { $0 }.first(where: choices.contains) ?? fallback
    d.set(v, forKey: key)
    return v
  }

  public static func store(_ level: String, in d: UserDefaults) { d.set(level, forKey: key) }

  /// What a set-up screen shows instead of a picker.
  public static func line(_ level: String) -> String {
    "Throwing at \(level.capitalized)."
  }
}
