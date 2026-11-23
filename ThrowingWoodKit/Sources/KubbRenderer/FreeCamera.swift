import CoreGraphics
import Foundation

// The watcher's free camera (the web's docs/OBSERVER.md, src/render/freecam.js and
// src/game/free-camera.js, their numbers): someone with no side in the match flies
// round the pitch in the wide view.
//
// The renderer draws through any core camera: a pinhole with a position, a level
// right vector and a lens. The wide view's camera (the engine's session/wide.lua) is
// one, made with core/camera's lookAt, so the free camera is the same kind, made here
// from an orbit round a point on the pitch with the same lookAt arithmetic:
//
//   tx, ty, tz  the point it turns about and looks at (m, the world frame)
//   yaw         where the eye stands round it, radians from +x
//   pitch       how high it looks down, radians above the ground (never straight down)
//   dist        m from the point to the eye
//
// The lens (f, cx, cy) stays the wide camera's: closer is the eye moving, not a longer
// lens. Until the first move the engine's wide camera is drawn untouched.

/// An orbit round a point on the pitch.
public struct Orbit: Equatable, Sendable {
  public var yaw, pitch, dist, tx, ty, tz: Double
  public init(yaw: Double, pitch: Double, dist: Double, tx: Double, ty: Double, tz: Double) {
    self.yaw = yaw
    self.pitch = pitch
    self.dist = dist
    self.tx = tx
    self.ty = ty
    self.tz = tz
  }
}

/// The free camera's pure arithmetic (the web's freecam.js).
public enum FreeCam {
  private static let d = Double.pi / 180
  /// The web's `freeTune`.
  public static let minDist = 2.5, maxDist = 24.0
  public static let minPitch = 4 * d, maxPitch = 86 * d
  public static let minEyeZ = 0.35
  public static let boxX = -4.0...4.0, boxY = -2.5...10.5
  public static let turnPerPx = 0.006, tiltPerPx = 0.004
  public static let resetTime = 0.45
  public static let pitchMinSin = 0.3
  /// s the hint shows when nothing has moved the view (the web's watch-view.js).
  public static let hintTime = 8.0

  static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }

  /// The orbit a core camera stands on: its eye and the point it looks at (`lx`, `ly`,
  /// `lz`, which lookAt keeps), so camera(orbit(c), lens: c) is c again.
  public static func orbit(of c: Camera) -> Orbit {
    let tx = c.lx ?? c.px + c.fx, ty = c.ly ?? c.py + c.fy, tz = c.lz ?? c.pz + c.fz
    let dx = c.px - tx, dy = c.py - ty, dz = c.pz - tz
    let flat = hypot(dx, dy)
    return Orbit(
      yaw: atan2(dy, dx), pitch: atan2(dz, flat), dist: hypot(flat, dz), tx: tx, ty: ty, tz: tz)
  }

  /// The same orbit held inside the limits.
  public static func clamped(_ o: Orbit) -> Orbit {
    let tx = clamp(o.tx, boxX), ty = clamp(o.ty, boxY)
    var pitch = clamp(o.pitch, minPitch...maxPitch)
    let dist = clamp(o.dist, minDist...maxDist)
    // the eye stays over the grass: a low pitch close in is lifted
    if o.tz + dist * sin(pitch) < minEyeZ {
      pitch = min(maxPitch, asin(clamp((minEyeZ - o.tz) / dist, -1...1)))
    }
    return Orbit(yaw: wrap(o.yaw), pitch: pitch, dist: dist, tx: tx, ty: ty, tz: o.tz)
  }

  /// An angle in (-pi, pi].
  public static func wrap(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r <= -.pi { r += 2 * .pi }
    if r > .pi { r -= 2 * .pi }
    return r
  }

  /// The eye of an orbit.
  public static func eye(of o: Orbit) -> (x: Double, y: Double, z: Double) {
    let c = cos(o.pitch)
    return (o.tx + o.dist * c * cos(o.yaw), o.ty + o.dist * c * sin(o.yaw), o.tz + o.dist * sin(o.pitch))
  }

  /// core/camera's lookAt, the same arithmetic: the right vector level, up = right x
  /// forward, with the lens `f`, `cx`, `cy`.
  public static func lookAt(
    px: Double, py: Double, pz: Double, tx: Double, ty: Double, tz: Double,
    f: Double, cx: Double, cy: Double
  ) -> Camera {
    var fx = tx - px, fy = ty - py, fz = tz - pz
    let n = (fx * fx + fy * fy + fz * fz).squareRoot()
    fx /= n
    fy /= n
    fz /= n
    var rx = fy, ry = -fx
    let rn = (rx * rx + ry * ry).squareRoot()
    rx /= rn
    ry /= rn
    return Camera(
      px: px, py: py, pz: pz, fx: fx, fy: fy, fz: fz, rx: rx, ry: ry, rz: 0,
      ux: ry * fz, uy: -rx * fz, uz: rx * fy - ry * fx, f: f, cx: cx, cy: cy,
      lx: tx, ly: ty, lz: tz)
  }

  /// The camera an orbit gives, with `lens`'s f, cx and cy (the wide camera's).
  public static func camera(_ o: Orbit, lens: Camera) -> Camera {
    let e = eye(of: o)
    return lookAt(px: e.x, py: e.y, pz: e.z, tx: o.tx, ty: o.ty, tz: o.tz, f: lens.f, cx: lens.cx, cy: lens.cy)
  }

  /// Turn round the point (yaw) and raise or lower the eye over it (pitch).
  public static func turn(_ o: Orbit, _ dyaw: Double, _ dpitch: Double) -> Orbit {
    var n = o
    n.yaw += dyaw
    n.pitch += dpitch
    return clamped(n)
  }

  /// Closer (factor < 1) or farther (factor > 1).
  public static func zoom(_ o: Orbit, _ factor: Double) -> Orbit {
    guard factor > 0, factor.isFinite else { return o }
    var n = o
    n.dist *= factor
    return clamped(n)
  }

  /// Move the point over the ground: `right` m to the screen's right and `ahead` m
  /// away from the eye, both level.
  public static func move(_ o: Orbit, right: Double, ahead: Double) -> Orbit {
    let s = sin(o.yaw), c = cos(o.yaw)
    var n = o
    n.tx = o.tx - s * right - c * ahead
    n.ty = o.ty + c * right - s * ahead
    return clamped(n)
  }

  /// A drag of the pitch by (dx, dy) frame px with lens length f: the ground under the
  /// finger goes with it, as near as one point turned about allows.
  public static func drag(_ o: Orbit, dx: Double, dy: Double, f: Double) -> Orbit {
    let perPx = o.dist / max(1, f)
    let s = max(pitchMinSin, sin(o.pitch))
    return move(o, right: -dx * perPx, ahead: dy * perPx / s)
  }

  /// The way between two orbits at t (0...1), turning the short way round.
  public static func mix(_ a: Orbit, _ b: Orbit, _ t: Double) -> Orbit {
    func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
    return Orbit(
      yaw: wrap(a.yaw + wrap(b.yaw - a.yaw) * t), pitch: m(a.pitch, b.pitch), dist: m(a.dist, b.dist),
      tx: m(a.tx, b.tx), ty: m(a.ty, b.ty), tz: m(a.tz, b.tz))
  }

  /// Two orbits the same to within a hair (the eye within a millimetre).
  public static func same(_ a: Orbit?, _ b: Orbit?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    let ea = eye(of: a), eb = eye(of: b)
    let de = (ea.x - eb.x, ea.y - eb.y, ea.z - eb.z)
    let dt = (a.tx - b.tx, a.ty - b.ty, a.tz - b.tz)
    return (de.0 * de.0 + de.1 * de.1 + de.2 * de.2).squareRoot() < 1e-3
      && (dt.0 * dt.0 + dt.1 * dt.1 + dt.2 * dt.2).squareRoot() < 1e-3
  }

  /// Two fingers from (a0, b0) to (a1, b1), pt: how far apart they spread (scale, > 1
  /// apart), how much they turned (radians, clockwise on the screen positive) and how
  /// far their middle moved.
  public static func twoFingers(_ a0: CGPoint, _ b0: CGPoint, _ a1: CGPoint, _ b1: CGPoint)
    -> (scale: Double, angle: Double, dx: Double, dy: Double)
  {
    let d0 = hypot(b0.x - a0.x, b0.y - a0.y), d1 = hypot(b1.x - a1.x, b1.y - a1.y)
    let t0 = atan2(b0.y - a0.y, b0.x - a0.x), t1 = atan2(b1.y - a1.y, b1.x - a1.x)
    return (
      d0 > 1 && d1 > 1 ? Double(d1 / d0) : 1, wrap(Double(t1 - t0)),
      Double(a1.x + b1.x - a0.x - b0.x) / 2, Double(a1.y + b1.y - a0.y - b0.y) / 2
    )
  }
}

/// The free camera's state and controls (the web's FreeCamera): the wide camera as its
/// lens, the orbit chosen (nil: the default view, the engine's camera untouched), and
/// RESET VIEW's ease. Nothing is stored.
public final class FreeCamera {
  /// The wide camera: its lens, and the default orbit.
  public private(set) var lens: Camera?
  /// nil: the default view (the lens itself).
  public private(set) var orbit: Orbit?
  private var ease: (from: Orbit, t: Double)?
  /// pt a frame px (the wide view's fit), for drags.
  public var k = 1.0
  public var moved: Bool { orbit != nil }
  /// The view has been moved since the wide view came on: the hint has done its job.
  public private(set) var touched = false
  public var easing: Bool { ease != nil }
  public init() {}

  /// The wide camera, again on every resize: the lens follows the window, the orbit
  /// chosen stays (held inside the limits). nil lets go of it all.
  public func setLens(_ cam: Camera?) {
    lens = cam
    if cam == nil {
      orbit = nil
      ease = nil
      touched = false
    } else if let o = orbit {
      orbit = FreeCam.clamped(o)
    }
  }

  /// The camera to draw through: `base` (the engine's) in the default view.
  public func camera(_ base: Camera) -> Camera {
    guard let orbit, let lens else { return base }
    return FreeCam.camera(orbit, lens: lens)
  }

  private func begin() -> Orbit? {
    guard let lens else { return nil }
    ease = nil
    touched = true
    return orbit ?? FreeCam.clamped(FreeCam.orbit(of: lens))
  }

  public func turnBy(_ dyaw: Double, _ dpitch: Double) {
    if let o = begin() { orbit = FreeCam.turn(o, dyaw, dpitch) }
  }
  public func zoomBy(_ factor: Double) {
    if let o = begin() { orbit = FreeCam.zoom(o, factor) }
  }
  /// A drag of the ground by pt.
  public func dragBy(_ dx: Double, _ dy: Double) {
    if let o = begin(), let lens { orbit = FreeCam.drag(o, dx: dx / k, dy: dy / k, f: lens.f) }
  }

  /// One finger moved by (dx, dy) pt: turn round the pitch and raise or lower the eye.
  public func oneFinger(dx: Double, dy: Double) {
    turnBy(-dx * FreeCam.turnPerPx, dy * FreeCam.tiltPerPx)
  }

  /// One of two fingers moved from `from` to `to`, the other still at `other`: pinch
  /// closer or farther, twist to turn, slide to move.
  public func twoFingers(from: CGPoint, to: CGPoint, other: CGPoint) {
    let g = FreeCam.twoFingers(from, other, to, other)
    guard var o = begin() else { return }
    o = FreeCam.zoom(o, 1 / g.scale)
    o = FreeCam.turn(o, g.angle, 0)
    orbit = o
    dragBy(g.dx, g.dy)
  }

  /// RESET VIEW: back to the default, eased over 0.45 s unless Reduce Motion is on.
  public func reset(reduced: Bool) {
    guard let orbit else { return }
    if reduced || lens == nil {
      home()
    } else {
      ease = (orbit, 0)
    }
  }

  /// The default view at once: the engine's camera is drawn again.
  public func home() {
    ease = nil
    orbit = nil
  }

  /// One frame. True while RESET VIEW eases (the picture moves).
  @discardableResult public func tick(_ dt: Double) -> Bool {
    guard let lens, dt > 0, var e = ease else { return false }
    e.t = min(1, e.t + dt / FreeCam.resetTime)
    if e.t >= 1 {
      home()
      return true
    }
    let goal = FreeCam.clamped(FreeCam.orbit(of: lens))
    let s = e.t * e.t * (3 - 2 * e.t)
    ease = e
    orbit = FreeCam.mix(e.from, goal, s)
    return true
  }
}

/// Where the watcher's wide view frames the pitch (the web's layout.js wideBox): the
/// window as the 400 x 240 frame sees it, less the HUD's top (132 pt upright, 70 on its
/// side) and a 16 pt margin, inside the safe area. The frame is fitted whole (the plain
/// letterbox), and a watcher gets the wide view down to a smallest base kubb of 2 pt.
public enum WatchView {
  /// The smallest base kubb a watcher's wide view may draw, in pt (the web's observeMinPx).
  public static let observeMinPx = 2.0
  public static let margin: CGFloat = 16

  /// pt a frame px in the wide view (the letterbox fit).
  public static func scale(_ size: CGSize) -> Double {
    Double(min(size.width / 400, size.height / 240))
  }

  /// The box in frame px: left, top, right, bottom.
  public static func box(size: CGSize, safe: ScreenInsets) -> (left: Double, top: Double, right: Double, bottom: Double) {
    let w = size.width, h = size.height
    let k = min(w / 400, h / 240)
    let ox = (w - 400 * k) / 2, oy = (h - 240 * k) / 2
    let tall = h > w * WideLayout.tallFrom
    let top = (tall ? 132 : 70) + safe.top
    return (
      Double((safe.left + margin - ox) / k), Double((top - oy) / k),
      Double((w - safe.right - margin - ox) / k), Double((h - safe.bottom - margin - oy) / k)
    )
  }
}
