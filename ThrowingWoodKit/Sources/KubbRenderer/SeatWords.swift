import Foundation

/// Computer seats' words (engine 0.17, kubb-engine docs/PITCH.md "Computer seats"), the
/// web's (its src/ui/lobby.js and docs/SYSTEM.md "Computer seats"): the lobby's seat rows,
/// what VoiceOver says of them, the Computer row beside them and the match's lines for a
/// computer player's throw.
public enum SeatWords {
  /// A level as shown: the engine's words (its Computer row's labels).
  public static func level(_ id: String?) -> String {
    switch id {
    case "kid": "Kid"
    case "beginner": "Beginner"
    case "club": "Club"
    case "pro": "Pro"
    default: id ?? ""
    }
  }
  /// The levels a seat may have, in the bar's order (the engine's `SEAT_LEVELS`).
  public static let seatLevels = ["beginner", "club", "pro"]
  public static func team(_ side: String) -> String { "Team \(side)" }

  /// Everyone else's row: "Bold Birch · computer · Pro".
  public static func line(_ name: String, _ level: String) -> String {
    "\(name) · computer · \(Self.level(level))"
  }
  /// The host's row's head after the name.
  public static let computerTag = " · computer"
  /// The row read as one thing: "Bold Birch, computer, Pro, 2 of 3 in Team A".
  public static func spoken(_ name: String, _ level: String, place: Int, of: Int, side: String) -> String {
    "\(name), computer, \(Self.level(level)), \(place) of \(of) in \(team(side))"
  }
  /// The host's controls, spoken.
  public static func levelLabel(_ name: String) -> String { "\(name)'s level" }
  public static func upLabel(_ name: String) -> String { "Move \(name) up" }
  public static func downLabel(_ name: String) -> String { "Move \(name) down" }
  public static func acrossLabel(_ name: String, to side: String) -> String { "Move \(name) to \(team(side))" }
  public static func removeLabel(_ name: String) -> String { "Remove \(name)" }
  public static func addLabel(_ side: String) -> String { "Add a computer player to \(team(side))" }
  public static let add = "ADD COMPUTER"
  public static let remove = "REMOVE"
  public static func across(_ side: String) -> String { "TO \(side)" }

  /// What a change the host makes says, once, to VoiceOver.
  public enum Change: Equatable {
    case add(side: String, level: String), level(String), up, down, across(String), remove
  }
  public static func says(_ name: String, _ change: Change) -> String {
    switch change {
    case .add(let side, let level): "\(name) joins \(team(side)) at \(Self.level(level))."
    case .level(let level): "\(name) now plays at \(Self.level(level))."
    case .up: "\(name) moves up."
    case .down: "\(name) moves down."
    case .across(let side): "\(name) moves to \(team(side))."
    case .remove: "\(name) is off the team."
    }
  }

  /// A Kid pitch: every computer plays as Kid, whatever its seat says.
  public static let kidNote = "Kid match: every computer plays as Kid."

  /// The Computer row beside seats: the level of the computer on an empty side while a
  /// side has nobody and no seat; with no empty side and a seat on the pitch, a Kid match
  /// switch; else no row (no computer plays).
  public enum ComputerRow: Equatable { case empty, kid }
  public static func computerRow(emptySide: Bool, anySeat: Bool) -> ComputerRow? {
    emptySide ? .empty : anySeat ? .kid : nil
  }
  public static func label(_ row: ComputerRow) -> String {
    row == .empty ? "An empty side plays as" : "Kid match"
  }
  /// The Kid match switch's parts: On is the Computer setting Kid, Off sets it back to Club.
  public static let kidSwitch = [("off", "Off"), ("on", "On")]
  public static func kidValue(on: Bool) -> String { on ? "kid" : "club" }

  /// A side's head count, people and seats together: "3 of 6".
  public static func count(_ n: Int, of max: Int) -> String { "\(n) of \(max)" }
  /// An empty side's line.
  public static func emptySide(otherHasPlayers: Bool) -> String {
    otherHasPlayers ? "The computer plays this side." : "Nobody yet."
  }

  // MARK: - In the match

  /// The header line's end while a computer player throws (`need.setup.thrower.cpu` and
  /// `.level`): " · computer · pro", as the web's hud.js writes the line (lower case after
  /// its first word).
  public static func headerTail(cpu: Bool?, level: String?) -> String? {
    guard cpu == true else { return nil }
    return " · computer" + (level.map { " · " + Self.level($0).lowercased() } ?? "")
  }
  /// The thrower's line for a computer player's throw: "Bold Birch throws". (A side the
  /// computer plays whole still says "Computer throws".)
  public static func throwing(_ name: String) -> String { "\(name) throws" }
  /// The hand-off's second line when the turn opens with a computer player (the engine's
  /// `card.handoff.throwerCpu`, `throwerLevel`): "Bold Birch throws first · computer · Pro".
  public static func handoffFirst(thrower: String?, cpu: Bool?, level: String?) -> String? {
    guard cpu == true, let thrower, !thrower.isEmpty else { return nil }
    let l = level.map(Self.level) ?? ""
    return "\(thrower) throws first · computer" + (l.isEmpty ? "" : " · \(l)")
  }
}
