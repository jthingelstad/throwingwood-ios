/// The match's pace, in one place: how long a throw's result stays still before the
/// match moves on, how long a watched automatic raise takes a kubb, and how long the
/// verdict stays over the next aim. The same on every screen (solo, practice, online):
/// the web's src/game/pacing.js, its names and numbers. Online every browser and the
/// iPhone wait the same, so a watcher's picture keeps up with the thrower's.
public enum Pacing {
  /// Seconds a played throw rests, everything still, before the next need shows.
  public static let restAfterThrow = 0.8
  /// Seconds a watched automatic raise takes a kubb (lying, tipping up, standing:
  /// RaiseShow.parts), at most: the owner, 2026-11-22, "When you hit auto to raise kubbs
  /// you should watch the computer raise them." Before, each kubb lay 0.7 s and stood at
  /// once.
  public static let autoRaiseStep = 0.5
  /// Seconds a whole watched raise takes at most: with many kubbs each is quicker.
  public static let autoRaiseMost = 4.0
  /// Seconds the verdict stays over the next aim when the player does nothing (it goes at
  /// the first press of the aim): long enough to read a flag and four words. 6 before.
  public static let verdictShown = 3.5

  /// One kubb's step of a watched raise of `count` kubbs: half a second, quicker when there
  /// are more than eight so the whole never passes four seconds.
  public static func raiseStep(_ count: Int) -> Double {
    min(autoRaiseStep, autoRaiseMost / Double(max(1, count)))
  }
}
