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

  func silence() {
    audio?.silence()
    tactile.silence()
  }
}

struct FeedbackSettings: View {
  @Bindable var feedback: GameFeedback
  var body: some View {
    Toggle("SOUND", isOn: $feedback.sound)
    Toggle("HAPTICS", isOn: $feedback.haptics)
  }
}
