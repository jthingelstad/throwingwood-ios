import AVFAudio
import KubbRenderer
import Observation
import SwiftUI

@MainActor @Observable final class GameFeedback {
  var sound: Bool {
    didSet {
      UserDefaults.standard.set(sound, forKey: "pitch.sound")
      if sound { prepare() } else { audio?.suspend() }
    }
  }
  var haptics: Bool {
    didSet {
      UserDefaults.standard.set(haptics, forKey: "pitch.haptics")
      if haptics { prepare() } else { tactile.silence() }
    }
  }
  private var active = false
  var onPitch = false { didSet { if onPitch != oldValue { update() } } }
  private var audio: PitchAudio?
  private let tactile = PitchHaptics()

  init() {
    sound = UserDefaults.standard.object(forKey: "pitch.sound") as? Bool ?? true
    haptics = UserDefaults.standard.object(forKey: "pitch.haptics") as? Bool ?? true
  }

  func setActive(_ value: Bool) {
    active = value
    update()
  }

  private func update() {
    if active && onPitch {
      prepare()
    } else {
      audio?.suspend()
      tactile.silence()
    }
  }

  func prepare() {
    guard active, onPitch, sound || haptics else { return }
    let session = AVAudioSession.sharedInstance()
    do {
      if session.category != .ambient { try session.setCategory(.ambient) }
      try? session.setPreferredIOBufferDuration(0.0053)
      try session.setActive(true)
      if haptics { tactile.prepare() }
      if sound {
        if audio == nil { audio = try PitchAudio() }
        try audio?.start()
      }
    } catch {
      // The pitch remains playable while the audio session is unavailable.
    }
  }

  func attach(_ board: PitchSession) {
    board.onFeedback = { [weak self] cue in
      guard let self, active, onPitch else { return }
      if sound, let s = cue.sound { audio?.play(s) }
      if haptics, let h = cue.haptic { tactile.play(h) }
    }
    board.cancelFeedback = { [weak self] in self?.silence() }
  }

  /// The Tournament's other pitches, quiet and far (NeighbourSounds): under SOUND only,
  /// never a haptic, and only while the pitch is on the screen with the app active.
  func neighbours(_ sounds: [NeighbourSound]) {
    guard active, onPitch, sound, !sounds.isEmpty else { return }
    for s in sounds { audio?.play(s) }
  }

  func silence() {
    audio?.silence()
    tactile.silence()
  }
}

/// Sound and Haptics as rows that show their value, On or Off (the web's menu
/// row, which was once a SOUND: ON button that read as its own state), on the
/// Settings card: each a segmented bar.
struct FeedbackSettings: View {
  @Bindable var feedback: GameFeedback
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      FormRow("Sound") { full in Segmented(onOff: "Sound", value: $feedback.sound, full: full) }
      FormRow("Haptics") { full in Segmented(onOff: "Haptics", value: $feedback.haptics, full: full) }
    }
  }
}
