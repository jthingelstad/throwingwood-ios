import Foundation

/// Raising without choosing the ends (Jamie, 2026-11-19: "When raising kubbs we
/// have three options today including an auto, we should also add an "auto
/// all". In fact I could see players wanting to shift to auto raise kubbs for
/// the rest of the game."). `always` is the device's setting (menu, Raising:
/// Automatic); `rest` is AUTO ALL on the raise card, for this turn's kubbs.
/// Each kubb is shown lying `gap` seconds before the engine's choice stands it,
/// so each is seen.
public struct AutoRaise: Sendable {
  public static let gap = 0.7
  public var always = false
  public internal(set) var rest = false
  private var key: String?
  private var wait = 0.0

  public init() {}

  public var on: Bool { always || rest }
  /// A kubb is lying and its raise is counting down.
  public var waiting: Bool { on && key != nil && wait > 0 && wait.isFinite }

  /// One display tick. `raising` names the kubb this device may raise now (nil:
  /// no raise of ours, or a card is up). True when it is time to raise it.
  public mutating func tick(_ dt: Double, raising: String?) -> Bool {
    guard let raising else {
      key = nil
      return false
    }
    guard on else { return false }
    if key != raising {
      key = raising
      wait = Self.gap
      return false
    }
    wait -= dt
    return wait <= 0
  }

  /// The engine would not raise it: leave this kubb, and AUTO ALL, to the player.
  public mutating func refused() {
    rest = false
    wait = .infinity
  }

  /// The turn's raising is over: AUTO ALL ends with it.
  public mutating func turnEnded() { rest = false }

  public mutating func raiseRest() {
    rest = true
    key = nil
  }

  public mutating func byHand() {
    always = false
    rest = false
  }
}

extension PitchSession {
  /// The device's setting: raise every kubb automatically.
  public var raiseAutomatically: Bool {
    get { autoRaise.always }
    set {
      autoRaise.always = newValue
      if !newValue { autoRaise.byHand() }
      revision += 1
    }
  }
  /// AUTO ALL is raising this turn's kubbs.
  public var raisingRest: Bool { autoRaise.rest }

  /// This device's raise, with no card over it.
  var raiseIsOurs: Bool {
    acceptsInput && !playing && handoff == nil && need?.kind == "raise" && need?.cpu != true
  }

  /// AUTO ALL: this kubb and the rest of this turn's, by the engine's choice.
  public func raiseRest() {
    guard raiseIsOurs else { return }
    autoRaise.raiseRest()
    revision += 1
  }

  /// BY HAND: back to choosing the ends.
  public func raiseByHand() {
    autoRaise.byHand()
    revision += 1
  }

  func autoRaiseTick(_ dt: Double) throws -> Bool {
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
