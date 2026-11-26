import CoreGraphics
import simd

extension GroundMark {
  init(x: Double, y: Double, angle: Double? = nil, allowed: Bool = true, chosen: Bool = false) {
    self.init(
      x: x, y: y, r: nil, angle: angle, chosen: chosen, allowed: allowed, shown: true, facing: nil)
  }
}

extension Camera {
  fileprivate static func looking(from eye: V3, at target: V3, focal: Double) -> Camera {
    let forward = normalize(target - eye)
    let right = normalize(cross(forward, V3(0, 0, 1)))
    let up = cross(right, forward)
    return Camera(
      px: eye.x, py: eye.y, pz: eye.z, fx: forward.x, fy: forward.y, fz: forward.z,
      rx: right.x, ry: right.y, rz: right.z, ux: up.x, uy: up.y, uz: up.z,
      f: focal, cx: 200, cy: 120)
  }
}

/// The raise scene's camera (the web's scenes.js tune): across the kubb's length from its
/// near side, looking down at it. Twice as far back as it first stood (the owner,
/// 2026-11-22: "When raising kubbs the camera view is too close. We need to see about
/// twice as much to know how to raise them."): the same angle down and the same lens, so
/// twice the ground shows each way round the kubb (its neighbours, the lines near it,
/// often the king) and the kubb is drawn half as big; its touch target stays at least
/// 44 pt across (RaiseTouch.margin round it). The web's numbers: 2.3 m back (1.15
/// before), 2.1 m up (1.05), the look point 0.24 m toward the camera (0.12), f 520.
enum RaiseCamera {
  static let back = 2.3, up = 2.1, lead = 0.24, focal = 520.0
  /// Upright, the frame drawn this much larger than the width fit (the web's 1.8).
  static let zoom = 1.8

  /// For a kubb lying at (x, y) along `axis` (either way), in the defender's frame: the
  /// camera stands on the side of it toward the defender's baseline (y down), or, side on,
  /// toward the middle of the pitch.
  static func camera(x: Double, y: Double, axis: V2) -> Camera {
    var normal = V3(-axis.y, axis.x, 0)
    if normal.y > 0.05 || (abs(normal.y) <= 0.05 && normal.x * x > 0) { normal = -normal }
    let spot = V3(x, y, 0)
    return .looking(from: spot + normal * back + V3(0, 0, up), at: spot + normal * lead, focal: focal)
  }
}

extension MatchNeed.Pose {
  func piece(id: String, king: Bool = false) -> Piece {
    let down = standing == false
    var rotation = simd_quatd(angle: (angle ?? 0) - (down ? .pi / 2 : 0), axis: V3(0, 0, 1))
    if down { rotation *= simd_quatd(angle: -.pi / 2, axis: V3(1, 0, 0)) }
    let team = id.first == "a" ? "A" : id.first == "b" ? "B" : nil
    return Piece(
      id: id, kind: king ? "king" : "kubb", team: team, x: x, y: y,
      z: down ? 0.035 : (king ? 0.15 : 0.075), qw: rotation.real,
      qx: rotation.imag.x, qy: rotation.imag.y, qz: rotation.imag.z)
  }
}

extension PitchSession {
  /// The punishment scene's near baseline, a frame y (the web's punishNearY).
  static func punishNearY(_ camera: Camera) -> Double {
    Double(PitchProjection(size: CGSize(width: 400, height: 240), camera: camera).project(V3(0, 0, 0))?.y ?? 240)
  }

  /// The raise or punishment scene's lowest working point on a wide screen of
  /// `size`, in pt from the top: the near baseline (punishment), or the lying kubb's lowest
  /// corner, footprint or number's centre (raise). nil on other screens.
  public func stillLowestY(in size: CGSize) -> Double? {
    guard let low = scene.stillLowest, WideLayout.isWide(size) else { return nil }
    let shown = scene.projection(size, camera)
    return shown.origin.y + shown.k * low
  }

  /// The top, on a screen of `size`, of what the next throw is aimed at: the target ring,
  /// a kubb standing in it (0.3 m: the king's height) and the arc's last 1.5 m. nil
  /// while no aim is shown (WideLayout.verdictClear keeps the verdict above it).
  public func aimTop(in size: CGSize) -> CGFloat? {
    guard need == nil || need?.aims == true, let m = scene.marker, m.shown != false else { return nil }
    let pr = scene.projection(size, shownCamera)
    let r = m.r ?? 0.3
    var points: [CGPoint] = (0..<16).compactMap { k in
      let a = Double(k) / 16 * 2 * .pi
      return pr.project(V3(m.x + r * cos(a), m.y + r * sin(a), 0))
    }
    if let top = pr.project(V3(m.x, m.y, 0.3)) { points.append(top) }
    for p in scene.arc ?? [] where hypot(p.x - m.x, p.y - m.y) < 1.5 {
      if let q = pr.project(p) { points.append(q) }
    }
    return points.map(\.y).min()
  }

  /// Where the ground point (x, y) is drawn on a screen of `size` (review tools).
  public func groundPoint(x: Double, y: Double, in size: CGSize) -> CGPoint? {
    scene.projection(size, camera).project(V3(x, y, 0))
  }

  func settleScene() throws {
    guard let n = need, !n.aims else { return }
    scene.arc = nil
    scene.marker = nil
    scene.thrower = nil
    scene.advantageY = nil
    scene.kidY = nil
    scene.focusX = nil
    scene.stillLowest = nil
    scene.stillPoints = nil
    scene.stillPad = nil
    scene.stillFloor = stillFloor
    guard n.kind == "raise" || n.kind == "punish", let first = n.kubb else { return }
    // a raise in any order (engine 1.4.0): drawn for the kubb picked, the rest lying round it
    let r = n.kind == "raise" ? (raiseNeed ?? n) : n
    let id = r.kubb ?? first
    scene.items = (r.others ?? []).map { $0.pose.piece(id: $0.id) }
    if let king = n.king { scene.items.append(king.piece(id: "king", king: true)) }
    if let p = r.pose, n.kind == "raise" {
      // a watched raise (AUTO, AUTO ALL, a team-mate's: `raiseShow`) keeps the per-kubb
      // camera, close enough to see each tip up; the held camera is for raising by hand
      if let held = n.camera, raiseShow == nil {
        // engine 1.4.0: one camera for the whole raise, the whole group in it, never
        // moving from kubb to kubb (fitted to the screen as the engine's box says)
        camera = held
        scene.stillZoom = nil
        scene.heldRaise = true
      } else {
        scene.heldRaise = nil
        let a = p.angle ?? 0
        camera = RaiseCamera.camera(x: p.x, y: p.y, axis: V2(cos(a), sin(a)))
        scene.stillZoom = RaiseCamera.zoom
      }
      // on a phone on its side: the lowest of the kubb, its footprints and its
      // numbers stays above the bar (WideLayout.stillLift), with the press's
      // margin round the kubb below it, which also covers a number's circle; under the
      // held camera the whole lying group, so a tall bar never covers one
      scene.stillLowest = scene.heldRaise == true ? nil : RaiseTouch.lowest(r, camera: camera)
      scene.stillPoints = scene.heldRaise == true ? RaiseTouch.groupPoints(r) : nil
      scene.stillPad = Double(max(RaiseTouch.margin, RaiseTouch.numberR))
      // the kubb: tipped part way up while it is dragged (RaiseTouch), else lying
      let lying = p.piece(id: id)
      scene.items.append(
        raiseDragging.map { RaiseTouch.tilt(r, lying: lying, i: $0.i, t: $0.t) } ?? lying)
      let lit = raiseLit
      scene.footprints = r.ends?.enumerated().map { i, e in
        GroundMark(
          x: e.pose.x, y: e.pose.y, angle: e.pose.angle, allowed: e.ok != false, chosen: i == lit)
      }
    } else if let c = cursor {
      camera = .looking(from: V3(0, -2.6, 5.4), at: V3(0, 1.05, 0), focal: 300)
      scene.stillZoom = 1
      // the lowest ground a punishment kubb may go on: the near baseline, level
      // across the screen (the camera looks straight down the pitch)
      scene.stillLowest = Self.punishNearY(camera)
      scene.keepOut = n.keepOut
      if let k = n.keepOut?.first(where: { $0.kind == "king" }) {
        scene.items.append(
          MatchNeed.Pose(x: k.x, y: k.y, angle: 0, standing: true).piece(id: "king", king: true))
      }
      // engine 1.4.0 names the frame the spot is in (the viewer's with `setView`)
      let frame = n.frame.map { #","frame":"\#($0)""# } ?? ""
      placement = try read("checkPunish", #"{"x":\#(c.x),"y":\#(c.y)\#(frame)}"#)
      scene.items.append(MatchNeed.Pose(x: c.x, y: c.y, angle: 0, standing: true).piece(id: id))
      scene.footprints = [GroundMark(x: c.x, y: c.y, allowed: placement?.ok == true, chosen: true)]
    }
  }
}
