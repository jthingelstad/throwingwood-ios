import Foundation

/// The plan's two sliders: ARC (vertical, continuous) and TILT for a baton or
/// SPIN for a kubb (horizontal, a detent at each of the engine's steps). They
/// replace the four step buttons carried over from the Playdate's "hold B and
/// press the d-pad" (Jamie, 2026-11-19: "I'd like to make arc and tilt less
/// buttons and more a slider with continuous movement ... It is all a hangover
/// from us starting on play date").
public enum PlanSlider: Sendable, Equatable {
  case arc, side
}

/// The sliders' scale both ways. The numbers are the engine's plan limits
/// (core/throwplan.lua `plan.tune`): the planned release on the clock, 15 to
/// 165 degrees; a baton's tilt in steps of 5 to 20 either way; a kubb's spin in
/// steps of 1 to 3 either way. The engine clamps; these only lay out the scale.
public enum PlanScale {
  public static let releaseMin = 15.0, releaseMax = 165.0
  /// 3 o'clock, the normal throw (loft 32).
  public static let releaseNormal = 90.0
  public static let tiltStep = 5, tiltMax = 20, spinMax = 3
  /// Seconds the side view stays after a slider is let go.
  public static let peek = 0.5

  static func clamp01(_ f: Double) -> Double { f.isFinite ? max(0, min(1, f)) : 0 }

  /// ARC: the release for a place on the track (0 the bottom, 1 the top) and back.
  public static func release(at f: Double) -> Double {
    releaseMin + clamp01(f) * (releaseMax - releaseMin)
  }
  public static func arcFraction(_ release: Double?) -> Double {
    clamp01(((release ?? releaseNormal) - releaseMin) / (releaseMax - releaseMin))
  }
  /// ARC's marks: every hour of the release on the clock (1 to 5 o'clock), the
  /// level throw's at 3 o'clock long.
  public static var arcMarks: [(f: Double, long: Bool)] {
    stride(from: 30.0, through: 150, by: 30).map { (arcFraction($0), $0 == releaseNormal) }
  }

  /// TILT or SPIN: the steps either way (4 for a baton, 3 for a kubb).
  public static func sideSteps(kubb: Bool) -> Int { kubb ? spinMax : tiltMax / tiltStep }
  /// The nearest step for a place on the track (0 the left end, 1 the right).
  public static func sideStep(at f: Double, kubb: Bool) -> Int {
    Int(((clamp01(f) * 2 - 1) * Double(sideSteps(kubb: kubb))).rounded())
  }
  public static func sideFraction(_ step: Int, kubb: Bool) -> Double {
    clamp01((Double(step) / Double(sideSteps(kubb: kubb)) + 1) / 2)
  }
  /// A side value in steps: a baton's tilt comes in degrees, a kubb's spin in steps.
  public static func steps(of value: Int, kubb: Bool) -> Int {
    kubb ? value : Int((Double(value) / Double(tiltStep)).rounded())
  }
  /// One mark a step, the middle long and heavy.
  public static func sideMarks(kubb: Bool) -> [(f: Double, long: Bool)] {
    let n = sideSteps(kubb: kubb)
    return (-n...n).map { (sideFraction($0, kubb: kubb), $0 == 0) }
  }

  /// The headers' words: ARC 32° (the loft), TILT 10R, SPIN 2L, TILT 0.
  public static func arcLabel(loft: Int?) -> String { "ARC \(loft ?? 0)°" }
  public static func sideLabel(_ value: Int, kubb: Bool) -> String {
    let word = kubb ? "SPIN" : "TILT"
    return value == 0 ? "\(word) 0" : "\(word) \(abs(value))\(value < 0 ? "L" : "R")"
  }
  /// For VoiceOver: "Tilt 10 degrees right", "Spin 2 left", "Tilt none".
  public static func sideValueText(_ value: Int, kubb: Bool) -> String {
    let word = kubb ? "Spin" : "Tilt"
    guard value != 0 else { return "\(word) none" }
    let direction = value < 0 ? "left" : "right"
    return kubb ? "\(word) \(abs(value)) \(direction)" : "\(word) \(abs(value)) degrees \(direction)"
  }

  /// The line on the screen while a slider is held: what it does to the throw.
  public static func caption(_ slider: PlanSlider, kubb: Bool) -> String {
    switch slider {
    case .arc: "A HIGHER ARC DROPS IN STEEPER. A LOWER ONE SKIDS IN."
    case .side:
      kubb
        ? "SPIN KEEPS A DRILLED KUBB STEADY IN THE AIR."
        : "TILT LEANS THE BATON TO STEER IT THROUGH A GROUP."
    }
  }
}

public enum SlidePhase: Sendable { case down, move, up }

extension PitchSession {
  /// The engine's plan view (SIDE VIEW): the toggle, or while a slider is held
  /// and `PlanScale.peek` after.
  public var showsSide: Bool { plan || held != nil || peekLeft > 0 }

  /// True while the display must keep ticking with nothing else moving: a slider
  /// held or easing out of its peek, or an automatic raise waiting its turn.
  public var wantsFrames: Bool {
    held != nil || peekLeft > 0 || pendingSlide != nil || autoRaise.waiting
  }

  /// A kubb is in the hand (SPIN), not a baton (TILT).
  public var throwsKubb: Bool { projectile == "kubb" }

  /// A finger on a slider at `f` (0...1, bottom to top or left to right). Only
  /// records where it is: `tick` sends the latest place to the engine once a frame.
  public func slide(_ slider: PlanSlider, to f: Double, phase: SlidePhase) {
    guard canAim || (phase == .up && held != nil) else { return }
    let f = PlanScale.clamp01(f)
    switch phase {
    case .down, .move:
      if held == nil { input.reset() }
      held = slider
      heldFraction = f
      pendingSlide = (slider, f)
    case .up:
      pendingSlide = (slider, f)
      held = nil
      heldFraction = nil
      peekLeft = PlanScale.peek
    }
    revision += 1
  }

  /// A step from VoiceOver's adjustable action.
  public func stepPlan(_ slider: PlanSlider, by step: Int) throws {
    try adjustPlan(arc: slider == .arc, step: step)
  }

  /// Sends the slider's latest place. ARC is continuous (`setArc`); the engine
  /// takes the side only in steps (`stepSide`), so it moves by the difference.
  func applySlide() throws -> Bool {
    guard let (slider, f) = pendingSlide else { return false }
    pendingSlide = nil
    guard canAim else { return false }
    switch slider {
    case .arc:
      let deg = PlanScale.release(at: f)
      guard release.map({ abs($0 - deg) > 1e-9 }) ?? true else { return false }
      try replan("setArc", #"{"deg":\#(deg)}"#)
    case .side:
      let step = PlanScale.sideStep(at: f, kubb: throwsKubb) - sideSteps
      guard step != 0 else { return true }
      try replan("stepSide", #"{"step":\#(step)}"#)
    }
    return true
  }

  func endSlide() {
    held = nil
    heldFraction = nil
    pendingSlide = nil
    peekLeft = 0
  }
}
