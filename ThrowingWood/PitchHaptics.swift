import AVFAudio
import CoreHaptics
import KubbRenderer

@MainActor final class PitchHaptics {
  private var engine: CHHapticEngine?
  private var players: [(end: Double, player: any CHHapticPatternPlayer)] = []

  func prepare() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    do {
      if engine == nil {
        let e = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
        e.playsHapticsOnly = true
        e.isAutoShutdownEnabled = true
        engine = e
      }
      try engine?.start()
    } catch { engine = nil }
  }

  func play(_ pattern: PitchHaptic) {
    guard let engine else { return }
    do {
      // start is idempotent and also recovers from idle shutdown or a media reset.
      try engine.start()
      let pulses = pattern.pulses
      let events = pulses.map { p in
        CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(p.intensity)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(p.sharpness)),
          ], relativeTime: p.offset)
      }
      let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
      let now = engine.currentTime
      players.removeAll { $0.end < now }
      try player.start(atTime: CHHapticTimeImmediate)
      players.append((now + (pulses.last?.offset ?? 0) + 0.05, player))
    } catch { prepare() }
  }

  func silence() {
    for entry in players { try? entry.player.stop(atTime: CHHapticTimeImmediate) }
    players.removeAll()
  }
}
