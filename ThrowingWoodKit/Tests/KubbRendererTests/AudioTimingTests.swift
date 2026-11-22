#if os(iOS) && targetEnvironment(simulator)
  import AVFAudio
  import Foundation
  import Testing
  import os

  @testable import KubbRenderer

  /// Measure the first rendered non-silent PCM sample in the mixer's host clock.
  /// A tap can deliver a large block late. Its timestamp still identifies sample zero.
  @MainActor struct AudioTimingTests {
    @Test func warmMixerOnset() async throws {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.ambient)
      try session.setPreferredIOBufferDuration(0.0053)
      try session.setActive(true)
      let audio = try PitchAudio()
      let mixer = audio.engine.mainMixerNode
      let onset = OSAllocatedUnfairLock(initialState: 0.0)
      mixer.installTap(onBus: 0, bufferSize: 256, format: nil) { @Sendable buffer, time in
        guard time.isHostTimeValid, let samples = buffer.floatChannelData?[0],
          let i = (0..<Int(buffer.frameLength)).first(where: { abs(samples[$0]) > 0.001 })
        else { return }
        let t =
          AVAudioTime.seconds(forHostTime: time.hostTime) + Double(i) / buffer.format.sampleRate
        onset.withLock { if $0 == 0 { $0 = t } }
      }
      defer {
        mixer.removeTap(onBus: 0)
        audio.suspend()
      }
      try audio.start()
      try await Task.sleep(for: .milliseconds(250))
      var times: [Double] = []
      for _ in 0..<9 {
        onset.withLock { $0 = 0 }
        let start = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        audio.play(.knock(gain: 1))
        try await Task.sleep(for: .milliseconds(500))
        let time = onset.withLock { $0 }
        try #require(time > 0, "mixer produced no wood transient")
        times.append(1000 * (time - start))
      }
      #expect(times.allSatisfy { $0 >= 0 && $0 < 1000.0 / 30 }, "two 60 Hz simulator frames")
      print(
        "warm mixer onset ms \(times.sorted()), IO buffer ms \(session.ioBufferDuration * 1000)")
      // the Tournament's neighbours: their own voices, a knock take and the landing's thud
      var far: [Double] = []
      for i in 0..<8 {
        onset.withLock { $0 = 0 }
        let start = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        audio.play(NeighbourSound(kind: i % 2 == 0 ? .knock : .thud, gain: 1, pan: i % 4 < 2 ? -0.6 : 0.6))
        try await Task.sleep(for: .milliseconds(400))
        let time = onset.withLock { $0 }
        try #require(time > 0, "mixer produced no neighbour sound")
        far.append(1000 * (time - start))
      }
      #expect(far.allSatisfy { $0 >= 0 && $0 < 1000.0 / 30 }, "two 60 Hz simulator frames")
      print("warm neighbour onset ms \(far.sorted())")
    }
  }
#endif
