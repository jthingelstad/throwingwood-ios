import CoreGraphics
import Foundation
import simd

/// Placing the aim circle. A tap puts it where the finger lands (onto a standing
/// target drawn under or right beside the tap); a drag anywhere on the pitch moves
/// it from where it is, by the finger's travel at a fixed ground scale. The finger
/// never has to sit on the circle (Jamie, 2026-11-19, about the meters: the finger
/// must not cover the thing it controls).
///
/// The old drag put the circle under the finger. The aim camera turns to follow
/// the circle, so every move event cast the finger through a camera that had
/// already turned: on the iPhone 16e 20 pt of finger travel near the far baseline
/// moved the circle 1.9 m sideways, ten times the 0.18 m under the finger.
public enum AimDrag {
  /// Ground metres per point of finger travel, both ways. Sideways at the far
  /// baseline a point under the finger is 0.009 m (16e) and 0.008 m (Pro Max);
  /// along the pitch it is 0.031 m and 0.027 m, which is what made depth coarse.
  public static let metresPerPoint = 0.01
  /// Finger travel (pt) before a press on the pitch is a drag, not a tap.
  public static let slop = 8.0
  /// A tap within this many points of a standing target's drawn body aims at it.
  public static let snapReach = 22.0

  /// The ground move for a finger move on the screen, in the view frame. Screen
  /// right is the camera's right laid on the ground, screen up its forward.
  static func groundDelta(_ d: CGVector, camera c: Camera) -> V2 {
    func flat(_ v: V2, _ fallback: V2) -> V2 { simd_length(v) > 0.2 ? simd_normalize(v) : fallback }
    let right = flat(V2(c.rx, c.ry), V2(1, 0))
    let forward = flat(V2(c.fx, c.fy), flat(V2(c.ux, c.uy), V2(-right.y, right.x)))
    return metresPerPoint * (Double(d.dx) * right - Double(d.dy) * forward)
  }
}

extension PitchSession {
  /// Moves the circle by a finger's move (points, screen axes), from where it is.
  public func nudgeAim(by d: CGVector) throws {
    guard canAim, let m = scene.marker, d.dx != 0 || d.dy != 0 else { return }
    let g = V2(m.x, m.y) + AimDrag.groundDelta(d, camera: camera)
    try replan("setTarget", #"{"x":\#(g.x),"y":\#(g.y),"snap":false}"#)
  }

  /// The drag is let go: onto a standing target if it is that near (the engine's snap).
  public func settleAim() throws {
    guard canAim, let m = scene.marker else { return }
    try replan("setTarget", #"{"x":\#(m.x),"y":\#(m.y),"snap":true}"#)
  }

  /// A tap on the pitch: on or right beside a standing target's drawn body aims
  /// at that target, anywhere else at the ground under the tap.
  public func tapAim(at point: CGPoint, size: CGSize) throws {
    guard canAim else { return }
    if let piece = standingTarget(near: point, size: size) {
      try replan("setTarget", #"{"x":\#(piece.x),"y":\#(piece.y),"snap":true}"#)
    } else {
      try target(point, size: size, snap: true, tap: true)
    }
  }

  /// The standing kubb or king beyond the throwing line whose drawn body (ground
  /// to top) passes nearest the point, within `AimDrag.snapReach`.
  func standingTarget(near point: CGPoint, size: CGSize) -> Piece? {
    let p = scene.projection(size, camera)
    let tap = V2(point.x, point.y)
    var best: (Piece, Double)?
    for piece in scene.items where piece.kind == "kubb" || piece.kind == "king" {
      let axis = piece.rotation.act(V3(0, 0, 1))
      guard axis.z > 0.9, piece.y > 0.5,
        let foot = p.project(V3(piece.x, piece.y, 0)),
        let top = p.project(V3(piece.x, piece.y, piece.z * 2))
      else { continue }
      let a = V2(foot.x, foot.y), b = V2(top.x, top.y)
      let ab = b - a
      let t = simd_length_squared(ab) > 0 ? max(0, min(1, simd_dot(tap - a, ab) / simd_length_squared(ab))) : 0
      let d = simd_length(tap - (a + t * ab))
      if d <= AimDrag.snapReach, d < (best?.1 ?? .infinity) { best = (piece, d) }
    }
    return best?.0
  }
}
