/// The hand-off card's words for a watcher: a device with no side in the match (an
/// observer, a member who watches instead). The engine's `baseText` ("YOUR BASE 4",
/// "THEIRS 5") speaks to the team the card goes to, so a watcher gets each team by name
/// with its standing base kubbs from the card's `base` ({ from's, to's }): "NORTH BASE 5",
/// "SOUTH BASE 4", the far team first. The web's src/ui/handoff-words.js. Pure.
public enum HandoffWords {
  /// The bases line for a watcher, or [] when the card carries no bases.
  public static func watcherBases(_ c: MatchNeed.Handoff, teams: [String: String]? = nil) -> [String] {
    guard let base = c.base, base.count >= 2 else { return [] }
    let to = c.to == "B" ? "B" : "A"
    let from = c.from ?? (to == "A" ? "B" : "A")
    func name(_ side: String, _ own: String?) -> String {
      (teams?[side].flatMap { $0.isEmpty ? nil : $0 } ?? own.flatMap { $0.isEmpty ? nil : $0 } ?? "Team \(side)")
        .uppercased()
    }
    return ["\(name(from, c.fromName)) BASE \(base[0])", "\(name(to, c.toName)) BASE \(base[1])"]
  }

  /// What the turn throws, for the team the card goes to ("Throw 2 kubbs in, then 6
  /// batons.") or for a watcher ("2 kubbs in, then 6 batons.", "They throw 6 batons.").
  public static func throwLine(_ c: MatchNeed.Handoff, watcher: Bool) -> String {
    if c.kubbs > 0 {
      // the players' words are as before; a watcher's are the web's ("1 kubb in")
      return watcher
        ? "\(c.kubbs) \(c.kubbs == 1 ? "kubb" : "kubbs") in, then \(c.batons) batons."
        : "Throw \(c.kubbs) kubbs in, then \(c.batons) batons."
    }
    return watcher ? "They throw \(c.batons) batons." : "Throw \(c.batons) batons."
  }

  /// The hand-off card's title: "Your turn" for this device's own turn, else the
  /// team's, the web's words (its handoff-words.js handoffTitle): "Lucky Larch’s
  /// turn", "Golden Kubblets’ turn", "Their turn" with no name.
  public static func title(_ c: MatchNeed.Handoff, own: Bool) -> String {
    title(name: c.toName, own: own)
  }
  public static func title(name: String, own: Bool) -> String {
    if own { return "Your turn" }
    let n = name.trimmingCharacters(in: .whitespaces)
    if n.isEmpty { return "Their turn" }
    return n + (n.lowercased().hasSuffix("s") ? "’" : "’s") + " turn"
  }

  /// The hand-off card's one line (the owner's decision, 2026-11-22): what the thrower
  /// faces, from the engine's own state, in plain words. A turn of batons: "Six batons.
  /// Two field kubbs to clear first." (the rail's FIELD n), "Six batons. Aim for the
  /// base kubbs." (no field kubb standing), "Six batons. Go for the king." (every base
  /// kubb of the other side down: the rail's KING); an inkast: "Throw three kubbs into
  /// the other half."; a raise by hand: "Stand your kubbs up." Counts are words up to
  /// ten. `at`: the engine's rail (`rail.r1`) for the turn's first throw.
  public static func line(batons: Int, kubbs: Int, at: String?, raise: Bool = false) -> String {
    if raise { return "Stand your kubbs up." }
    if kubbs > 0 {
      return "Throw \(CountWords.count(kubbs, "kubb", "kubbs")) into the other half."
    }
    let first = CountWords.sentence(CountWords.count(batons, "baton", "batons")) + "."
    if at == "KING" { return first + " Go for the king." }
    let parts = (at ?? "").split(separator: " ")
    if parts.count == 2, parts[0] == "FIELD", let n = Int(parts[1]), n > 0 {
      return first + " " + CountWords.sentence(CountWords.count(n, "field kubb", "field kubbs")) + " to clear first."
    }
    return first + " Aim for the base kubbs."
  }

  /// A Kid match's kicker over the hand-off card's title (engine 0.15's `need.kid`, the
  /// web's handoff-words.js KID_LINES): every kubb and every baton at a kubb is thrown
  /// from the Kid line, which the pitch marks with a cone at each end, and the king shot
  /// from the baseline. Nothing here speaks of a punishment or a loss: a Kid match has
  /// none. nil in a match that is not a Kid match.
  public static let kidLines = (
    cones: "Kid match · throw from the cones", king: "Kid match · the king from your line", plain: "Kid match"
  )
  public static func kid(_ need: MatchNeed?) -> String? {
    guard let need, need.kid == true else { return nil }
    guard need.kind == "throw", let setup = need.setup else { return kidLines.plain }
    return setup.kingShot == true ? kidLines.king : kidLines.cones
  }

  /// The line for a hand-off card, from the card and the rail.
  public static func line(_ c: MatchNeed.Handoff, at: String?) -> String {
    line(batons: c.batons, kubbs: c.kubbs, at: at)
  }
}

