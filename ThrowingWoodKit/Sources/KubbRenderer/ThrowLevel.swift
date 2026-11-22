import Foundation

/// The player's kept throw level (Beginner, Club or Pro): one value on the device.
/// No screen sets it any more (2026-11-21). From kubb-engine 0.13 a level is the
/// computer's standard only and every person throws on one meter (its
/// docs/notes/throw.md "The person's meter"), so on 0.13 it changes nothing in a
/// person's throw. It is kept and still passed (a solo match's player entry,
/// practice's and a throw's `setLevel`, the pitch member's `level`) because the
/// engine still takes those fields, and because a match on a carried engine before
/// 0.13 (0.9, 0.8, 0.7: a kept solo match, a pitch with a peer on 0.9) plans a
/// person's throw at it, as it did when it was set. The computer's level is a
/// different thing: the solo set-up's and the lobby's per-game choice.
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
}
