/// The match's pace, in one place: how long a throw's result stays still before the
/// match moves on, and how long each kubb lies before an automatic raise stands it.
/// The same on every screen (solo, practice, online): the web's src/game/pacing.js, its
/// names and numbers. Online every browser and the iPhone wait the same, so a watcher's
/// picture keeps up with the thrower's. Kept as they were for the pitch server.
public enum Pacing {
  /// Seconds a played throw rests, everything still, before the next need shows.
  public static let restAfterThrow = 0.8
  /// Seconds each kubb is shown lying before an automatic raise stands it.
  public static let autoRaiseWait = 0.7
}
