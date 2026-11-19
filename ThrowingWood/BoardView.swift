import KubbRenderer
import UIKit

@MainActor final class BoardView: UIView {
  let pitch: PitchSession
  private let model: GameModel
  private var display: CADisplayLink?, previous: CFTimeInterval?
  private var active = false
  private enum Gesture { case aim, dial, body, zone, track, stance, walk, raise, punishment }
  private var gesture: Gesture?
  private var tracking: UITouch?
  private var startPoint = CGPoint.zero, moved = false
  private var lastAimPoint = CGPoint.zero
  private var lastDialPoint: CGPoint?
  /// The linear meter's grab: the press's offset from the knob's home.
  private var meterGrab: CGFloat = 0
  /// A finger turning the clock from beside its ring (drawn as a spoke to it).
  private var besideRing = false
  /// A stroke from the throw zone or beside the ring: the engine takes the
  /// press on one frame, then this, the finger, on the next.
  private var pendingDial: CGPoint?, pendingLift = false
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
      "Practice pitch. Tap to aim, or drag anywhere to move the circle. Wind the dial back, flick forward and lift to throw."
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
    pitch.cancelSlide()
  }
  private func cancel() {
    if gesture == .walk { pitch.walk(drag: .zero) }
    if gesture == .dial { run { try pitch.cancelInput() } }
    tracking = nil
    gesture = nil
    besideRing = false
    pendingDial = nil
    pendingLift = false
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
      if ProcessInfo.processInfo.environment["ONLINE_REVIEW"] == "flight", pitch.playing {
        if !reviewReady {
          reviewReady = true
          run { for _ in 0..<22 { try model.online?.tick(1.0 / 60) } }
        }
        link.isPaused = true
        return
      }
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
            if mode == "arc" || mode == "tilt" {
              // A finger held on the slider three quarters along: the side view eases in.
              pitch.slide(mode == "arc" ? .arc : .side, to: 0.75, phase: .down)
              for _ in 0..<90 { try pitch.tick(1.0 / 60) }
            }
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
      let ticked = try model.online?.tick(dt) ?? pitch.tick(dt)
      let fed = pendingDial != nil
      if let q = pendingDial {
        pendingDial = nil
        sampleDial(q)
        if pendingLift { pitch.sample(nil) }
        pendingLift = false
      }
      if ticked {
        if pitch.playing { gesture = nil }
        model.refresh()
        setNeedsDisplay()
        #if targetEnvironment(simulator)
          if reviewMode == "timing", pitch.playing, pitch.result == nil { timing.tick(start) }
        #endif
      } else if gesture == nil && !fed && !pitch.playing && pitch.result == nil && !pitch.wantsFrames {
        link.isPaused = true
        previous = nil
      }
    } catch {
      model.error = error.localizedDescription
      stop()
    }
  }

  /// The meter on the screen: the player's choice where it has its room.
  var meter: MeterLayout { model.meter.layout(bounds: bounds, safe: safeAreaInsets) }
  var clock: ClockMeter { ClockMeter(bounds: bounds, bottomInset: safeAreaInsets.bottom) }
  var radius: CGFloat { clock.radius }
  var hub: CGPoint { clock.center }

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
      if let mode = reviewMode, matchReview == nil, reviewReady, !signalled, model.error == nil {
        signalled = true
        try? Data(mode.utf8).write(
          to: URL.temporaryDirectory.appending(path: "review-ready"), options: .atomic)
      }
      if let mode = matchReview, !signalled, model.error == nil {
        let ready =
          switch mode {
          case "home": model.screen == .home
          case "options": model.screen == .options
          case "aim": model.screen == .match && pitch.canAim
          case "menu": model.screen == .menu
          case "verdict": pitch.result != nil
          case "plan": pitch.plan
          case "arc": pitch.held == .arc
          case "tilt": pitch.held == .side
          case "raisemany", "raiseauto", "raiserest": pitch.need?.kind == "raise"
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
      if pitch.held == .side, !pitch.throwsKubb, let circle = pitch.marker(in: bounds.size) {
        hud.leaningBaton(at: circle, tiltDegrees: Double(pitch.sideStep ?? 0))
      }
    }
    for burst in pitch.bursts {
      if let point = burst.point(size: bounds.size, camera: pitch.camera) {
        hud.burst(burst, at: point)
      }
    }
    if model.screen == .practice || model.screen == .match, !pitch.playing,
      pitch.handoff == nil, pitch.need == nil || pitch.need?.kind == "throw"
    {
      let hint = model.screen == .practice
      switch meter {
      case .clock(let c):
        let finger = gesture == .dial && besideRing ? lastDialPoint : nil
        hud.dial(pitch.dial, at: c.center, radius: c.radius, showHint: hint, finger: finger)
      case .linear(let m):
        hud.linear(pitch.dial, m, held: gesture == .dial, prompt: linearWords(pitch.dial.prompt))
        if hint { hud.linearHint(m, safeBottom: safeAreaInsets.bottom) }
      }
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard pitch.acceptsInput, !pitch.playing, tracking == nil, let t = touches.first else { return }
    let p = t.location(in: self)
    startPoint = p
    moved = false
    besideRing = false
    if pitch.need?.kind == "raise" {
      gesture = .raise
    } else if pitch.need?.kind == "punish" {
      gesture = .punishment
      run { try pitch.movePunishment(to: p, size: bounds.size) }
    } else if !pitch.canAim {
      return
    } else if let claim = meter.first(p) {
      if case .meter(let grab) = claim {
        gesture = .dial
        meterGrab = grab
        pitch.beginDial()
        wake()
        sampleDial(p)
      } else {
        gesture = .body
      }
    } else if pitch.walking {
      gesture = .walk
      wake()
    } else if let stance = pitch.stancePoint(in: bounds.size),
      hypot(p.x - stance.x, p.y - stance.y) < 44
    {
      gesture = .stance
    } else if let claim = meter.after(p, in: bounds.size, aimable: pitch.tapCouldAim(p, size: bounds.size)) {
      switch claim {
      case .beside:  // nothing to aim at under it: the arm turns at once
        gesture = .dial
        meterGrab = 0
        besideRing = true
        pitch.beginDial()
        wake()
        sampleDial(p)
      case .besidePending: gesture = .track  // a tap still aims; a drag turns the arm
      default: gesture = .zone  // a tap still aims; a drag strokes the knob
      }
    } else {
      // A tap puts the circle there; a drag anywhere moves it from where it is (AimDrag).
      gesture = .aim
      lastAimPoint = p
    }
    tracking = t
  }
  private func sampleDial(_ p: CGPoint) {
    lastDialPoint = p
    pitch.sample(meter.unit(p, grab: meterGrab))
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard pitch.acceptsInput else {
      cancel()
      return
    }
    guard let t = tracking, touches.contains(t) else { return }
    let p = t.location(in: self)
    let slop = gesture == .aim ? AimDrag.slop : MeterLayout.tapSlop
    let crossed = !moved && hypot(p.x - startPoint.x, p.y - startPoint.y) > slop
    moved = moved || crossed
    switch gesture {
    case .walk:
      pitch.walk(drag: CGPoint(x: p.x - startPoint.x, y: p.y - startPoint.y))
      wake()
    case .dial:
      if pendingDial != nil { pendingDial = p } else { sampleDial(p) }
    case .zone where moved, .track where moved:
      // a drag after all: the press is where the stroke starts (the knob's home
      // for the zone), fed this frame, and the finger the next, as a grab is
      if gesture == .zone, let m = meter.linear {
        meterGrab = startPoint.y - m.yHome
      } else {
        meterGrab = 0
        besideRing = true
      }
      gesture = .dial
      pitch.beginDial()
      wake()
      sampleDial(startPoint)
      pendingDial = p
      setNeedsDisplay()
    case .aim:
      // The slop is not travel: the circle starts moving from where the drag became one.
      if crossed { lastAimPoint = p }
      guard moved, p != lastAimPoint else { break }
      let d = CGVector(dx: p.x - lastAimPoint.x, dy: p.y - lastAimPoint.y)
      lastAimPoint = p
      run { try pitch.nudgeAim(by: d) }
    case .stance: run { try pitch.stance(at: p, size: bounds.size) }
    case .punishment: run { try pitch.movePunishment(to: p, size: bounds.size) }
    case .zone, .track, .raise, .body, nil: break
    }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard pitch.acceptsInput else {
      cancel()
      return
    }
    guard let t = tracking, touches.contains(t) else { return }
    switch gesture {
    case .dial:
      let p = t.location(in: self)
      if pendingDial != nil {
        pendingDial = p
        pendingLift = true
      } else {
        if p != lastDialPoint { sampleDial(p) }
        pitch.sample(nil)
      }
    case .aim:
      if moved {
        run { try pitch.settleAim() }
      } else {
        run { try pitch.tapAim(at: t.location(in: self), size: bounds.size) }
      }
    case .zone, .track:
      // a tap in the throw zone or beside the ring aims as a tap on the pitch does
      if !moved {
        run { try pitch.tapAim(at: t.location(in: self), size: bounds.size) }
      }
    case .raise:
      if !moved { run { try pitch.raise(at: t.location(in: self), size: bounds.size) } }
    case .walk: pitch.walk(drag: .zero)
    case .stance, .punishment, .body, nil: break
    }
    tracking = nil
    gesture = nil
    besideRing = false
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }

  #if targetEnvironment(simulator)
    /// Review stills use the actual pitch, dial input, clock and drawing layers.
    private func prepareReview(_ mode: String) throws {
      guard ["aim", "flight", "rest", "timing", "wind", "beside", "marks"].contains(mode) else { return }
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
      if mode == "wind" || mode == "beside" {
        // Held at the back of the swing: the meter mid-throw, the finger still down
        // (beside: on the clock from 1.7 radii out, its spoke drawn).
        gesture = .dial
        if mode == "beside", let c = meter.clock {
          besideRing = true
          lastDialPoint = c.point(arm: -back, radius: c.radius * 1.7)
        }
        return
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
        // The next aim, with the last throw's marks on the meter.
        if mode == "marks" { for _ in 0..<2000 where pitch.playing { try pitch.tick(dt) } }
      }
    }
    private enum ReviewError: Error { case noRelease, noRest }
  #endif
}
