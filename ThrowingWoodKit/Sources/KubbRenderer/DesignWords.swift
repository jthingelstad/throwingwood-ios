import Foundation

// The words of the 1.0 design's shared controls (kubb-sources design, the build list's
// "Shared by every client"), pure so they are tested: the segmented bar's VoiceOver
// words and the header's.

/// The segmented bar (one joined bar for two to four options, the chosen part ink with
/// paper type). VoiceOver reads each part as "Clock, selected, 1 of 2" (the design's
/// words): the choice is its label, and "selected" and where it is in the bar its value,
/// so the words come in that order.
public enum SegmentWords {
  /// The value read after a part's label: "selected, 1 of 2", or "2 of 2".
  public static func value(index: Int, count: Int, selected: Bool) -> String {
    (selected ? "selected, " : "") + "\(index + 1) of \(count)"
  }
  /// The whole of what VoiceOver says for a part: "Clock, selected, 1 of 2".
  public static func spoken(_ label: String, index: Int, count: Int, selected: Bool) -> String {
    "\(label), " + value(index: index, count: count, selected: selected)
  }
}

/// The header over a match (the design's "The header (the rail)"): which turn and which
/// throw, counted the same way everywhere ("Turn 4 · baton 2 of 6", where "2 batons
/// left" was), over the thrower's name in sentence case; the base kubbs standing for
/// each side as two numbers on the team colours, with a spoken label; MENU as a word.
public enum HeaderWords {
  /// "Turn 4 · baton 2 of 6"; an inkast's "Turn 3 · kubb 1 of 4" (as "Kubb 1 of 4" was
  /// before); "Watch · turn 4 · baton 2 of 6"
  /// while this device only watches. `n` is the throw's place in the turn (the engine's
  /// `setup.n`, one-based), `of` the turn's throws.
  public static func line(turn: Int, n: Int?, of: Int?, projectile: String?, watching: Bool) -> String {
    var line = watching ? "Watch · turn \(turn)" : "Turn \(turn)"
    if let n, let of {
      line += " · \(projectile == "baton" ? "baton" : "kubb") \(n) of \(of)"
    }
    return line
  }

  /// What VoiceOver reads for the two numbers, the web's words (its hud.js): "Kubbs
  /// standing: Golden Kubblets 5, Computer 4", a side with no name "Team A".
  public static func counts(a: Int, b: Int, teamA: String?, teamB: String?) -> String {
    "Kubbs standing: \(teamA ?? "Team A") \(a), \(teamB ?? "Team B") \(b)"
  }

  /// MENU, the word inside the header's plate, and what VoiceOver reads for it.
  public static let menu = "MENU"
  public static let menuLabel = "Menu"
}
