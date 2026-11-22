#if os(iOS)
  import AVFAudio

  /// One warm voice per recorded take, plus one for the web's synthesized chord, and
  /// `NeighbourSounds.voices` voices of their own for the Tournament's other pitches (so a
  /// neighbour never takes a voice from the player's own throw).
  @MainActor public final class PitchAudio {
    let engine = AVAudioEngine()
    private struct Voice {
      let node: AVAudioPlayerNode, buffers: [AVAudioPCMBuffer]
      var busyUntil = 0.0
    }
    private var knocks: [Voice] = []
    private var chord: Voice?
    private var last: Int?
    /// The neighbours' voices, panned, each with the gain it is sounding at.
    private var far: [Voice] = []
    private var farGain: [Double] = []
    /// The knock takes at their own rate (the neighbours share them) and the landing's thud.
    private var takes: [AVAudioPCMBuffer] = []
    private var thud: AVAudioPCMBuffer?

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
        takes.append(buffers[6])
      }
      chord = voice([Self.kingChord(hz: hz)])
      let thud = Self.thud(hz: hz)
      self.thud = thud
      for _ in 0..<NeighbourSounds.voices {
        far.append(voice([thud]))
        farGain.append(0)
      }
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

    /// A soft landing on grass, made once: a low knock (110 Hz falling to 70) under a puff
    /// of filtered noise, gone in 0.14 s. Its peak is about 0.6.
    private static func thud(hz: Double) -> AVAudioPCMBuffer {
      let format = AVAudioFormat(standardFormatWithSampleRate: hz, channels: 1)!
      let n = Int(0.14 * hz)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
      buffer.frameLength = buffer.frameCapacity
      let out = buffer.floatChannelData![0]
      var seed: UInt32 = 0x9E37_79B9
      var low = 0.0, phase = 0.0
      for i in 0..<n {
        let t = Double(i) / hz
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
        low += (noise - low) * 0.08  // a one-pole low pass: the grass's hush
        phase += 2 * .pi * (70 + 40 * exp(-t / 0.03)) / hz
        let attack = min(1, t / 0.003)
        let body = sin(phase) * exp(-t / 0.035)
        let hush = low * 2.2 * exp(-t / 0.025)
        out[i] = Float(attack * 0.6 * (0.75 * body + 0.25 * hush))
      }
      return buffer
    }

    public func start() throws {
      if !engine.isRunning { try engine.start() }
      for v in far where !v.node.isPlaying { v.node.play() }
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

    /// A neighbour's sound: on a free neighbour voice, else on the faintest one sounding if
    /// this is louder (the faintest is dropped), else not at all.
    public func play(_ sound: NeighbourSound) {
      guard engine.isRunning, !far.isEmpty else { return }
      let now = ProcessInfo.processInfo.systemUptime
      let buffer: AVAudioPCMBuffer
      switch sound.kind {
      case .knock: buffer = takes.randomElement()!
      case .thud: buffer = thud!
      }
      var pick = far.indices.first { far[$0].busyUntil <= now }
      if pick == nil, let i = far.indices.min(by: { farGain[$0] < farGain[$1] }), farGain[i] < sound.gain {
        pick = i
      }
      guard let i = pick else { return }
      far[i].busyUntil = now + Double(buffer.frameLength) / buffer.format.sampleRate
      farGain[i] = sound.gain
      far[i].node.pan = Float(sound.pan)
      strike(far[i], buffer: buffer, gain: sound.gain)
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
      for i in far.indices {
        far[i].node.stop()
        if engine.isRunning { far[i].node.play() }
        far[i].busyUntil = 0
        farGain[i] = 0
      }
    }

    public func suspend() {
      engine.pause()
      silence()
    }
  }
#endif
