import CoreGraphics
import Foundation

/// The feedback card's picture of the pitch from above (the web's src/net/paint.js and
/// src/ui/paint.js; the owner, 2026-11-26: "show an image of the pitch and allow the user
/// to paint over the area where the issue occurred instead of selecting individual
/// pieces"): which box of the pitch it shows, each piece's footprint, and the mapping
/// between the picture's points and the pieces' metres (x across, y along, the thrower's
/// view frame). Pure, so the app's view and the tests share it.
public enum ReportPicture {
  /// Half extents along a piece's local x, y, z (the web's PIECE_SIZES).
  public static let sizes: [String: (Double, Double, Double)] = [
    "kubb": (0.035, 0.035, 0.075),
    "king": (0.045, 0.045, 0.15),
    "baton": (0.022, 0.022, 0.15),
    "stake": (0.0095, 0.0095, 0.075),
  ]

  /// The web's paintTune.
  public static let brushPoints: CGFloat = 13
  public static let maxHeightShare: CGFloat = 0.55
  public static let minHeight: CGFloat = 190
  public static let step = 0.35
  public static let minPiecePoints: CGFloat = 7
  public static let grow: CGFloat = 1.6

  /// The box the picture shows: the pitch (5 by 8) and every piece, with a margin, in the
  /// paint's limits.
  public struct Bounds: Equatable, Sendable {
    public var x0, x1, y0, y1: Double
  }

  public static func bounds(_ pieces: [ReportPiece]) -> Bounds {
    let xs = pieces.map(\.x).filter(\.isFinite), ys = pieces.map(\.y).filter(\.isFinite)
    return Bounds(
      x0: max(ReportPaint.xRange.lowerBound, min(-2.5, xs.min() ?? 0) - 0.5),
      x1: min(ReportPaint.xRange.upperBound, max(2.5, xs.max() ?? 0) + 0.5),
      y0: max(ReportPaint.yRange.lowerBound, min(0, ys.min() ?? 0) - 0.6),
      y1: min(ReportPaint.yRange.upperBound, max(8, ys.max() ?? 0) + 0.6))
  }

  /// A piece seen from above: the hull of its box's corners, and whether it lies (its
  /// long axis more along the ground than up, or toppled).
  public static func footprint(_ p: ReportPiece) -> (poly: [CGPoint], lying: Bool) {
    let (hx, hy, hz) = sizes[p.kind] ?? sizes["kubb"]!
    let (qw, qx, qy, qz) = (p.qw, p.qx, p.qy, p.qz)
    // core/quat.toMatrix: the columns are the local axes in the world
    let m = [
      1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy),
      2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx),
    ]
    var pts: [CGPoint] = []
    for sx in [-1.0, 1] {
      for sy in [-1.0, 1] {
        for sz in [-1.0, 1] {
          let (lx, ly, lz) = (sx * hx, sy * hy, sz * hz)
          pts.append(
            CGPoint(x: p.x + m[0] * lx + m[1] * ly + m[2] * lz, y: p.y + m[3] * lx + m[4] * ly + m[5] * lz))
        }
      }
    }
    let up = abs(1 - 2 * (qx * qx + qy * qy))
    return (hull(pts), p.toppled || up < 0.7)
  }

  static func hull(_ pts: [CGPoint]) -> [CGPoint] {
    let s = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
      Double((a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x))
    }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for p in s {
      while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 1e-12 { lower.removeLast() }
      lower.append(p)
    }
    for p in s.reversed() {
      while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 1e-12 { upper.removeLast() }
      upper.append(p)
    }
    lower.removeLast()
    upper.removeLast()
    return lower + upper
  }

  /// The picture's mapping for a box `width` wide with at most `maxHeight`: upright (the
  /// far baseline at the top) or on its side (the far baseline at the right), whichever
  /// shows the pitch bigger.
  public struct Fit: Equatable, Sendable {
    public let bounds: Bounds
    public let upright: Bool
    /// Points a metre.
    public let scale: CGFloat
    public let size: CGSize

    public init(bounds: Bounds, width: CGFloat, maxHeight: CGFloat) {
      let across = CGFloat(bounds.x1 - bounds.x0), along = CGFloat(bounds.y1 - bounds.y0)
      let up = min(width / across, maxHeight / along)
      let side = min(width / along, maxHeight / across)
      self.bounds = bounds
      upright = up >= side
      scale = upright ? up : side
      size = CGSize(
        width: ((upright ? across : along) * scale).rounded(.down),
        height: ((upright ? along : across) * scale).rounded(.down))
    }

    /// A point in metres to the picture's points.
    public func point(_ m: CGPoint) -> CGPoint {
      let b = bounds
      return upright
        ? CGPoint(x: (Double(m.x) - b.x0) * scale, y: (b.y1 - Double(m.y)) * scale)
        : CGPoint(x: (Double(m.y) - b.y0) * scale, y: (Double(m.x) - b.x0) * scale)
    }

    /// A point in the picture to metres.
    public func metres(_ p: CGPoint) -> CGPoint {
      let b = bounds
      return upright
        ? CGPoint(x: b.x0 + Double(p.x / scale), y: b.y1 - Double(p.y / scale))
        : CGPoint(x: b.x0 + Double(p.y / scale), y: b.y0 + Double(p.x / scale))
    }

    /// The brush's radius in metres from its first fit (kept through a resize).
    public var brush: Double {
      (min(ReportPaint.brushRange.upperBound, max(0.1, Double(ReportPicture.brushPoints / scale))) * 100)
        .rounded() / 100
    }
  }

  /// How much a kubb or the king is drawn larger round its real place so its colour and
  /// shape show (a baton never).
  public static func grow(_ p: ReportPiece, scale: CGFloat) -> CGFloat {
    if p.kind == "baton" { return 1 }
    let across = 2 * CGFloat((sizes[p.kind] ?? sizes["kubb"]!).0) * scale
    return min(grow, max(1, minPiecePoints / across))
  }
}
