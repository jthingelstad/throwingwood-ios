import Foundation
import Testing

@testable import KubbRenderer

private struct FeelFixture: Decodable {
  let projectile: Recording.Projectile, timeline: Recording.Timeline
  var cues: [TimedFeedback] { timeline.feedback(projectileID: projectile.id) }
}

private func data(_ name: String) throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/feel"))
  return try Data(contentsOf: url)
}
private func fixture(_ name: String) throws -> FeelFixture {
  try JSONDecoder().decode(FeelFixture.self, from: data(name))
}

struct FeedbackTests {
  @Test(arguments: ["clean", "multi", "king", "miss-grass", "miss-sand", "miss-snow"])
  func recordedCues(name: String) throws {
    // Independent expected strikes, in 240 Hz solver steps, from the six fixture throws.
    typealias Strike = (tick: Int, gain: Double?, haptic: PitchHaptic)
    let land: Strike = (256, nil, .landing(.grass, 0.14823098943332164))
    let first: Strike = (256, 0.72, .contact(1))
    let strikes: [Strike]
    switch name {
    case "clean": strikes = [first, land]
    case "multi":
      strikes = [first, land, (259, 0.22775718660688052, .contact(0.08843923445718614))]
    case "king":
      strikes = [
        (167, 0.5413613265632272, .contact(0.5689355442720453)), (167, nil, .king),
        (200, nil, .landing(.grass, 0.1451845266485351)),
      ]
    case "miss-grass": strikes = [(186, nil, .landing(.grass, 0.3686926930467786))]
    case "miss-sand": strikes = [(186, nil, .landing(.sand, 0.1138426191960219))]
    default: strikes = [(186, nil, .landing(.snow, 0.3714566986479197))]
    }
    let cues = try fixture(name).cues
    try #require(cues.count == strikes.count)
    for (cue, strike) in zip(cues, strikes) {
      #expect(abs(cue.time - Double(strike.tick) / 240) < 1e-10)
      #expect(cue.cue.haptic == strike.haptic)
      if let gain = strike.gain {
        guard case .knock(let value) = cue.cue.sound else {
          Issue.record("Missing knock")
          continue
        }
        #expect(abs(value - gain) < 1e-9)
      } else {
        #expect(cue.cue.sound == (strike.haptic == .king ? .kingChord : nil))
      }
    }
  }

  @Test func legacyTouchesStillKnock() throws {
    let timeline = try JSONDecoder().decode(
      Recording.Timeline.self,
      from: Data(
        #"{"bursts":[],"touches":[{"id":"a","kind":"kubb","t":0.5},{"id":"baton","kind":"baton","t":0.5}]}"#
          .utf8))
    let cues = timeline.feedback(projectileID: "baton")
    #expect(cues == [TimedFeedback(time: 0.5, cue: .init(sound: .knock(gain: 0.8 * 0.9)))])
  }

  @Test func patternShapes() {
    #expect(PitchHaptic.band.pulses == [Pulse(0, 0.18, 0.75)])
    #expect(PitchHaptic.release.pulses == [Pulse(0, 0.78, 0.65)])
    #expect(PitchHaptic.contact(0.5).pulses == [Pulse(0, 0.55, 0.65)])
    for (s, sharp) in [(Surface.grass, 0.20), (.sand, 0.10), (.snow, 0.04)] {
      #expect(PitchHaptic.landing(s, 0.5).pulses == [Pulse(0, 0.275, sharp)])
    }
    #expect(PitchHaptic.king.pulses == [Pulse(0, 0.90, 0.32), Pulse(0.085, 0.66, 0.18)])
    #expect(PitchHaptic.win.pulses == [Pulse(0, 0.40, 0.45), Pulse(0.095, 0.72, 0.70)])
    #expect(PitchHaptic.handoff.pulses == [Pulse(0, 0.32, 0.4)])
  }

  @MainActor @Test(arguments: [false, true]) func pictureClockAndSkip(skip: Bool) throws {
    let board = try PitchSession(appVersion: "test")
    // Replay the same recorded clean throw. SKIP lands during its approach in slow motion.
    let object = try #require(JSONSerialization.jsonObject(with: data("clean")) as? [String: Any])
    let action = try JSONSerialization.data(withJSONObject: #require(object["action"]))
    struct Applied: Decodable { let recording: Recording }
    let applied: Applied = try board.read("apply", String(decoding: action, as: UTF8.self))
    let expected = try fixture("clean").cues
    var emitted: [PitchFeedback] = []
    var cancelled = 0
    var sawSlow = false
    board.onFeedback = { emitted.append($0) }
    board.cancelFeedback = { cancelled += 1 }
    try board.beginPlayback(applied.recording)
    let dt = 1.0 / 120
    for _ in 0..<2000 {
      guard let p = board.playback else { break }
      let shown = min(p.recording.duration, p.nextTime)
      try board.tick(dt)
      sawSlow = sawSlow || board.slow
      #expect(emitted == expected.filter { $0.time <= shown }.map(\.cue))
      if skip && board.slow {
        try board.skipPlayback()
        for _ in 0..<240 { try board.tick(dt) }
        break
      }
    }
    #expect(sawSlow && !board.playing)
    #expect(cancelled == (skip ? 1 : 0))
    #expect(emitted == (skip ? [] : expected.map(\.cue)))
  }
}
