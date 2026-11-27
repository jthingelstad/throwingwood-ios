import CoreGraphics
import Foundation

/// The aim circle's ring as it is drawn on the screen (PitchRenderer: the ground
/// circle of the marker's radius, cast through the camera). A press on or near it is
/// always the aim: a tap puts the circle there and a drag moves it, never the throw
/// (the owner, 2026-11-27, from an iPad: "On iPad I'm trying to move the drill target
/// and when I tap it is activating the throw instead. I can't find a tap target to move
/// the drill location."). The meter's own knob and the clock's ring still win
/// (`MeterLayout.first`); the throw zone and the clock's outer reach give way to it
/// (`MeterLayout.start`). docs/RENDER.md "The meter".
public struct TargetRing: Equatable, Sendable {
  /// pt round the drawn ring that a press still counts as on it.
  public static let margin: CGFloat = 10
  /// The touch target is never less than this across, however small the ring is drawn:
  /// a press within half of it of the ring's centre is on it.
  public static let least: CGFloat = 44

  /// The ring's centre on the screen, and its outline (the drawn ellipse, in order).
  public let center: CGPoint
  public let outline: [CGPoint]

  public init(center: CGPoint, outline: [CGPoint]) {
    self.center = center
    self.outline = outline
  }

  /// The outline's bounding box.
  public var bounds: CGRect {
    guard let first = outline.first else { return CGRect(origin: center, size: .zero) }
    return outline.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
  }

  /// Is the press on the ring: inside its drawn shape, within `margin` of its line, or
  /// within half of `least` of its centre?
  public func contains(_ p: CGPoint) -> Bool {
    if hypot(p.x - center.x, p.y - center.y) <= Self.least / 2 { return true }
    guard outline.count >= 3 else { return false }
    var inside = false
    var j = outline.count - 1
    for i in outline.indices {
      let a = outline[i], b = outline[j]
      if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
      j = i
    }
    if inside { return true }
    j = outline.count - 1
    for i in outline.indices {
      if Self.distance(p, outline[j], outline[i]) <= Self.margin { return true }
      j = i
    }
    return false
  }

  static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = dx * dx + dy * dy
    let t = len > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len)) : 0
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
  }
}

extension PitchSession {
  /// The aim circle's ring on a screen of `size`, as PitchRenderer draws it; nil where
  /// none is drawn.
  public func targetRing(in size: CGSize) -> TargetRing? {
    guard let m = scene.marker, m.shown != false, let r = m.r, r > 0 else { return nil }
    let projection = scene.projection(size, camera)
    guard let c = projection.project(m.point) else { return nil }
    let n = 48
    let outline = (0..<n).compactMap { i -> CGPoint? in
      let a = Double(i) / Double(n) * 2 * .pi
      return projection.project(V3(m.x + r * cos(a), m.y + r * sin(a), 0))
    }
    guard outline.count >= 3 else { return nil }
    return TargetRing(center: c, outline: outline)
  }
}
