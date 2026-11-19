import CoreGraphics
import Foundation

// STAND: where the thrower stands, as one control that shows it (the web's
// src/game/stand-pad.js, its numbers and words). It replaces WALK, a mode
// switch carried over from the Playdate's held A (Jamie, 2026-11-19: "Can you
// audit the control surface from a broader level that would catch these type
// of odd engagements. It is all a hangover from us starting on play date").
// While WALK was on, a drag on the pitch walked the thrower like a joystick.
//
// The thrower's own spot is below the screen in the thrower's view, so there is
// nothing on the pitch to take hold of. STAND is a plate in the plan instead:
// the throwing line from above, the ground behind it the rules allow, the
// advantage line when there is one, and a ring where the thrower stands. A
// press anywhere on it puts the ring under the finger; a drag follows by
// position. The engine's setStance holds it to the line's ends, `backMax`
// behind it and the forward limit.

/// What the engine's aim says about where the thrower may stand.
public struct StandAim: Equatable, Sendable {
  public var projectile: String?
  public var lineY, forwardY, halfWidth, backMax: Double
  public init(
    projectile: String? = "baton", lineY: Double = 0, forwardY: Double? = nil,
    halfWidth: Double = 2.5, backMax: Double = 3
  ) {
    self.projectile = projectile
    self.lineY = lineY
    self.forwardY = forwardY ?? lineY
    self.halfWidth = halfWidth
    self.backMax = backMax
  }
}

public enum StandPad {
  /// m of pitch shown in front of the farthest line the thrower may stand on.
  public static let front = 0.6
  /// m a VoiceOver step moves the thrower (the web's arrow keys).
  public static let keyStep = 0.25
  /// m: nearer the middle or the line than this reads as on it.
  public static let still = 0.05
  /// s the caption stays up after STAND is let go (the web's `standPeek`).
  public static let peek = 1.0

  /// The ground the plate shows: across the line's width, from `backMax`
  /// behind the line to a little in front of the forward limit (the advantage
  /// line for a baton, else the line itself).
  public struct Span: Equatable, Sendable {
    public let x0, x1, yBack, yFront, lineY, limit: Double

    public init(_ aim: StandAim) {
      let fwd = max(aim.lineY, aim.forwardY)
      let limit = aim.projectile == "kubb" ? aim.lineY : fwd
      x0 = -aim.halfWidth
      x1 = aim.halfWidth
      yBack = aim.lineY - aim.backMax
      yFront = limit + StandPad.front
      lineY = aim.lineY
      self.limit = limit
    }

    static func clamp01(_ f: Double) -> Double { f.isFinite ? max(0, min(1, f)) : 0 }

    /// A place on the plate (fx 0 left to 1 right, fy 0 top to 1 bottom; the
    /// top is toward the target) to the ground.
    public func ground(fx: Double, fy: Double) -> (x: Double, y: Double) {
      (x0 + Self.clamp01(fx) * (x1 - x0), yFront - Self.clamp01(fy) * (yFront - yBack))
    }
    /// The ground to a place on the plate.
    public func fraction(x: Double, y: Double) -> (fx: Double, fy: Double) {
      let w = x1 - x0 == 0 ? 1 : x1 - x0
      let h = yFront - yBack == 0 ? 1 : yFront - yBack
      return (Self.clamp01((x - x0) / w), Self.clamp01((yFront - y) / h))
    }
    /// Is there an advantage line to draw (the forward limit ahead of the line)?
    public var advantage: Bool { fraction(x: 0, y: limit).fy < fraction(x: 0, y: lineY).fy - 0.01 }
  }

  static func metres(_ d: Double) -> String {
    String(format: "%.1f M", (abs(d) * 10).rounded() / 10)
  }

  /// Where the thrower stands, in words: "MIDDLE, ON THE LINE",
  /// "1.2 M LEFT, 0.5 M BACK", "0.8 M RIGHT, 1.5 M UP".
  public static func text(x: Double, y: Double, aim: StandAim) -> String {
    let along = y - aim.lineY
    let across = abs(x) < still ? "MIDDLE" : "\(metres(x)) \(x < 0 ? "LEFT" : "RIGHT")"
    let up = abs(along) < still ? "ON THE LINE" : "\(metres(along)) \(along < 0 ? "BACK" : "UP")"
    return "\(across), \(up)"
  }

  /// What STAND does, shown while it is held and a second after, with where
  /// the thrower is. Upper case, as the web's caption is drawn.
  public static func caption(x: Double, y: Double, aim: StandAim) -> String {
    let span = Span(aim)
    let how =
      span.limit > span.lineY + still
      ? "Stand on your line, behind it, or up to the advantage line."
      : "Stand on your line or behind it."
    return "\(text(x: x, y: y, aim: aim)). \(how)".uppercased()
  }

  /// For VoiceOver: "1.2 metres left, 0.5 metres back" (the web's aria words,
  /// with every "m" spoken, where the web's replace stops at the first).
  public static func valueText(x: Double, y: Double, aim: StandAim) -> String {
    text(x: x, y: y, aim: aim).lowercased().replacingOccurrences(of: " m ", with: " metres ")
  }
}

extension PitchSession {
  /// Where the thrower stands now (ground metres), or the line's middle.
  public var standPoint: (x: Double, y: Double) {
    scene.thrower.map { ($0.x, $0.y) } ?? (0, standAim.lineY)
  }

  /// The plate's picture now: the span frozen at the press while held, else the aim's.
  public var standSpan: StandPad.Span { standDrag?.span ?? StandPad.Span(standAim) }

  /// The caption while STAND is held and `StandPad.peek` after, else nil.
  public var standCaption: String? {
    guard standDrag != nil || standPeekLeft > 0 else { return nil }
    let p = standPoint
    return StandPad.caption(x: p.x, y: p.y, aim: standAim)
  }

  public var standValueText: String {
    let p = standPoint
    return StandPad.valueText(x: p.x, y: p.y, aim: standAim)
  }

  /// Is a finger on STAND?
  public var standHeld: Bool { standDrag != nil }

  /// A finger on STAND at (fx, fy) on its picture of the line. Only records the
  /// place: `tick` sends the latest to the engine's `setStance` once a frame. The
  /// ground the picture shows is fixed at the press, so it never shifts under the
  /// finger. `.cancel`: the plate went away under the finger.
  public func stand(fx: Double, fy: Double, phase: SlidePhase) {
    switch phase {
    case .down:
      guard canAim else { return }
      input.reset()
      standDrag = StandDrag(span: StandPad.Span(standAim), fx: fx, fy: fy, dirty: true)
    case .move:
      guard standDrag != nil else { return }
      standDrag?.fx = fx
      standDrag?.fy = fy
      standDrag?.dirty = true
    case .up:
      guard standDrag != nil else { return }
      standDrag?.fx = fx
      standDrag?.fy = fy
      standDrag?.dirty = true
      _ = try? applyStand()
      standDrag = nil
      standPeekLeft = StandPad.peek
    case .cancel:
      guard standDrag != nil else { return }
      standDrag = nil
    }
    revision += 1
  }

  /// VoiceOver's step: along the line (dx, right) or up and back (dy, up), metres.
  public func standStep(dx: Double, dy: Double) throws {
    guard canAim else { return }
    let p = standPoint
    try replan("setStance", #"{"x":\#(p.x + dx),"y":\#(p.y + dy)}"#)
    standPeekLeft = StandPad.peek
    revision += 1
  }

  /// Sends STAND's latest place, at most once a frame.
  func applyStand() throws -> Bool {
    guard let d = standDrag, d.dirty else { return false }
    standDrag?.dirty = false
    guard canAim else { return false }
    let g = d.span.ground(fx: d.fx, fy: d.fy)
    try replan("setStance", #"{"x":\#(g.x),"y":\#(g.y)}"#)
    return true
  }
}

struct StandDrag {
  let span: StandPad.Span
  var fx, fy: Double
  var dirty: Bool
}

extension PitchSession {
  func endStand() {
    standDrag = nil
    standPeekLeft = 0
  }
}
