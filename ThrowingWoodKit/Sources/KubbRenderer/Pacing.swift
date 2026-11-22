/// The match's pace, in one place: how long a throw's result stays still before the
/// match moves on, how long a watched automatic raise takes a kubb, and how long the
/// verdict stays over the next aim. The same on every screen (solo, practice, online):
/// the web's src/game/pacing.js, its names and numbers. Online every browser and the
/// iPhone wait the same, so a watcher's picture keeps up with the thrower's.
public enum Pacing {
  /// Seconds a played throw rests, everything still, before the next need shows.
  public static let restAfterThrow = 0.8
  /// Seconds the first kubb of a turn's automatic raise lies on the raise view before it
  /// tips (the web's autoRaiseWait; 0.7 for every kubb before raises were watched).
  public static let autoRaiseWait = 0.4
  /// Seconds a watched raise takes a kubb (its tip and a moment standing), at most: the
  /// owner, 2026-11-22, "When you hit auto to raise kubbs you should watch the computer
  /// raise them." (the web's lift.js beat).
  public static let autoRaiseStep = 0.5
  /// Seconds a whole watched raise takes at most, the first kubb's lying included; and a
  /// kubb's beat at least, however many there are.
  public static let autoRaiseMost = 4.0, autoRaiseLeast = 0.18
  /// Seconds the verdict stays over the next aim when the player does nothing (it goes at
  /// the first press of the aim): long enough to read a flag and four words. 6 before.
  public static let verdictShown = 3.5

  /// One kubb's beat in a watched raise of `count` kubbs: half a second, quicker when there
  /// are more than seven so the lying and every kubb take four seconds at most, never
  /// under 0.18 (the web's liftPace).
  public static func raiseBeat(_ count: Int) -> Double {
    max(autoRaiseLeast, min(autoRaiseStep, (autoRaiseMost - autoRaiseWait) / Double(max(1, count))))
  }
}
