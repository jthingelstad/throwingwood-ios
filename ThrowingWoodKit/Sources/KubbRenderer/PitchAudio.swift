#if os(iOS)
  import AVFAudio

  /// One warm voice per recorded take, plus one for the web's synthesized chord.
  @MainActor public final class PitchAudio {
    let engine = AVAudioEngine()
    private struct Voice {
      let node: AVAudioPlayerNode, buffers: [AVAudioPCMBuffer]
      var busyUntil = 0.0
    }
    private var knocks: [Voice] = []
    private var chord: Voice?
    private var last: Int?

    public init() throws {
      // Render the small rate variations before the pitch opens. Every voice can
      // then join the next mixer quantum without a rate unit or a cold start.
      let hz = 48_000.0
      let format = AVAudioFormat(standardFormatWithSampleRate: hz, channels: 1)!
      for i in 1...9 {
        guard let url = Bundle.module.url(forResource: "Sounds/knock-\(i)", withExtension: "wav")
        else { throw CocoaError(.fileNoSuchFile) }
        let file = try AVAudioFile(forReading: url)
        let source = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let buffers = (-6...6).map { percent in
          Self.resample(source, rate: 1 + Double(percent) / 100, format: format)
        }
        knocks.append(voice(buffers))
      }
      chord = voice([Self.kingChord(hz: hz)])
      engine.prepare()
    }

    private static func resample(_ source: AVAudioPCMBuffer, rate: Double, format: AVAudioFormat)
      -> AVAudioPCMBuffer
    {
      let step = rate * source.format.sampleRate / format.sampleRate
      let last = Int(source.frameLength) - 1
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(last) / step) + 1)!
      buffer.frameLength = buffer.frameCapacity
      let input = source.floatChannelData![0]
      let output = buffer.floatChannelData![0]
      for i in 0..<Int(buffer.frameLength) {
        let x = Double(i) * step
        let lo = min(last, Int(x))
        output[i] = input[lo] + Float(x - Double(lo)) * (input[min(lo + 1, last)] - input[lo])
      }
      return buffer
    }

    private func voice(_ buffers: [AVAudioPCMBuffer]) -> Voice {
      let node = AVAudioPlayerNode()
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: buffers[0].format)
      node.prepare(withFrameCount: buffers[0].frameLength)
      return Voice(node: node, buffers: buffers)
    }

    private static func kingChord(hz: Double) -> AVAudioPCMBuffer {
      let format = AVAudioFormat(standardFormatWithSampleRate: hz, channels: 1)!
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(0.89 * hz)))!
      buffer.frameLength = buffer.frameCapacity
      let samples = buffer.floatChannelData![0]
      for i in 0..<Int(buffer.frameLength) {
        let now = Double(i) / hz
        var sum = 0.0
        for (frequency, delay) in [(523.25, 0.0), (783.99, 0.07), (1046.5, 0.14)] {
          let t = now - delay
          guard t >= 0 && t < 0.75 else { continue }
          let phase = t * frequency
          let triangle = 1 - 4 * abs((phase + 0.25).truncatingRemainder(dividingBy: 1) - 0.5)
          let gain =
            t < 0.012
            ? 0.18 * t / 0.012
            : 0.18 * pow(0.001 / 0.18, min(1, (t - 0.012) / 0.688))
          sum += triangle * gain
        }
        samples[i] = Float(sum)
      }
      return buffer
    }

    public func start() throws {
      if !engine.isRunning { try engine.start() }
      for v in knocks where !v.node.isPlaying { v.node.play() }
      if let chord, !chord.node.isPlaying { chord.node.play() }
    }

    public func play(_ sound: PitchSound) {
      guard engine.isRunning else { return }
      switch sound {
      case .knock(let gain):
        let now = ProcessInfo.processInfo.systemUptime
        let alternatives = knocks.indices.filter { $0 != last }
        let free = alternatives.filter { knocks[$0].busyUntil <= now }
        guard let i = (free.isEmpty ? alternatives : free).randomElement() else { return }
        let buffer = knocks[i].buffers.randomElement()!
        last = i
        knocks[i].busyUntil = now + Double(buffer.frameLength) / buffer.format.sampleRate
        strike(knocks[i], buffer: buffer, gain: gain)
      case .kingChord:
        if let chord { strike(chord, buffer: chord.buffers[0], gain: 1) }
      }
    }

    private func strike(_ v: Voice, buffer: AVAudioPCMBuffer, gain: Double) {
      v.node.volume = Float(gain)
      v.node.scheduleBuffer(buffer, at: nil, options: .interrupts)
      if !v.node.isPlaying { v.node.play() }
    }

    public func silence() {
      for i in knocks.indices {
        knocks[i].node.stop()
        if engine.isRunning { knocks[i].node.play() }
        knocks[i].busyUntil = 0
      }
      chord?.node.stop()
      if engine.isRunning { chord?.node.play() }
    }

    public func suspend() {
      engine.pause()
      silence()
    }
  }
#endif
