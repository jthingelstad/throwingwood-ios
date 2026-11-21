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
}
