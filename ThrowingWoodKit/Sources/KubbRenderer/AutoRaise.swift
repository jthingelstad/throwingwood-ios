import Foundation

/// Automatic raising, the player's choice while a match raises by hand (Jamie,
/// 2026-11-19: "When raising kubbs we have three options today including an auto,
/// we should also add an "auto all". In fact I could see players wanting to shift
/// to auto raise kubbs for the rest of the game."). A port of the web's
/// src/game/auto-raise.js: AUTO ALL on the raise panel (`turn`) stands the rest of
/// this turn's kubbs on the engine's choice of end, and the menu's Raising (or
/// REST OF GAME on the panel) does it for the rest of the match (`game`). Nothing
/// is kept on the device: a match that should always raise itself is the match's
/// own Raising option. Each kubb is shown lying `gap` seconds before it stands.
public struct AutoRaise: Sendable {
  public static let gap = Pacing.autoRaiseWait
  /// For the rest of this match.
  public internal(set) var game = false
  /// For the rest of this turn's kubbs (AUTO ALL).
  public internal(set) var turn = false
  /// This device has been asked to raise in this match: the menu shows its Raising
  /// row from then on.
  public internal(set) var seen = false
  private var key: String?
  private var wait = 0.0

  public init() {}

  public var on: Bool { game || turn }
  /// A kubb is lying and its raise is counting down.
  public var waiting: Bool { on && key != nil && wait > 0 && wait.isFinite }

  /// One display tick. `raising` names the kubb this device may raise now (nil:
  /// no raise of ours, or a card is up). True when it is time to raise it.
  public mutating func tick(_ dt: Double, raising: String?) -> Bool {
    guard let raising else {
      key = nil
      return false
    }
    seen = true
    guard on else { return false }
    if key != raising {
      key = raising
      wait = Self.gap
      return false
    }
    wait -= dt
    guard wait <= 0 else { return false }
    wait = .infinity
    return true
  }

  /// The menu's Raising, and BY HAND / REST OF GAME on the panel.
  public mutating func setGame(_ value: Bool) {
    game = value
    if !value { turn = false }
    key = nil
  }

  /// AUTO ALL.
  public mutating func restOfTurn() {
    turn = true
    key = nil
  }

  /// The engine would not raise it: back to the player.
  public mutating func refused() {
    game = false
    turn = false
  }

  /// The turn's raising is over: AUTO ALL ends with it.
  public mutating func turnEnded() { turn = false }
}

extension PitchSession {
  /// The menu's Raising for this match: every kubb of this device's raised by the
  /// engine's choice, until BY HAND or the match ends.
  public var raiseAutomatically: Bool {
    get { autoRaise.game }
    set {
      autoRaise.setGame(newValue)
      revision += 1
    }
  }
  /// AUTO ALL is raising this turn's kubbs.
  public var raisingRest: Bool { autoRaise.turn }
  /// This device has been asked to raise in this match (or chose Automatic).
  public var raiseSeen: Bool { autoRaise.seen || autoRaise.game }

  /// This device's raise, with no card over it.
  var raiseIsOurs: Bool {
    acceptsInput && !playing && handoff == nil && need?.kind == "raise" && need?.cpu != true
  }

  /// AUTO ALL: this kubb and the rest of this turn's, by the engine's choice.
  public func raiseRest() {
    guard raiseIsOurs else { return }
    autoRaise.restOfTurn()
    revision += 1
  }

  /// BY HAND: back to choosing the ends.
  public func raiseByHand() {
    autoRaise.setGame(false)
    revision += 1
  }

  func autoRaiseTick(_ dt: Double) throws -> Bool {
    if need?.kind == "over" {
      autoRaise = AutoRaise()
      return false
    }
    if need?.kind != "raise" { autoRaise.turnEnded() }
    let raising = raiseIsOurs ? "\(need?.turn ?? 0):\(need?.kubb ?? ""):\(need?.n ?? 0)" : nil
    guard autoRaise.tick(dt, raising: raising) else { return false }
    if try !raise() {
      autoRaise.refused()
      revision += 1
    }
    return true
  }
}
