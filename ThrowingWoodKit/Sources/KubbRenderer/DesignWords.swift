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
  /// before); with what the thrower aims at when it is not the base kubbs the numbers
  /// show, the web's words (its hud.js headerLine): "Turn 4 · baton 2 of 6 · 2 field
  /// kubbs", "Turn 9 · baton 5 of 6 · at the king" (`at`: the engine's rail, `aimsAt`).
  /// "Watch · turn 4 · baton 2 of 6" while this device only watches and no WATCH tab
  /// says so (an observer's wide view, a raise it watches); where the WATCH tab shows
  /// (the computer's or another player's throw) the line drops "Watch". `n` is the
  /// throw's place in the turn (the engine's `setup.n`, one-based), `of` the turn's
  /// throws.
  /// A computer player's throw ends it with " · computer · pro" (`thrower`: the need's
  /// `setup.thrower`, engine 0.17; SeatWords.headerTail).
  public static func line(
    turn: Int, n: Int?, of: Int?, projectile: String?, watching: Bool, at: String? = nil,
    thrower: MatchNeed.Setup.Player? = nil
  ) -> String {
    var line = watching ? "Watch · turn \(turn)" : "Turn \(turn)"
    if let n, let of {
      line += " · \(projectile == "baton" ? "baton" : "kubb") \(n) of \(of)"
    }
    if let at = aimsAt(at) { line += " · " + at }
    if let tail = SeatWords.headerTail(cpu: thrower?.cpu, level: thrower?.level) { line += tail }
    return line
  }

  /// The header's line while the engine's own raise is watched (engine 0.16.0's
  /// `setup.settled`): "Turn 3 · raise 1 of 2", "Turn 3 · punishment kubb", over the
  /// raising side's name.
  public static func engineRaise(turn: Int, k: Int, of: Int, placed: Bool) -> String {
    placed ? "Turn \(turn) · punishment kubb" : "Turn \(turn) · raise \(k) of \(of)"
  }

  /// What the thrower aims at, from the engine's rail (session.lua aimView `rail.r1`:
  /// "FIELD 2", "BASE 5", "KING"), when it is not the base kubbs the numbers show: "2
  /// field kubbs", "1 field kubb", "at the king"; nil for the base kubbs or nothing.
  public static func aimsAt(_ r1: String?) -> String? {
    guard let r1 else { return nil }
    if r1 == "KING" { return "at the king" }
    let parts = r1.split(separator: " ")
    if parts.count == 2, parts[0] == "FIELD", let n = Int(parts[1]) {
      return "\(n) field \(n == 1 ? "kubb" : "kubbs")"
    }
    return nil
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

/// Counts as words, up to ten, as a sentence says them ("Six batons", "two field
/// kubbs"); past ten, the digits.
public enum CountWords {
  static let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
  public static func word(_ n: Int) -> String { n >= 0 && n < words.count ? words[n] : String(n) }
  /// "six batons", "one field kubb": the count and the noun, singular or plural.
  public static func count(_ n: Int, _ one: String, _ many: String) -> String {
    "\(word(n)) \(n == 1 ? one : many)"
  }
  /// The first letter in capitals.
  public static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

/// The meter's words beyond the engine's prompts: the throw's distance on the inverted
/// tab beside WIND BACK or DRAW BACK (the 1.0 design's "Meter marks and distance"), to
/// the nearest metre, and what VoiceOver says for the prompt and the meter.
public enum MeterWords {
  /// The tab: "8 M" (the engine's plan `dist`, m from the stance to the target, never
  /// under 1), the web's distanceWords; nil where there is no distance.
  public static func distance(_ metres: Double?) -> String? {
    guard let m = metres, m.isFinite, m > 0 else { return nil }
    return "\(max(1, Int(m.rounded()))) M"
  }
  /// Spoken: "8 metres", "1 metre".
  public static func spokenDistance(_ metres: Double?) -> String? {
    guard let m = metres, m.isFinite, m > 0 else { return nil }
    let n = max(1, Int(m.rounded()))
    return "\(n) \(n == 1 ? "metre" : "metres")"
  }
  /// The prompts the tab stands beside (the web's): WIND BACK and FLICK! on the clock,
  /// DRAW BACK and FLING! on the linear meter.
  public static func showsDistance(_ prompt: String?) -> Bool {
    ["WIND BACK", "DRAW BACK", "FLICK!", "FLING!"].contains(prompt ?? "")
  }
  /// The prompt and the distance, spoken together, the web's words: "Wind back, 8
  /// metres", "Flick, 8 metres" (no "!").
  public static func spokenPrompt(_ prompt: String?, metres: Double?) -> String? {
    guard let prompt, !prompt.isEmpty else { return nil }
    let p = CountWords.sentence(prompt.lowercased().replacingOccurrences(of: "!", with: "").trimmingCharacters(in: .whitespaces))
    guard showsDistance(prompt), let d = spokenDistance(metres) else { return p }
    return "\(p), \(d)"
  }
  /// The WATCH tab on the computer's or another player's turn.
  public static let watch = "WATCH"
  /// The meter, spoken (its marks by shape, as the coach names them), the web's words.
  public static func spokenMeter(linear: Bool, watching: Bool) -> String {
    let kind = linear ? "Linear meter" : "Clock meter"
    return watching
      ? "\(kind), shown for watching only."
      : "\(kind). Draw back to the stripes, then flick and let go on the solid mark."
  }
  /// The minimap as one image, the web's words (its hud.js mapSummary): "Map of the
  /// pitch: Mighty Maple 5 kubbs standing, Computer 4. The target is 8 metres out."
  /// In a Kid match it ends with the Kid line: "The Kid line is 2 metres out."
  /// (`kidLine`: m from the thrower's line).
  public static func mapSummary(
    standing: [String: Int]?, teams: [String: String]?, metres: Double?, kidLine: Double? = nil
  ) -> String {
    var text = "Map of the pitch"
    if let a = standing?["A"], let b = standing?["B"] {
      text += ": \(teams?["A"] ?? "Team A") \(a) \(a == 1 ? "kubb" : "kubbs") standing, \(teams?["B"] ?? "Team B") \(b)"
    }
    text += "."
    if let d = spokenDistance(metres) { text += " The target is \(d) out." }
    if let k = kidLine, k > 0 {
      let m = (k * 10).rounded() / 10
      text += " The Kid line is \(m == m.rounded() ? String(Int(m)) : String(m)) \(m == 1 ? "metre" : "metres") out."
    }
    return text
  }
}

/// The verdict after a throw (the 1.0 design's "Verdict: the reason leads"): each off
/// word first, inverted, 18 pt, with an arrow for its direction; the on-target words
/// after it as small chips. Announced once, the off words first.
public enum VerdictWords {
  public enum Arrow: String, Sendable { case down, up, left, right, wavy, clock }
  /// The off word's arrow: down for SHORT and LOW, up for LONG and HIGH, left and right
  /// for PULLED, a wavy line for SHAKY, a clock hand for SLOW.
  public static func arrow(_ word: String) -> Arrow? {
    switch word {
    case "SHORT", "LOW": .down
    case "LONG", "HIGH": .up
    case "PULLED LEFT": .left
    case "PULLED RIGHT": .right
    case "SHAKY": .wavy
    case "SLOW": .clock
    default: nil
    }
  }
  /// What VoiceOver says, once, the web's verdictSpeech: each off word a sentence,
  /// then the flag, then the on-target words ("Short. Miss. Arc on, steady, straight."),
  /// then where it came to rest when the engine says ("50 cm away.").
  public static func spoken(flag: String?, words: [ThrowResult.Verdict], rest: String? = nil) -> String {
    func sentence(_ s: String) -> String {
      var l = s.lowercased()
      while l.hasSuffix("!") { l.removeLast() }
      return CountWords.sentence(l)
    }
    var parts = words.filter(\.offTarget).map { sentence($0.text) + "." }
    if let flag, !flag.isEmpty { parts.append(sentence(flag) + ".") }
    let on = words.filter { !$0.offTarget }.map { $0.text.lowercased() }
    if !on.isEmpty { parts.append(sentence(on.joined(separator: ", ")) + ".") }
    // where it came to rest ("50 CM AWAY"): shown under the verdict, so spoken too
    if let rest, !rest.isEmpty { parts.append(sentence(rest) + ".") }
    return parts.joined(separator: " ")
  }
}

/// A card's rows (the app's `CardScreen` and `FitOrScroll`, through its `FitHeight`
/// layout): one scroll view, as tall as its rows where they fit and as tall as it is
/// offered where they do not. One copy of the rows either way: two copies to choose
/// between (a `ViewThatFits`) swapped when the keyboard took the room, which dropped the
/// focused field and its keyboard (Send feedback, builds 181 to 1.0.0).
public enum FitHeightRule {
  /// The rows' height shown: their own, no more than `offered` (nil: no limit).
  public static func height(ideal: Double, offered: Double?) -> Double {
    guard let offered, offered.isFinite else { return ideal }
    return max(0, min(ideal, offered))
  }
  /// The least a card's rows keep beside its pinned button row: a phone on its side with
  /// the keyboard up leaves a card about 180 pt, where pinned buttons left the rows none
  /// and the field being typed in out of sight.
  public static let rowsRoom: Double = 120
  /// Whether the button row stays pinned under the rows: where it leaves them `rowsRoom`
  /// of the card's inside height `room` (its spacing, 14, between), else it scrolls
  /// with them, under the last.
  public static func pinsButtons(room: Double, buttons: Double) -> Bool {
    !room.isFinite || room - buttons - 14 >= rowsRoom
  }
}

/// The throw to go's words (engine 1.4.0, kubb-engine docs/SESSION.md "The throw to go"):
/// each team throws one baton at the king, the nearer that leaves it standing throws first.
/// The engine's own line (`result.text`) is the game file's; these are the screen's, short
/// and plain. `togoTeams` and `togoViewer` come from the session, never the engine.
public enum TogoWords {
  /// The header's first line while a baton to go is thrown or waited for, and while this
  /// device throws its own (the web's "YOUR THROW TO GO", in the header's sentence case).
  public static let header = "Throw to go"
  public static let yours = "Your throw to go"
  /// Under it while this device's baton is in and another team's is not (the web's
  /// "WAITING FOR <TEAM>", its teams joined by "and").
  public static func waiting(for teams: [String]) -> String { "Waiting for " + teams.joined(separator: " and ") }
  /// The coach's line on the first round: what a baton to go is for.
  public static let hint = "CLOSEST TO THE KING THROWS FIRST"

  static func name(_ r: ThrowResult, _ side: String?) -> String {
    guard let side else { return "" }
    return r.togoTeams?[side] ?? "Team \(side)"
  }

  /// The web's togoWords (src/game/rulings.js): "MIGHTY MAPLE GOES FIRST", "A TIE: THROW
  /// AGAIN", "BOTH HIT THE KING: THROW AGAIN", "THROW AGAIN".
  public static func flag(_ r: ThrowResult) -> String {
    if r.how == "again" || r.first == nil {
      return r.why == "tie" ? "A TIE: THROW AGAIN" : r.why == "both king" ? "BOTH HIT THE KING: THROW AGAIN" : "THROW AGAIN"
    }
    return "\(name(r, r.first).uppercased()) GOES FIRST"
  }

  /// Under it, each team's baton, A then B: "Mighty Maple 0.42 m · Computer hit the king".
  public static func rest(_ r: ThrowResult) -> String? {
    func one(_ side: String) -> String {
      let n = name(r, side)
      guard let b = baton(r, side) else { return n }
      if b.toppled == true { return "\(n) hit the king" }
      guard let g = b.gap ?? b.mm.map({ Double($0) / 1000 }) else { return n }
      return "\(n) \(String(format: "%.2f", g)) m"
    }
    return "\(one("A")) · \(one("B"))"
  }

  static func baton(_ r: ThrowResult, _ side: String) -> ThrowResult.TogoBaton? { side == "A" ? r.A : r.B }
}
