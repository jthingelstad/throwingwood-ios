import Foundation

/// The throw's coach line, the web's `src/game/coach.js`: a few words over the
/// meter's prompt that follow the stroke, for a player who is learning, and
/// that answer a tester's question ("Does it matter how quickly or slowly I
/// track my finger") on the meter itself ("Have the UI show it not a separate
/// how to page.").
///
/// What the engine does (core/swing.lua, core/throwplan.lua plan.launch): the
/// pull back sets the power and its speed does not matter; the forward flick
/// must be fast, because a slow one delivers only part of that power (the
/// engine's verdict for it is SLOW); the throw leaves where the flick stops.
/// The power band is the orange mark, the release band the blue mark.
///
/// Pure. Drawing only: never fed to the engine, sent or recorded.
public enum Coach {
  /// A device that has made fewer throws than this is coached (the nudge's
  /// `learnedAt`, the same `pitch.throwsMade` count).
  public static let learnedAt = 3

  public enum Stage: String, Sendable { case rest, winding, band }

  public static let lines: [Stage: String] = [
    .rest: "PULL BACK TO THE ORANGE MARK",
    .winding: "NO RUSH GOING BACK",
    .band: "NOW FLICK FAST AND STOP ON THE BLUE MARK",
  ]
  /// The lead line for the throw after one the engine called SLOW.
  public static let slowLine = "SLOW FLICK. FLICK FASTER."

  public struct Line: Equatable, Sendable {
    public let stage: Stage
    public let lead: String?
    public let line: String
  }

  /// Where the stroke is: rest before a backswing, winding while drawing back
  /// short of the power band, band once it is reached and through the flick.
  public static func stage(phase: String?, back: Double?, powerLo: Double?) -> Stage {
    let phase = phase ?? "idle"
    if phase == "swinging" { return .band }
    if phase != "winding" { return .rest }
    let lo = powerLo.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
    return (back ?? 0) >= lo ? .band : .winding
  }

  public static func stage(_ dial: DialState) -> Stage {
    stage(phase: dial.phase, back: dial.back, powerLo: dial.powerLo)
  }

  /// Was the flick too slow? `power`: this player's own throw's power verdict.
  public static func slow(power: String?) -> Bool { power == "SLOW" }

  /// The coach for this frame, or nil. `thrown`: this device's throws;
  /// `slow`: this player's last throw was SLOW.
  public static func line(thrown: Int, slow: Bool, stage: Stage) -> Line? {
    if !slow && thrown >= learnedAt { return nil }
    return Line(stage: stage, lead: slow ? slowLine : nil, line: lines[stage]!)
  }
}

extension ThrowResult {
  /// The engine called this throw's flick SLOW (only this player's own throws
  /// carry verdicts).
  public var slowFlick: Bool { Coach.slow(power: verdicts?.power) }
}
