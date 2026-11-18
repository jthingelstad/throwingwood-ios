import KubbRenderer
import UIKit

@MainActor final class BoardView: UIView {
  let pitch: PitchSession
  private let model: GameModel
  private var display: CADisplayLink?, previous: CFTimeInterval?
  private var active = false
  private enum Gesture { case target, tap, dial, stance, walk, raise, punishment }
  private var gesture: Gesture?
  private var tracking: UITouch?
  private var startPoint = CGPoint.zero, moved = false
  private var lastDialPoint: CGPoint?
  #if targetEnvironment(simulator)
    private var reviewReady = false, signalled = false
    private let reviewMode = ProcessInfo.processInfo.environment["PITCH_REVIEW"]
    private let matchReview = ProcessInfo.processInfo.environment["MATCH_REVIEW"]
    private var timing = FrameTiming()
  #endif

  init(pitch: PitchSession, model: GameModel) {
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
  func wake() {
    #if targetEnvironment(simulator)
      if reviewReady && (matchReview != nil || (reviewMode != nil && reviewMode != "timing")) {
        return
      }
    #endif
    if display?.isPaused == true {
      previous = nil
      display?.isPaused = false
    }
  }
  func stop() {
    display?.invalidate()
    display = nil
    previous = nil
    cancel()
  }
  private func cancel() {
    if gesture == .walk { pitch.walk(drag: .zero) }
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
      if let mode = matchReview, !bounds.isEmpty {
        if !reviewReady {
          reviewReady = true
          run {
            if mode == "flight" { try prepareReview("flight") }
            if mode == "verdict" { try prepareReview("rest") }
            if mode == "plan" {
              try pitch.togglePlan()
              for _ in 0..<90 { try pitch.tick(1.0 / 60) }
            }
            if mode == "computer" { for _ in 0..<32 { try pitch.tick(1.0 / 60) } }
          }
        }
        link.isPaused = true
        return
      }
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
    let backdrop = model.screen == .home || model.screen == .options
    PitchRenderer.draw(
      in: ctx, size: bounds.size, camera: pitch.camera,
      scene: backdrop ? pitch.scene.scenery : pitch.scene)
    #if targetEnvironment(simulator)
      if let mode = matchReview, !signalled, model.error == nil {
        let ready =
          switch mode {
          case "home": model.screen == .home
          case "options": model.screen == .options
          case "aim": model.screen == .match && pitch.canAim
          case "menu": model.screen == .menu
          case "verdict": pitch.result != nil
          case "plan": pitch.plan
          case "flight": pitch.playing
          case "handoff": pitch.handoff != nil
          case "raise", "punish": pitch.need?.kind == mode
          case "computer": reviewReady && pitch.need?.cpu == true
          case "winner": pitch.need?.winner != nil && model.screen == .match
          case "sheet": model.sheet?.done == true && model.screen == .sheet
          default: false
          }
        if ready {
          signalled = true
          try? Data(mode.utf8).write(
            to: URL.temporaryDirectory.appending(path: "review-ready"), options: .atomic)
        }
      }
    #endif
    let hud = PracticeHUD(context: ctx, size: bounds.size)
    if model.screen == .match, pitch.handoff == nil {
      if pitch.need?.kind == "throw" {
        let width = min(74, bounds.width * 0.18)
        let left = (pitch.marker(in: bounds.size)?.x ?? 0) > bounds.midX
        let x = left ? 14 : bounds.width - width - 14
        pitch.scene.drawMap(
          in: ctx,
          rect: CGRect(x: x, y: safeAreaInsets.top + 75, width: width, height: width * 1.65))
      }
      for (end, p) in pitch.endLabels(in: bounds.size) { hud.endLabel(end, at: p) }
    }
    for burst in pitch.bursts {
      if let point = burst.point(size: bounds.size, camera: pitch.camera) {
        hud.burst(burst, at: point)
      }
    }
    if model.screen == .practice || model.screen == .match, !pitch.playing,
      pitch.handoff == nil, pitch.need == nil || pitch.need?.kind == "throw"
    {
      hud.dial(pitch.dial, at: hub, radius: radius, showHint: model.screen == .practice)
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard !pitch.playing, tracking == nil, let t = touches.first else { return }
    let p = t.location(in: self)
    startPoint = p
    moved = false
    if pitch.need?.kind == "raise" {
      gesture = .raise
    } else if pitch.need?.kind == "punish" {
      gesture = .punishment
      run { try pitch.movePunishment(to: p, size: bounds.size) }
    } else if !pitch.canAim {
      return
    } else if hypot(p.x - hub.x, p.y - hub.y) <= 1.25 * radius {
      gesture = .dial
      pitch.beginDial()
      wake()
      sampleDial(p)
    } else if pitch.walking {
      gesture = .walk
      wake()
    } else if let mark = pitch.marker(in: bounds.size), hypot(p.x - mark.x, p.y - mark.y) < 56 {
      gesture = .target
    } else if let stance = pitch.stancePoint(in: bounds.size),
      hypot(p.x - stance.x, p.y - stance.y) < 44
    {
      gesture = .stance
    } else {
      gesture = .tap
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
    moved = moved || hypot(p.x - startPoint.x, p.y - startPoint.y) > 10
    switch gesture {
    case .walk:
      pitch.walk(drag: CGPoint(x: p.x - startPoint.x, y: p.y - startPoint.y))
      wake()
    case .dial: sampleDial(p)
    case .target: run { try pitch.target(p, size: bounds.size, snap: false) }
    case .stance: run { try pitch.stance(at: p, size: bounds.size) }
    case .punishment: run { try pitch.movePunishment(to: p, size: bounds.size) }
    case .tap, .raise, nil: break
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
    case .tap:
      if !moved {
        run { try pitch.target(t.location(in: self), size: bounds.size, snap: true, tap: true) }
      }
    case .raise:
      if !moved { run { try pitch.raise(at: t.location(in: self), size: bounds.size) } }
    case .walk: pitch.walk(drag: .zero)
    case .stance, .punishment, nil: break
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
