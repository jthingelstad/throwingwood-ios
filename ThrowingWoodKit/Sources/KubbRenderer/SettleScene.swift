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

  /// Where the ground point (x, y) is drawn on a screen of `size` (review tools).
  public func groundPoint(x: Double, y: Double, in size: CGSize) -> CGPoint? {
    scene.projection(size, camera).project(V3(x, y, 0))
  }

  func settleScene() throws {
    guard let n = need, n.kind != "throw" else { return }
    scene.arc = nil
    scene.marker = nil
    scene.thrower = nil
    scene.advantageY = nil
    scene.kidY = nil
    scene.focusX = nil
    scene.stillLowest = nil
    scene.stillPad = nil
    scene.stillFloor = stillFloor
    guard n.kind == "raise" || n.kind == "punish", let id = n.kubb else { return }
    scene.items = (n.others ?? []).map { $0.pose.piece(id: $0.id) }
    if let king = n.king { scene.items.append(king.piece(id: "king", king: true)) }
    if let p = n.pose, n.kind == "raise" {
      let a = p.angle ?? 0
      var normal = V3(-sin(a), cos(a), 0)
      if normal.y > 0.05 || (abs(normal.y) <= 0.05 && normal.x * p.x > 0) { normal = -normal }
      let spot = V3(p.x, p.y, 0)
      camera = .looking(
        from: spot + normal * 1.15 + V3(0, 0, 1.05), at: spot + normal * 0.12, focal: 520)
      scene.stillZoom = 1.8
      // on a phone on its side: the lowest of the kubb, its footprints and its
      // numbers stays above the bar (WideLayout.stillLift), with the press's
      // margin round the kubb below it, which also covers a number's circle
      scene.stillLowest = RaiseTouch.lowest(n, camera: camera)
      scene.stillPad = Double(max(RaiseTouch.margin, RaiseTouch.numberR))
      // the kubb: tipped part way up while it is dragged (RaiseTouch), else lying
      let lying = p.piece(id: id)
      scene.items.append(
        raiseDragging.map { RaiseTouch.tilt(n, lying: lying, i: $0.i, t: $0.t) } ?? lying)
      let lit = raiseLit
      scene.footprints = n.ends?.enumerated().map { i, e in
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
      placement = try read("checkPunish", #"{"x":\#(c.x),"y":\#(c.y)}"#)
      scene.items.append(MatchNeed.Pose(x: c.x, y: c.y, angle: 0, standing: true).piece(id: id))
      scene.footprints = [GroundMark(x: c.x, y: c.y, allowed: placement?.ok == true, chosen: true)]
    }
  }
}
