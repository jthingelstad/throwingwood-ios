import Foundation

/// What a watched raise is, for everything that must treat it as busy, and what each kind
/// allows, in one place (docs/ONLINE.md "A watched raise online"; Codex on PR #46, three
/// times). The board shows a raise need while the engine may already be past it, so new
/// input waits; but the actions this device scheduled itself keep the authority they were
/// scheduled with until they are sent, or are dropped before being applied if that
/// authority is lost.
public enum RaiseWatch: Equatable, Sendable {
  /// Nothing watched.
  case none
  /// This device's own automatic raise, its kubb still lying: its action is scheduled and
  /// not yet applied or sent.
  case ownLeadIn
  /// This device's own automatic raise after its action was applied and sent: the kubb
  /// tipping up, then standing.
  case ownTipping
  /// Another member's raise, arriving online, already applied: tipping up at the sender's
  /// pace.
  case arriving
  /// A raise the engine made itself (engine 0.16.0's `raised`; none today).
  case engine

  /// New input (a gesture, a tap on the pitch other than the skip, the tray, the meter).
  public var blocksInput: Bool { self != .none }
  /// The seat may count the board caught up, so this device keeps (or gains) the right to
  /// act. Its own raise keeps the authority it was started with; while another member's
  /// raise or the engine's is watched, the board shows a need the match has passed, so
  /// nothing may act on it.
  public var seatMayAct: Bool { self == .none || self == .ownLeadIn || self == .ownTipping }
  /// A scheduled action is waiting to be applied and sent: if the seat says this device may
  /// no longer act, the raise is dropped before it is applied (nothing sent, engine
  /// untouched), never applied and then refused.
  public var holdsUnsentAction: Bool { self == .ownLeadIn }
  /// Another member's aim may be drawn over the board.
  public var drawsRemoteAim: Bool { self == .none }
  /// The hand-off banner may come up.
  public var showsBanner: Bool { self == .none }
  /// Incoming actions are applied now (else they wait in the queue, drained on the first
  /// frame after it ends).
  public var appliesIncoming: Bool { self == .none }
}

extension PitchSession {
  /// What this board is watching now (RaiseWatch).
  public var raiseWatch: RaiseWatch {
    if stoodShow != nil { return .engine }
    guard let s = raiseShow else { return .none }
    if !s.own { return .arriving }
    return s.pending != nil ? .ownLeadIn : .ownTipping
  }

  /// This device's scheduled raise, dropped before its action is applied (the authority to
  /// send it was lost: moved off the team, a changed seat). The kubb lies as it was; the
  /// engine and the pitch never saw it. Nothing happens once the action has gone.
  public func dropUnsentRaise() {
    guard raiseWatch == .ownLeadIn else { return }
    raiseShow = nil
    resetRaiseTouch()
    try? settleScene()
    revision += 1
  }
}
