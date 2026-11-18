import Foundation

public enum PitchSound: Equatable, Sendable {
  case knock(gain: Double)
  case kingChord
}

public struct Pulse: Equatable, Sendable {
  public let offset, intensity, sharpness: Double

  init(_ offset: Double, _ intensity: Double, _ sharpness: Double) {
    self.offset = offset
    self.intensity = intensity
    self.sharpness = sharpness
  }
}

public enum PitchHaptic: Equatable, Sendable {
  case band, release
  case contact(Double)
  case landing(Surface, Double)
  case king, win, handoff

  public var pulses: [Pulse] {
    switch self {
    case .band: [Pulse(0, 0.18, 0.75)]
    case .release: [Pulse(0, 0.78, 0.65)]
    case .contact(let strength): [Pulse(0, 0.15 + 0.8 * strength, 0.65)]
    case .landing(let surface, let strength):
      [Pulse(0, 0.10 + 0.35 * strength, [.grass: 0.20, .sand: 0.10, .snow: 0.04][surface]!)]
    case .king: [Pulse(0, 0.90, 0.32), Pulse(0.085, 0.66, 0.18)]
    case .win: [Pulse(0, 0.40, 0.45), Pulse(0.095, 0.72, 0.70)]
    case .handoff: [Pulse(0, 0.32, 0.4)]
    }
  }
}

/// The display frame delivers only cues whose simulation time is already visible.
public struct PitchFeedback: Equatable, Sendable {
  public let sound: PitchSound?, haptic: PitchHaptic?
  init(sound: PitchSound? = nil, haptic: PitchHaptic? = nil) {
    self.sound = sound
    self.haptic = haptic
  }
}

struct TimedFeedback: Equatable {
  let time: Double, cue: PitchFeedback
}

extension Recording.Timeline {
  func feedback(projectileID: String) -> [TimedFeedback] {
    var cues: [TimedFeedback] = []
    func add(_ time: Double, _ sound: PitchSound?, _ haptic: PitchHaptic?) {
      cues.append(TimedFeedback(time: time, cue: PitchFeedback(sound: sound, haptic: haptic)))
    }
    var touches = (self.touches ?? []).filter { $0.id != projectileID }
    for c in contacts ?? [] {
      // Keep the web's take for each first-touched piece, including two
      // pieces first struck together. Later pairs add a knock of their own.
      let struck = touches.filter { $0.t == c.t && ($0.id == c.idA || $0.id == c.idB) }
      touches.removeAll { $0.t == c.t && ($0.id == c.idA || $0.id == c.idB) }
      let weights =
        struck.isEmpty
        ? [c.a == "king" || c.b == "king" ? 1.0 : 0.9]
        : struck.map { $0.kind == "king" ? 1.0 : 0.9 }
      for (index, weight) in weights.enumerated() {
        let gain = 0.8 * weight * (0.25 + 0.75 * c.strength)
        add(c.t, .knock(gain: gain), index == 0 ? .contact(c.strength) : nil)
      }
    }
    // A pre-0.4.1 recording has touch times without measured strengths.
    for t in touches { add(t.t, .knock(gain: 0.8 * (t.kind == "king" ? 1 : 0.9)), nil) }
    if let l = batonLanding { add(l.t, nil, .landing(l.surface, l.strength)) }
    for b in bursts where b.kind == "king" {
      add(b.start, .kingChord, b.takenBack == true ? nil : .king)
    }
    return cues.sorted { $0.time < $1.time }
  }
}
