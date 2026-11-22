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

/// A slider's numbers from the engine (`view.aim.controls`, since 0.9; Jamie,
/// 2026-11-20: "more analog allow the slider to select any value in a range"): its
/// range, the value now, the plan's own, the fine `tick` and the `step` a press
/// jumps by, and whether it lasts a throw or the turn (`scope`). Any value in the
/// range may be sent (`setArc`, `setTilt`, `setSpin`); the engine clamps.
public struct PlanControl: Decodable, Sendable, Equatable {
  public let min, max, value, tick, step: Double
  public let `default`: Double?
  public let unit, scope: String?
  public init(
    min: Double, max: Double, value: Double, tick: Double, step: Double, default: Double? = nil,
    unit: String? = nil, scope: String? = nil
  ) {
    (self.min, self.max, self.value, self.tick, self.step) = (min, max, value, tick, step)
    (self.default, self.unit, self.scope) = (`default`, unit, scope)
  }

  /// A value's place on the track (0 the low end, 1 the high) and back, never rounded.
  public func fraction(_ v: Double) -> Double {
    max > min ? PlanScale.clamp01((v - min) / (max - min)) : 0.5
  }
  public func value(at f: Double) -> Double { min + PlanScale.clamp01(f) * (max - min) }

  /// The marks on a track `run` points long: one a tick, or, where ticks would come
  /// closer than `gap` points, the fewest ticks apart that divide a step (a baton's
  /// tilt, 1 degree ticks on a 64 point track, marks every 5; a kubb's spin, quarter
  /// taps, marks every half). The value is free between them.
  public func marks(run: Double, gap: Double = 4) -> [Double] {
    guard tick > 0, max > min, run > 0 else { return [] }
    let ticksPerStep = Swift.max(1, Int((step / tick).rounded()))
    let every =
      (1...ticksPerStep).first { k in
        ticksPerStep % k == 0 && Double(k) * tick / (max - min) * run >= gap
      } ?? ticksPerStep
    let spacing = Double(every) * tick
    let first = (min / spacing).rounded(.up) * spacing
    return stride(from: first, through: max + spacing * 1e-9, by: spacing).map { $0 }
  }
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
  public static func steps(of value: Double, kubb: Bool) -> Int {
    Int((kubb ? value : value / Double(tiltStep)).rounded())
  }
  /// One mark a step, the middle long and heavy.
  public static func sideMarks(kubb: Bool) -> [(f: Double, long: Bool)] {
    let n = sideSteps(kubb: kubb)
    return (-n...n).map { (sideFraction($0, kubb: kubb), $0 == 0) }
  }

  /// The headers' words: ARC 32° (the loft), TILT 10R, SPIN 2L, SPIN 1.25R, TILT 0.
  /// A tilt shows whole degrees, a spin its taps to a hundredth (0.9 takes any value).
  public static func arcLabel(loft: Int?) -> String { "ARC \(loft ?? 0)°" }
  public static func sideLabel(_ value: Double, kubb: Bool) -> String {
    let word = kubb ? "SPIN" : "TILT"
    let shown = amount(value, kubb: kubb)
    return shown == "0" ? "\(word) 0" : "\(word) \(shown)\(value < 0 ? "L" : "R")"
  }
  /// For VoiceOver: "Tilt 10 degrees right", "Spin 2 left", "Tilt none".
  public static func sideValueText(_ value: Double, kubb: Bool) -> String {
    let word = kubb ? "Spin" : "Tilt"
    let shown = amount(value, kubb: kubb)
    guard shown != "0" else { return "\(word) none" }
    let direction = value < 0 ? "left" : "right"
    return kubb ? "\(word) \(shown) \(direction)" : "\(word) \(shown) degrees \(direction)"
  }
  /// A tray plate's value after its name (the web's words: "Tilt, 7 degrees right",
  /// "Tilt, none", "Spin, 1.25 left"): the value without the name.
  public static func sideAmountText(_ value: Double, kubb: Bool) -> String {
    let shown = amount(value, kubb: kubb)
    guard shown != "0" else { return "none" }
    let direction = value < 0 ? "left" : "right"
    return kubb ? "\(shown) \(direction)" : "\(shown) degrees \(direction)"
  }
  /// The size of a side value as shown: "10", "2", "1.25", "0.5".
  static func amount(_ value: Double, kubb: Bool) -> String {
    let a = abs(value)
    guard kubb else { return String(Int(a.rounded())) }
    let hundredths = Int((a * 100).rounded())
    if hundredths % 100 == 0 { return String(hundredths / 100) }
    var text = String(format: "%d.%02d", hundredths / 100, hundredths % 100)
    if text.hasSuffix("0") { text.removeLast() }
    return text
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

/// `cancel`: the hold ended with no release (the controls went away under the
/// finger, the app left the foreground).
public enum SlidePhase: Sendable { case down, move, up, cancel }

extension PitchSession {
  /// The engine's plan view (SIDE VIEW): the toggle, or while a slider is held
  /// and `PlanScale.peek` after.
  public var showsSide: Bool { plan || held != nil || peekLeft > 0 }

  /// True while the display must keep ticking with nothing else moving: a slider
  /// held or easing out of its peek, an automatic raise waiting its turn, or a raise's
  /// allowed end lit for its second.
  public var wantsFrames: Bool {
    held != nil || peekLeft > 0 || pendingSlide != nil || autoRaise.waiting || raiseHint != nil
      || standDrag != nil || standPeekLeft > 0 || effects?.active == true || freeCamera.easing
  }

  /// A kubb is in the hand (SPIN), not a baton (TILT).
  public var throwsKubb: Bool { projectile == "kubb" }

  /// A finger on a slider at `f` (0...1, bottom to top or left to right). Only
  /// records where it is: `tick` sends the latest place to the engine once a frame.
  public func slide(_ slider: PlanSlider, to f: Double, phase: SlidePhase) {
    if phase == .cancel {
      cancelSlide()
      return
    }
    if slideLetGo {
      // the drag `cancelHeld` let go: nothing more until a new press
      guard phase == .down else {
        if phase == .up { slideLetGo = false }
        return
      }
      slideLetGo = false
    }
    guard canAim || (phase == .up && held != nil) else { return }
    let f = PlanScale.clamp01(f)
    switch phase {
    case .cancel: return
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

  /// A held slider's finger is gone without a release: the plan stays where the
  /// last frame left it and the side view goes at once, so the dial is not left
  /// refusing a throw.
  public func cancelSlide() {
    guard held != nil || pendingSlide != nil else { return }
    held = nil
    heldFraction = nil
    pendingSlide = nil
    revision += 1
  }

  /// The screen changed under the finger (it turned, or the plan moved): let go of
  /// any slider and STAND without sending what the finger was doing, and ignore
  /// the rest of that drag. The next press starts afresh.
  public func cancelHeld() {
    if held != nil { slideLetGo = true }
    cancelSlide()
    stand(fx: 0, fy: 0, phase: .cancel)
  }

  /// A step from VoiceOver's adjustable action.
  public func stepPlan(_ slider: PlanSlider, by step: Int) throws {
    try adjustPlan(arc: slider == .arc, step: step)
  }

  /// Sends the slider's latest place. ARC is continuous (`setArc`). On 0.9 the
  /// side is too (`setTilt`, `setSpin`: any value in the engine's range); an older
  /// engine takes it only in steps (`stepSide`), so it moves by the difference.
  func applySlide() throws -> Bool {
    guard let (slider, f) = pendingSlide else { return false }
    pendingSlide = nil
    guard canAim else { return false }
    switch slider {
    case .arc:
      let deg = arcControl?.value(at: f) ?? PlanScale.release(at: f)
      guard release.map({ abs($0 - deg) > 1e-9 }) ?? true else { return false }
      try replan("setArc", #"{"deg":\#(deg)}"#)
    case .side:
      if let c = sideControl {
        let v = c.value(at: f)
        guard abs(v - (sideStep ?? 0)) > 1e-9 else { return true }
        try replan(throwsKubb ? "setSpin" : "setTilt", throwsKubb ? #"{"spin":\#(v)}"# : #"{"deg":\#(v)}"#)
      } else {
        let step = PlanScale.sideStep(at: f, kubb: throwsKubb) - sideSteps
        guard step != 0 else { return true }
        try replan("stepSide", #"{"step":\#(step)}"#)
      }
    }
    return true
  }

  /// Where the ARC knob sits (0 the bottom, 1 the top): the engine's range on 0.9.
  public var arcPlace: Double {
    arcControl?.fraction(release ?? PlanScale.releaseNormal) ?? PlanScale.arcFraction(release)
  }
  /// Where the TILT or SPIN knob sits (0 the left end, 1 the right): the value itself
  /// on 0.9, its step before.
  public var sidePlace: Double {
    sideControl?.fraction(sideStep ?? 0)
      ?? PlanScale.sideFraction(sideSteps, kubb: throwsKubb)
  }
  /// ARC's marks on a track `run` points long, `long` the level throw's (3 o'clock).
  public func arcMarks(run: Double) -> [(f: Double, long: Bool)] {
    guard let c = arcControl else { return PlanScale.arcMarks }
    return c.marks(run: run).map { (c.fraction($0), abs($0 - PlanScale.releaseNormal) < 1e-9) }
  }
  /// TILT's or SPIN's marks, the middle (none) long.
  public func sideMarks(run: Double) -> [(f: Double, long: Bool)] {
    guard let c = sideControl else { return PlanScale.sideMarks(kubb: throwsKubb) }
    return c.marks(run: run).map { (c.fraction($0), abs($0) < 1e-9) }
  }

  func endSlide() {
    held = nil
    heldFraction = nil
    pendingSlide = nil
    peekLeft = 0
  }
}
