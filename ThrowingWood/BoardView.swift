import KubbRenderer
import UIKit

@MainActor final class BoardView: UIView {
  let pitch: PracticePitch
  private let model: PracticeModel
  private var display: CADisplayLink?, previous: CFTimeInterval?
  private var active = false
  private enum Gesture { case target, dial }
  private var gesture: Gesture?
  private var tracking: UITouch?
  private var lastDialPoint: CGPoint?
  #if targetEnvironment(simulator)
    private var reviewReady = false
    private let reviewMode = ProcessInfo.processInfo.environment["PITCH_REVIEW"]
    private var timing = FrameTiming()
  #endif

  init(pitch: PracticePitch, model: PracticeModel) {
    self.pitch = pitch
    self.model = model
    super.init(frame: .zero)
    isOpaque = true
    backgroundColor = .systemBackground
    contentMode = .redraw
    accessibilityLabel =
      "Practice pitch. Drag the target to aim. Wind the dial back, flick forward and lift to throw."
    isAccessibilityElement = true
  }
  required init?(coder: NSCoder) { nil }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if let window {
      contentScaleFactor = min(window.traitCollection.displayScale, 2)
      startIfActive()
    } else {
      stop()
    }
  }
  func setActive(_ value: Bool) {
    guard active != value else { return }
    active = value
    if active { startIfActive() } else { stop() }
  }
  private func startIfActive() {
    guard active, window != nil, display == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
    let maxRate = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(60, maxRate), maximum: maxRate, preferred: maxRate)
    link.add(to: .main, forMode: .common)
    display = link
  }
  func stop() {
    display?.invalidate()
    display = nil
    previous = nil
    cancel()
  }
  private func cancel() {
    if gesture == .dial { run { try pitch.cancelInput() } }
    tracking = nil
    gesture = nil
  }
  private func run(_ action: () throws -> Void) {
    do {
      try action()
      model.refresh()
      setNeedsDisplay()
    } catch {
      model.error = error.localizedDescription
      display?.invalidate()
      display = nil
    }
  }
  @objc private func frame(_ link: CADisplayLink) {
    let now = link.targetTimestamp
    let dt = previous.map { now - $0 } ?? (now - link.timestamp)
    previous = now
    #if targetEnvironment(simulator)
      if let mode = reviewMode, !bounds.isEmpty {
        if !reviewReady {
          reviewReady = true
          run { try prepareReview(mode) }
          if mode != "timing" { link.isPaused = true }
          return
        }
        if mode != "timing" { return }
      }
    #endif
    #if targetEnvironment(simulator)
      let start = CACurrentMediaTime()
      if reviewMode == "timing", pitch.result != nil { timing.finish() }
    #endif
    do {
      if try pitch.tick(dt) {
        if pitch.playing { gesture = nil }
        model.refresh()
        setNeedsDisplay()
        #if targetEnvironment(simulator)
          if reviewMode == "timing", pitch.playing, pitch.result == nil { timing.tick(start) }
        #endif
      } else if gesture == nil && !pitch.playing && pitch.result == nil {
        link.isPaused = true
        previous = nil
      }
    } catch {
      model.error = error.localizedDescription
      stop()
    }
  }

  var radius: CGFloat { min(bounds.width * 0.22, bounds.height * 0.12, 114) }
  var hub: CGPoint {
    CGPoint(x: bounds.midX, y: bounds.maxY - safeAreaInsets.bottom - 42 - radius)
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    #if targetEnvironment(simulator)
      let start = CACurrentMediaTime()
      defer { if reviewMode == "timing" { timing.draw(start) } }
    #endif
    PitchRenderer.draw(in: ctx, size: bounds.size, camera: pitch.camera, scene: pitch.scene)
    let hud = PracticeHUD(context: ctx, size: bounds.size)
    for burst in pitch.bursts {
      if let point = burst.point(size: bounds.size, camera: pitch.camera) {
        hud.burst(burst, at: point)
      }
    }
    hud.dial(pitch.dial, at: hub, radius: radius, playing: pitch.playing)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard !pitch.playing, tracking == nil, let t = touches.first else { return }
    let p = t.location(in: self)
    if hypot(p.x - hub.x, p.y - hub.y) <= 1.25 * radius {
      gesture = .dial
      display?.isPaused = false
      sampleDial(p)
    } else if let mark = pitch.marker(in: bounds.size), hypot(p.x - mark.x, p.y - mark.y) < 56 {
      gesture = .target
    } else {
      return
    }
    tracking = t
  }
  private func sampleDial(_ p: CGPoint) {
    lastDialPoint = p
    pitch.sample(CGPoint(x: (p.x - hub.x) / radius, y: (p.y - hub.y) / radius))
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let t = tracking, touches.contains(t) else { return }
    let p = t.location(in: self)
    switch gesture {
    case .dial: sampleDial(p)
    case .target: run { try pitch.target(p, size: bounds.size, snap: false) }
    case nil: break
    }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let t = tracking, touches.contains(t) else { return }
    switch gesture {
    case .dial:
      let p = t.location(in: self)
      if p != lastDialPoint { sampleDial(p) }
      pitch.sample(nil)
    case .target: run { try pitch.target(t.location(in: self), size: bounds.size, snap: true) }
    case nil: break
    }
    tracking = nil
    gesture = nil
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }

  #if targetEnvironment(simulator)
    /// Review stills use the actual pitch, dial input, clock and drawing layers.
    private func prepareReview(_ mode: String) throws {
      guard ["aim", "flight", "rest", "timing"].contains(mode) else { return }
      let dt = 1.0 / 60
      // Snap the circle one kubb to the right of its initial target.
      if let m = pitch.marker(in: bounds.size) {
        try pitch.target(
          CGPoint(x: m.x + bounds.width * 0.22, y: m.y), size: bounds.size, snap: true)
      }
      if mode == "aim" { return }
      let back = ((pitch.dial.powerHi ?? 100) + (pitch.dial.powerLo ?? 80)) / 2
      let stop = ((pitch.dial.releaseHi ?? 48) + (pitch.dial.releaseLo ?? 32)) / 2
      func arm(_ angle: Double) throws {
        let a = angle * .pi / 180
        pitch.sample(CGPoint(x: sin(a), y: cos(a)))
        try pitch.tick(dt)
      }
      try arm(0)
      var a = -5.0
      try arm(a)
      while a > -back {
        a = max(-back, a - 400 * dt)
        try arm(a)
      }
      while a < stop {
        a = min(stop, a + 2400 * dt)
        try arm(a)
      }
      pitch.sample(nil)
      try pitch.tick(dt)
      guard pitch.playing else { throw ReviewError.noRelease }
      if mode == "timing" { return }
      if mode == "flight" {
        for _ in 0..<22 { try pitch.tick(dt) }
      } else {
        for _ in 0..<2000 where pitch.result == nil { try pitch.tick(dt) }
        guard pitch.result != nil else { throw ReviewError.noRest }
      }
    }
    private enum ReviewError: Error { case noRelease, noRest }
  #endif
}
