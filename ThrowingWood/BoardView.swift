import KubbRenderer
import UIKit

@MainActor final class BoardView: UIView {
  let pitch: PitchSession
  private let model: GameModel
  private var display: CADisplayLink?, previous: CFTimeInterval?
  private var active = false
  private enum Gesture { case aim, dial, body, zone, track, stance, raise, punishment }
  private var gesture: Gesture?
  private var tracking: UITouch?
  /// Fingers on the watcher's free camera, at their last place (one turns and tilts,
  /// two pinch, twist and slide).
  private var freeTouches: [(touch: UITouch, at: CGPoint)] = []
  private var startPoint = CGPoint.zero, moved = false
  private var lastAimPoint = CGPoint.zero
  private var lastDialPoint: CGPoint?
  /// The linear meter's grab: the press's offset from the knob's home.
  private var meterGrab: CGFloat = 0
  /// The lying kubb as drawn when a press landed on it: the press may tip it up (RaiseTouch).
  private var raiseShape: RaiseTouch.Geometry?
  /// A finger turning the clock from beside its ring (drawn as a spoke to it).
  private var besideRing = false
  /// A stroke from the throw zone or beside the ring: the engine takes the
  /// press on one frame, then this, the finger, on the next.
  private var pendingDial: CGPoint?, pendingLift = false
  /// The nudge (ThrowNudge.swift): when the player is stuck on their own throw.
  private var nudge = NudgeTrigger(thrown: UserDefaults.standard.integer(forKey: "pitch.throwsMade"))
  private var nudgeClock: CFTimeInterval?
  private var nudgeShow = (show: false, t: 0.0, alpha: 0.0)
  private var nudgeAim = false, nudgeWasEligible = false, nudgeEnd: Int?
  private var nudgeWake: Timer?
  #if targetEnvironment(simulator)
    private var reviewNudge: Double?
  #endif
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
    nudgeWake?.invalidate()
    nudgeWake = nil
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
    // time away (the menu, the app in the background) is not time spent stuck
    nudgeWake?.invalidate()
    nudgeWake = nil
    nudgeClock = nil
    nudgeWasEligible = false
    cancel()
    pitch.cancelHeld()
  }
  private func cancel() {
    if gesture == .dial {
      run { try pitch.cancelInput() }
      nudgeEnd = 0
    }
    if gesture == .body { nudge.pressEnded(thrown: false) }
    if gesture == .raise {
      pitch.raiseCancel()
      setNeedsDisplay()
    }
    raiseShape = nil
    tracking = nil
    freeTouches = []
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
        // a landscape review prepares nothing until the screen has turned
        if !ReviewOrientation.settled(bounds.size) { return }
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
            // the nudge frozen a second in, the draw back, beside the plan's sliders
            if mode == "nudge" { reviewNudge = 1.0 }
            if mode == "raisedrag", let g = pitch.raiseGeometry(in: bounds.size) {
              // a finger tipping the kubb up toward end 2, past half way: that end lit
              let a = g.caps[0], b = g.caps[1]
              let l = max(1, hypot(b.x - a.x, b.y - a.y))
              let go = max(RaiseTouch.travelMin, l * RaiseTouch.travelK) * 0.7
              let from = CGPoint(x: a.x + (b.x - a.x) * 0.3, y: a.y + (b.y - a.y) * 0.3)
              try pitch.raiseDrag(
                g, from: from, to: CGPoint(x: from.x + (b.x - a.x) / l * go, y: from.y + (b.y - a.y) / l * go))
            }
            if mode == "punishwhy", let at = pitch.groundPoint(x: 2.4, y: 0.15, in: bounds.size) {
              // the kubb dragged beside the near right stake: refused, with the reason
              try pitch.movePunishment(to: at, size: bounds.size)
            }
            if mode == "raiserefused", let i = pitch.need?.ends?.firstIndex(where: { $0.ok == false }) {
              // a tap on the end the rules refuse: nothing sent, the allowed end lit
              try pitch.raiseTap(i)
            }
            if mode == "stand" {
              // a finger held on STAND, toward the right and back: the caption says where
              pitch.stand(fx: 0.8, fy: 0.75, phase: .down)
              for _ in 0..<3 { try pitch.tick(1.0 / 60) }
            }
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
        if !ReviewOrientation.settled(bounds.size) { return }
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
      if gesture == .dial, nudgeEnd == nil, pitch.playing {
        // the engine let go with the finger still down (a stop on the mark, or the
        // sky angle): that is a throw too, and the lift that follows is no press
        nudgeEnd = 0
        gesture = nil
      }
      if let n = nudgeEnd, pendingDial == nil {
        // the press has ended: a throw if the engine has one in flight within a few frames
        if pitch.playing || n >= 6 {
          nudgeEnd = nil
          nudge.pressEnded(thrown: pitch.playing)
          if pitch.playing { UserDefaults.standard.set(nudge.thrown, forKey: "pitch.throwsMade") }
        } else {
          nudgeEnd = n + 1
        }
      }
      stepNudge()
      if ticked || nudgeShow.show || nudgeEnd != nil {
        if pitch.playing { gesture = nil }
        model.refresh()
        setNeedsDisplay()
        #if targetEnvironment(simulator)
          if reviewMode == "timing", pitch.playing, pitch.result == nil { timing.tick(start) }
        #endif
      } else if gesture == nil && !fed && !pitch.playing && pitch.result == nil && !pitch.wantsFrames {
        link.isPaused = true
        previous = nil
        // sleep until the nudge would start
        if nudgeEligible {
          nudgeWake = Timer.scheduledTimer(withTimeInterval: max(0.05, nudge.untilWanted), repeats: false) {
            [weak self] _ in MainActor.assumeIsolated { self?.wake() }
          }
        }
      }
    } catch {
      model.error = error.localizedDescription
      stop()
    }
  }

  /// Is the player's own throw waiting, with nothing between them and the meter?
  private var nudgeAimWanted: Bool {
    (model.screen == .practice || model.screen == .match) && pitch.canAim && pitch.handoff == nil
  }
  private var nudgeEligible: Bool {
    // a finger on a slider or on STAND is busy elsewhere: those presses never
    // reach this view's touches, so they are asked of the pitch
    nudgeAimWanted && !pitch.showsSide && tracking == nil && pendingDial == nil && nudgeEnd == nil
      && pitch.held == nil && !pitch.standHeld && pitch.dial.phase == "idle"
  }
  /// Time passing for the nudge, on the wall clock (the display link sleeps).
  private func stepNudge() {
    let now = CACurrentMediaTime()
    let eligible = nudgeEligible
    // The trigger counts time only while eligible, and fades the ghost out on
    // the time it is given while it is not. The link may have slept through an
    // interval the nudge had no business in (the side view open): the first
    // eligible step after it would otherwise count all of that as time stuck.
    let dt = eligible && !nudgeWasEligible ? 0 : nudgeClock.map { now - $0 } ?? 0
    nudgeClock = now
    nudgeWasEligible = eligible
    // a held slider or STAND is input too: the wait starts again after it
    if pitch.held != nil || pitch.standHeld { nudge.input() }
    let aim = nudgeAimWanted
    if aim && !nudgeAim { nudge.aimBegan() }
    nudgeAim = aim
    let was = nudgeShow
    nudgeShow = nudge.step(dt, eligible: eligible)
    if nudgeShow.show || was.show { setNeedsDisplay() }
  }

  /// The meter on the screen: the player's choice where it has its room.
  var meter: MeterLayout { model.meter.layout(bounds: bounds, safe: safeAreaInsets) }
  var insets: ScreenInsets {
    let i = safeAreaInsets
    return ScreenInsets(top: i.top, left: i.left, bottom: i.bottom, right: i.right)
  }

  /// The screen turned (or was resized) under a finger: drawing and hit testing
  /// both follow the new size at once, so a held gesture would map its next move
  /// to another place. Let go of it cleanly instead, sending nothing more.
  private var laidOut = CGSize.zero
  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size != laidOut else { return }
    let first = laidOut == .zero
    laidOut = bounds.size
    if !first {
      cancel()
      pitch.cancelHeld()
      model.refresh()
    }
    setNeedsDisplay()
  }

  #if targetEnvironment(simulator)
    private var lastReviewLayout = ""
    /// The review's layout on a phone on its side, for the review tools: the safe
    /// area iOS gives, the meter, the plan block's place and the minimap, in
    /// points. Written only when it changes.
    private func writeReviewLayout() {
      guard WideLayout.isWide(bounds.size), model.screen == .match else { return }
      let s = insets
      let plan = WideLayout.plan(
        meter: meter, size: bounds.size, safe: s, side: model.meter.side,
        trayWidth: model.online == nil ? 0 : WideLayout.trayWidth)
      func r(_ f: CGRect) -> [Double] {
        f.isNull ? [] : [f.minX, f.minY, f.width, f.height].map { (Double($0) * 10).rounded() / 10 }
      }
      var json: [String: Any] = [
        "size": [Double(bounds.width), Double(bounds.height)],
        "safe": ["top": Double(s.top), "left": Double(s.left), "bottom": Double(s.bottom), "right": Double(s.right)],
        "side": model.meter.side.rawValue, "meter": r(WideLayout.meterBox(meter, size: bounds.size, safe: s, side: model.meter.side)),
        "block": r(plan.block), "edge": plan.edge?.rawValue ?? "beside", "minimap": r(plan.minimap),
      ]
      if let c = meter.clock { json["clock"] = [Double(c.center.x), Double(c.center.y), Double(c.radius)] }
      if let floor = pitch.stillFloor {
        // the raise and punishment bar's top and the scene's lowest working point
        json["bar"] = r(WideLayout.bar(height: floor - s.bottom - WideLayout.barLift, size: bounds.size, safe: s))
        json["lowest"] = pitch.stillLowestY(in: bounds.size).map { ($0 * 10).rounded() / 10 }
      }
      guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8), text != lastReviewLayout
      else { return }
      lastReviewLayout = text
      try? data.write(to: URL.temporaryDirectory.appending(path: "review-layout.json"), options: .atomic)
    }
  #endif

  /// The watcher's wide view follows the screen: on while this board watches a match
  /// (the engine frames the whole pitch inside the safe area), off for a player.
  private func syncWide() {
    guard !bounds.isEmpty else { return }
    let was = pitch.wideOn
    do {
      if pitch.watching && model.screen == .match {
        try pitch.watchWide(size: bounds.size, safe: insets)
      } else if pitch.wideOn {
        try pitch.endWide()
      }
    } catch {
      model.error = error.localizedDescription
    }
    isMultipleTouchEnabled = pitch.freeOn
    if !pitch.freeOn { freeTouches = [] }
    if was != pitch.wideOn { DispatchQueue.main.async { [weak self] in self?.model.refresh() } }
  }

  /// The free camera takes the pitch's touches: watching in the wide view, nothing
  /// over the pitch (the hand-off or winner card).
  private var freeWanted: Bool {
    pitch.freeOn && model.screen == .match && pitch.handoff == nil && pitch.need?.winner == nil
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    syncWide()
    #if targetEnvironment(simulator)
      let start = CACurrentMediaTime()
      defer { if reviewMode == "timing" { timing.draw(start) } }
    #endif
    let backdrop = model.screen == .home || model.screen == .options
    // the screen's scene (GameModel.shownScene): its look, and its effects for
    // the throws it shows, calmed by Reduce Motion
    let look = model.shownScene
    let reduced = UIAccessibility.isReduceMotionEnabled
    pitch.useLook(look, reduced: reduced)
    PitchRenderer.draw(
      in: ctx, size: bounds.size, camera: backdrop ? pitch.camera : pitch.shownCamera,
      scene: backdrop ? pitch.scene.scenery : pitch.scene, look: look,
      effects: backdrop ? nil : pitch.effects, time: pitch.lookTime, reduced: reduced)
    #if targetEnvironment(simulator)
      if reviewMode != nil || matchReview != nil { writeReviewLayout() }
      if let mode = reviewMode, matchReview == nil, reviewReady, !signalled, model.error == nil,
        ReviewOrientation.settled(bounds.size)
      {
        signalled = true
        try? Data(mode.utf8).write(
          to: URL.temporaryDirectory.appending(path: "review-ready"), options: .atomic)
      }
      if let mode = matchReview, !signalled, model.error == nil, ReviewOrientation.settled(bounds.size) {
        let ready =
          switch mode {
          case "home": model.screen == .home
          case "options": model.screen == .options
          case "settings": model.screen == .settings
          case "aim", "nudge", "coach", "coachslow": model.screen == .match && pitch.canAim
          case "menu": model.screen == .menu
          case "verdict": pitch.result != nil
          case "plan": pitch.plan
          case "arc": pitch.held == .arc
          case "tilt": pitch.held == .side
          case "stand": pitch.standHeld
          case "raisemany", "raiseauto", "raiserest", "raisedrag", "raiserefused": pitch.need?.kind == "raise"
          case "flight": pitch.playing
          case "handoff": pitch.handoff != nil
          case "raise", "punish": pitch.need?.kind == mode
          case "punishwhy": pitch.need?.kind == "punish" && pitch.placement?.ok == false
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
      if pitch.need?.kind == "throw", !pitch.wideOn {
        if WideLayout.isWide(bounds.size) {
          // on its side: beside the plan block at the far edge, toward the middle
          // (the web's wide minimap, layout.js planAt)
          // (over the block in a narrow window beside the linear meter, or not at all)
          let map = WideLayout.plan(
            meter: meter, size: bounds.size, safe: insets, side: model.meter.side,
            trayWidth: model.online == nil ? 0 : WideLayout.trayWidth).minimap
          if !map.isNull { pitch.scene.drawMap(in: ctx, rect: map, look: look) }
        } else {
          let width = min(74, bounds.width * 0.18)
          let left = (pitch.marker(in: bounds.size)?.x ?? 0) > bounds.midX
          let x = left ? 14 : bounds.width - width - 14
          pitch.scene.drawMap(
            in: ctx,
            rect: CGRect(x: x, y: safeAreaInsets.top + 75, width: width, height: width * 1.65), look: look)
        }
      }
      for e in pitch.raiseEnds(in: bounds.size) { hud.endLabel(e) }
      if pitch.held == .side, !pitch.throwsKubb, let circle = pitch.marker(in: bounds.size) {
        hud.leaningBaton(at: circle, tiltDegrees: Double(pitch.sideStep ?? 0))
      }
    }
    for burst in pitch.bursts {
      if let point = burst.point(size: bounds.size, camera: pitch.shownCamera) {
        hud.burst(burst, at: point)
      }
    }
    if model.screen == .practice || model.screen == .match, !pitch.playing, !pitch.wideOn,
      pitch.handoff == nil, pitch.need == nil || pitch.need?.kind == "throw"
    {
      let hint = model.screen == .practice
      let meter = meter
      var ghost: NudgeFrame?
      var show = nudgeShow
      #if targetEnvironment(simulator)
        if let t = reviewNudge { show = (true, t, 1) }
      #endif
      if show.show {
        var f = NudgeFrame.at(
          show.t, swing: NudgeSwing(pitch.dial),
          reduced: UIAccessibility.isReduceMotionEnabled
            || ProcessInfo.processInfo.environment["NUDGE_STILL"] != nil)
        f.alpha *= show.alpha
        ghost = f
      }
      // the ghost's words on the plate while the engine still says WIND BACK
      let caption = pitch.dial.prompt == "WIND BACK" ? ghost?.caption : nil
      switch meter {
      case .clock(let c):
        let finger = gesture == .dial && besideRing ? lastDialPoint : nil
        hud.dial(
          pitch.dial, at: c.center, radius: c.radius, showHint: hint, finger: finger,
          prompt: caption.map { Optional($0) },
          hintBeside: WideLayout.isWide(bounds.size) ? model.meter.side : nil)
      case .linear(let m):
        hud.linear(
          pitch.dial, m, held: gesture == .dial, prompt: linearWords(caption ?? pitch.dial.prompt))
        if hint { hud.linearHint(m, safeBottom: safeAreaInsets.bottom) }
      }
      // the coach line: words for the thrower, never while watching, over the
      // nudge's ghost (which shows the same stroke) or with a slider's caption
      var slow = pitch.coachSlow
      #if targetEnvironment(simulator)
        if matchReview == "coachslow" { slow = true }
      #endif
      if pitch.canAim, ghost == nil, pitch.held == nil,
        let line = Coach.line(thrown: nudge.thrown, slow: slow, stage: Coach.stage(pitch.dial))
      {
        let place = PracticeHUD.coachPlace(meter, wide: WideLayout.isWide(bounds.size))
        var plans = model.planFrames.values.map { convert($0, from: nil) }
        if WideLayout.isWide(bounds.size), meter.linear != nil {
          // on its side the tab is level with the far baseline: the line keeps to
          // the meter's half, `planClear` short of the throwing line and its target
          let c = bounds.midX
          plans.append(CGRect(x: c - WideLayout.planClear, y: 0, width: 2 * WideLayout.planClear, height: bounds.height))
        }
        let room = PracticeHUD.coachWidth(
          place, screen: bounds.size, safeLeft: safeAreaInsets.left, safeRight: safeAreaInsets.right,
          plans: plans)
        // on a phone on its side the lead sits level with the line, toward the middle
        let beside: PracticeHUD.CoachAlign? =
          WideLayout.isWide(bounds.size) ? (place.anchor > bounds.midX ? .left : .right) : nil
        hud.coach(line, place, left: room.left, width: room.width, beside: beside)
      }
      if let ghost {
        // on its side the flick's top stays under the captions or the practice header
        var ceiling: CGFloat = 0
        if WideLayout.isWide(bounds.size) {
          ceiling =
            model.screen == .practice
            ? WideLayout.practiceHeader(size: bounds.size, safe: insets, meter: meter).maxY
            : WideLayout.caption(
              size: bounds.size, safe: insets, trayWidth: model.online == nil ? 0 : WideLayout.trayWidth,
              meter: meter, side: model.meter.side
            ).maxY
        }
        hud.nudge(
          ghost, swing: NudgeSwing(pitch.dial), on: meter, safeLeft: safeAreaInsets.left,
          safeRight: safeAreaInsets.right, besideFree: model.screen == .practice, ceiling: ceiling)
      }
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    if freeWanted {
      for t in touches where freeTouches.count < 2 { freeTouches.append((t, t.location(in: self))) }
      return
    }
    guard pitch.acceptsInput, !pitch.playing, tracking == nil, let t = touches.first else { return }
    let p = t.location(in: self)
    startPoint = p
    moved = false
    besideRing = false
    stepNudge()
    nudge.input()
    if pitch.need?.kind == "raise" {
      gesture = .raise
      // a press on the kubb may become a drag that tips it up
      let g = pitch.raiseGeometry(in: bounds.size)
      raiseShape = RaiseTouch.on(g, p) ? g : nil
    } else if pitch.need?.kind == "punish" {
      gesture = .punishment
      run { try pitch.movePunishment(to: p, size: bounds.size) }
    } else if !pitch.canAim {
      return
    } else if let claim = meter.first(p, wide: WideLayout.isWide(bounds.size)) {
      if claim == .zone {
        // the linear meter's body on a wide screen: a tap still aims at the
        // kubb behind it; a drag strokes the knob, as in the throw zone
        nudge.zonePressed()
        gesture = .zone
      } else if case .meter(let grab) = claim {
        nudge.meterPressed()
        gesture = .dial
        meterGrab = grab
        pitch.beginDial()
        wake()
        sampleDial(p)
      } else {
        nudge.meterPressed()
        gesture = .body
      }
    } else if let stance = pitch.stancePoint(in: bounds.size),
      hypot(p.x - stance.x, p.y - stance.y) < 44
    {
      gesture = .stance
    } else if let claim = meter.after(p, in: bounds.size, aimable: pitch.tapCouldAim(p, size: bounds.size)) {
      if claim == .beside { nudge.meterPressed() } else { nudge.zonePressed() }
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
  /// The fingers on the free camera moved: one turns round the pitch and raises or
  /// lowers the eye; two pinch closer or farther, twist to turn, and slide the ground.
  private func moveFree(_ touches: Set<UITouch>) {
    guard freeWanted else {
      freeTouches = []
      return
    }
    for i in freeTouches.indices where touches.contains(freeTouches[i].touch) {
      let from = freeTouches[i].at, to = freeTouches[i].touch.location(in: self)
      if freeTouches.count == 1 {
        pitch.moveFree { $0.oneFinger(dx: Double(to.x - from.x), dy: Double(to.y - from.y)) }
      } else {
        let other = freeTouches[1 - i].at
        pitch.moveFree { $0.twoFingers(from: from, to: to, other: other) }
      }
      freeTouches[i].at = to
    }
    model.refresh()
    setNeedsDisplay()
  }

  private func sampleDial(_ p: CGPoint) {
    lastDialPoint = p
    pitch.sample(meter.unit(p, grab: meterGrab))
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    if !freeTouches.isEmpty {
      moveFree(touches)
      return
    }
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
    case .dial:
      if pendingDial != nil { pendingDial = p } else { sampleDial(p) }
    case .zone where moved, .track where moved:
      // a drag after all: the press is where the stroke starts (the knob's home
      // for the zone), fed this frame, and the finger the next, as a grab is
      let grab = meter.press(gesture == .zone ? .zone : .besidePending, from: startPoint, moved: true)
      meterGrab = if case .stroke(let g) = grab { g } else { 0 }
      besideRing = gesture != .zone
      gesture = .dial
      nudge.meterPressed()
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
    case .raise where moved:
      if let g = raiseShape { run { try pitch.raiseDrag(g, from: startPoint, to: p) } }
    case .zone, .track, .raise, .body, nil: break
    }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    if !freeTouches.isEmpty {
      freeTouches.removeAll { touches.contains($0.touch) }
      return
    }
    guard pitch.acceptsInput else {
      cancel()
      return
    }
    guard let t = tracking, touches.contains(t) else { return }
    // the finger was down until now: a sleeping link saw none of it, and the
    // step after the lift would count the whole press as time stuck
    stepNudge()
    switch gesture {
    case .dial:
      nudgeEnd = 0
      wake()
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
      // a tap: the end it means; a drag: past half way it stands, short of that nothing
      if !moved {
        let p = t.location(in: self)
        if let i = pitch.raisePick(at: p, size: bounds.size) { run { try pitch.raiseTap(i) } }
      } else {
        run { try pitch.raiseLetGo() }
      }
      raiseShape = nil
      wake()
    case .body:
      nudge.pressEnded(thrown: false)
      // a second fumble moves the nudge's deadline up: the sleeping link's
      // timer was set for the old one
      wake()
    case .stance, .punishment, nil: break
    }
    tracking = nil
    gesture = nil
    besideRing = false
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    if !freeTouches.isEmpty {
      freeTouches.removeAll { touches.contains($0.touch) }
      return
    }
    let body = gesture == .body
    if tracking != nil { stepNudge() }
    cancel()
    if body { wake() }
  }

  #if targetEnvironment(simulator)
    /// Review stills use the actual pitch, dial input, clock and drawing layers.
    private func prepareReview(_ mode: String) throws {
      guard ["aim", "flight", "rest", "timing", "wind", "beside", "marks", "nudge"].contains(mode) else { return }
      let dt = 1.0 / 60
      // Snap the circle one kubb to the right of its initial target.
      if let m = pitch.marker(in: bounds.size) {
        try pitch.target(
          CGPoint(x: m.x + bounds.width * 0.22, y: m.y), size: bounds.size, snap: true)
      }
      if mode == "aim" { return }
      if mode == "nudge" {
        // the nudge frozen at NUDGE_AT s into its loop (NUDGE_STILL: reduced motion)
        reviewNudge = Double(ProcessInfo.processInfo.environment["NUDGE_AT"] ?? "") ?? 1.0
        return
      }
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
