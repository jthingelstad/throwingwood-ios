import CoreGraphics
import Foundation
import simd

typealias V3 = SIMD3<Double>
typealias V2 = SIMD2<Double>

public enum Surface: String, Codable, CaseIterable, Sendable {
  case grass, sand, snow
}

public struct Camera: Decodable, Sendable {
  let px, py, pz, fx, fy, fz, rx, ry, rz, ux, uy, uz, f, cx, cy: Double
  var eye: V3 { V3(px, py, pz) }
  var forward: V3 { V3(fx, fy, fz) }
  var right: V3 { V3(rx, ry, rz) }
  var up: V3 { V3(ux, uy, uz) }
}

public struct Piece: Decodable, Sendable {
  let id, kind: String
  let team: String?
  var x, y, z, qw, qx, qy, qz: Double
  var center: V3 { V3(x, y, z) }
  var rotation: simd_quatd { simd_quatd(ix: qx, iy: qy, iz: qz, r: qw) }
}

public struct GroundMark: Decodable, Sendable {
  let x, y: Double
  let r, angle: Double?
  let chosen, allowed, shown: Bool?
  let facing: Int?
  var point: V3 { V3(x, y, 0) }
}

public struct PitchScene: Decodable, Sendable {
  public internal(set) var surface: Surface
  var set: String
  var items: [Piece]
  var advantageY: Double?
  var marker, thrower: GroundMark?
  var arc: [V3]?
  var footprints, keepOut: [GroundMark]?
}

/// One map for painting and hit testing. Screen coordinates are points, y down.
public struct PitchProjection {
  let c: Camera
  let size: CGSize
  let k: Double
  let origin: V2
  let principal: V2
  static let near = 0.05

  public init(size: CGSize, camera: Camera) {
    c = camera
    self.size = size
    k = min(size.width / 400, size.height / 240)
    origin = V2(size.width - 400 * k, size.height - 240 * k) * 0.5
    principal = origin + k * V2(c.cx, c.cy)
  }

  func view(_ p: V3) -> V3 {
    let d = p - c.eye
    return V3(dot(d, c.right), dot(d, c.up), dot(d, c.forward))
  }

  func screen(_ v: V3) -> CGPoint {
    let p = principal + (k * c.f / v.z) * V2(v.x, -v.y)
    return CGPoint(x: p.x, y: p.y)
  }

  func project(_ p: V3) -> CGPoint? {
    let v = view(p)
    return v.z >= Self.near ? screen(v) : nil
  }

  func ground(_ point: CGPoint) -> V3? {
    let uv = (V2(point.x, point.y) - principal) / (k * c.f)
    let ray = c.forward + c.right * uv.x - c.up * uv.y
    guard ray.z < -1e-9 else { return nil }
    let t = -c.pz / ray.z
    return t >= Self.near ? c.eye + t * ray : nil
  }

  /// Clip in eye space before dividing by depth, including polygons crossing the baseline.
  func polygon(_ world: [V3]) -> [CGPoint] {
    let corners = world.map(view)
    guard var a = corners.last else { return [] }
    var result: [CGPoint] = []
    for b in corners {
      if (a.z >= Self.near) != (b.z >= Self.near) {
        result.append(screen(a + (b - a) * ((Self.near - a.z) / (b.z - a.z))))
      }
      if b.z >= Self.near { result.append(screen(b)) }
      a = b
    }
    return result
  }
}

extension CGPoint {
  static func between(_ a: Self, _ b: Self, _ t: Double) -> Self {
    Self(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
  }
  func distance(to p: Self) -> Double { hypot(x - p.x, y - p.y) }
}
