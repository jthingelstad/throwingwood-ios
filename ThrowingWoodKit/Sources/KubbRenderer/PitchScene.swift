import CoreGraphics
import Foundation
import simd

typealias V3 = SIMD3<Double>
typealias V2 = SIMD2<Double>

/// The ground a pitch is played on (core/world): grass, sand and snow outdoors, and
/// since engine 0.14 `grid`, the Techno scene's flat electronic floor.
public enum Surface: String, Codable, CaseIterable, Sendable {
  case grass, sand, snow, grid
  /// The words for it (core/scenes' surfaceName).
  public var name: String { rawValue.capitalized }
}

public struct Camera: Decodable, Sendable {
  let px, py, pz, fx, fy, fz, rx, ry, rz, ux, uy, uz, f, cx, cy: Double
  /// The point looked at (core/camera's lookAt keeps it; the free camera turns about it).
  var lx, ly, lz: Double?
  /// The engine's camera kind (engine 1.4.0): "end" at the viewer's end for the other
  /// side's throw, "raise" for a raise's one camera. Both are fitted to the `setView` box
  /// and drawn in the letterbox fit (`fitted`).
  var kind: String? = nil
  var fitted: Bool { kind == "end" || kind == "raise" }
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
  var kind: String? = nil
  let facing: Int?
  var point: V3 { V3(x, y, 0) }
}

public struct PitchScene: Decodable, Sendable {
  public internal(set) var surface: Surface
  var set: String
  var items: [Piece]
  var advantageY: Double?
  /// The Kid line (a Kid match, engine 0.15's `aim.kidY`): every kubb and every baton at a
  /// kubb is thrown from it. Drawn as short dots with a cone at each end.
  var kidY: Double?
  var marker, thrower: GroundMark?
  var arc: [V3]?
  // Release preserves the aim's projected x even as the camera starts tracking the throw.
  var focusX: Double? = nil
  /// The far baseline's frame y in the aim camera (`PitchProjection.farFrame`), taken at
  /// each throw's adopt: a tall screen places it at `PitchProjection.anchorAt` whoever
  /// throws from where (the web's Game.farFrameY).
  var farFrameY: Double? = nil
  var stillZoom: Double? = nil
  /// A raise on the engine's held camera (engine 1.4.0, `need.camera`): a still scene in
  /// the raiser's frame though it has no close zoom of its own.
  var heldRaise: Bool? = nil
  /// A raise or punishment scene's lowest point the player works on: a frame y
  /// and the screen points below it (WideLayout.stillLift).
  var stillLowest: Double? = nil, stillPad: Double? = nil
  /// On a phone on its side, the top of the raise and punishment bar, in pt
  /// above the screen's foot (set by the app once it has measured the bar).
  var stillFloor: Double? = nil
  /// The match's scene (the engine view's `scene`, since 0.9), carried as given:
  /// nil or an id this build does not draw is the day (SceneID.shown).
  public internal(set) var look: String? = nil
  /// The watcher's wide view (WatchView): the 400 x 240 frame fitted whole, upright too.
  /// Not for a raise or punishment scene, which keeps its own close look. Never in the
  /// engine's view (optional, so a decoded scene leaves it off).
  var wideView: Bool? = nil
  /// The side whose view frame the pieces are in, from `PitchSession.viewFrame(of:)` at
  /// every adopt (never in the engine's view). The live neighbours turn with the field
  /// while it is Team B's (Neighbours.swift).
  var frameSide: String? = nil
  /// The neighbours are drawn turned half round: the board draws in Team B's frame. The
  /// watcher's wide view is the world frame (Team A's), except a raise or punishment
  /// scene (`stillZoom`, or the engine's held raise camera), which keeps its own camera on
  /// the need's poses, in the defender's frame, for a watcher too.
  public var neighboursTurned: Bool { (!wide || stillZoom != nil || heldRaise == true) && frameSide == "B" }
  var wide: Bool {
    get { wideView == true }
    set { wideView = newValue ? true : nil }
  }
  func projection(_ size: CGSize, _ camera: Camera) -> PitchProjection {
    if wide && stillZoom == nil && !camera.fitted { return PitchProjection(size: size, camera: camera, letterbox: true) }
    var lift = 0.0
    if let low = stillLowest, let floor = stillFloor {
      lift = WideLayout.stillLift(size: size, lowest: low, pad: stillPad ?? 0, floor: floor)
    }
    // the engine's end and raise cameras are fitted to the box it was given, in the
    // letterbox frame (engine 1.4.0, `setView`)
    if camera.fitted { return PitchProjection(size: size, camera: camera, lift: lift, letterbox: true) }
    return PitchProjection(
      size: size, camera: camera, focusX: focusX ?? 200, stillZoom: stillZoom, lift: lift, anchorY: farFrameY)
  }
  var footprints, keepOut: [GroundMark]?
  /// The pieces turning faster than the frames can show, by id (Spin.swift): set by the
  /// playback each shown frame, never by the engine.
  var spins: [String: Spin]? = nil
}

/// One map for painting and hit testing. Screen coordinates are points, y down.
public struct PitchProjection {
  let c: Camera
  let size: CGSize
  let k: Double
  let origin: V2
  let principal: V2
  static let near = 0.05
  /// A tall screen places the far baseline (frame y `anchorY`, the aim camera's own) this
  /// far down: 0.41 (the web's layout.js anchorAt; the owner, 2026-11-22: "I wonder if our
  /// camera view should be a touch lower so the kubbs we are aiming at are a little lower
  /// on the screen"). Before, frame y 112 stood at 0.33, which put the far baseline at 31%
  /// of the height from the baseline. The band under the header holds the minimap and
  /// the verdict.
  public static let anchorAt = 0.41
  /// The far baseline's frame y when no aim camera gave one (a throw from the baseline's).
  public static let anchorY = 96.0

  /// The far baseline's frame y in `camera` (the 400 x 240 frame), held to 40...180.
  static func farFrame(_ camera: Camera) -> Double? {
    guard let p = PitchProjection(size: CGSize(width: 400, height: 240), camera: camera).project(V3(0, 8, 0)),
      p.y.isFinite
    else { return nil }
    return max(40, min(180, Double(p.y)))
  }

  /// `lift`: pt a wide screen's frame moves up, the same scale (WideLayout.stillLift).
  /// `anchorY`: the far baseline's frame y in the aim camera (`farFrame`).
  public init(
    size: CGSize, camera: Camera, focusX: Double = 200, stillZoom: Double? = nil, lift: Double = 0,
    letterbox: Bool = false, anchorY: Double? = nil
  ) {
    c = camera
    self.size = size
    if !letterbox, size.height > size.width * 1.05, size.width > 0 {
      k = size.width / 400 * (stillZoom ?? 1.3)
      if stillZoom != nil {
        origin = V2(size.width / 2 - 200 * k, size.height * 0.42 - 120 * k)
      } else {
        let half = size.width / (2 * k)
        let room = half - 40
        let pan = max(focusX - room, min(focusX + room, 200))
        let center = max(half, min(400 - half, pan))
        origin = V2(size.width / 2 - center * k, size.height * Self.anchorAt - (anchorY ?? Self.anchorY) * k)
      }
    } else {
      k = min(size.width / 400, size.height / 240)
      origin = V2(size.width - 400 * k, size.height - 240 * k) * 0.5 - V2(0, lift)
    }
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
