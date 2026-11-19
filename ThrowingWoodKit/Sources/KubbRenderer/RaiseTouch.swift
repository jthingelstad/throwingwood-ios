import CoreGraphics
import Foundation
import simd

/// Touch the kubb to raise it (Jamie, 2026-11-19: "similar to on the Playdate where you can
/// use the crank to raise the kubbs, on touch, you should be able to just touch the kubb and
/// raise it"). A port of the web's src/game/raise-touch.js, same numbers: where the lying
/// kubb is drawn on the screen, which end a tap or a drag means, and the kubb's pose part way
/// up while it is dragged. Nothing here talks to the engine: the session sends the same
/// `raise` action with a choice as END 1 and END 2 do.
public enum RaiseTouch {
  public static let margin: CGFloat = 24  // pt round the drawn kubb a tap still takes it
  public static let labelR: CGFloat = 40  // pt round an end's number a tap takes that end
  public static let travelMin: CGFloat = 90  // pt: the shortest drag that tips it all the way
  public static let travelK: CGFloat = 1.1  // the full tip: this times the kubb's drawn length
  public static let stand = 0.5  // let go past this part of the way up and it stands
  public static let hint = 1.0  // s the allowed end is lit after a tap on a refused one
  public static let numberR: CGFloat = 17  // pt: an end's number's circle (the web's r 17)

  static let halfSide = 0.035  // a kubb: half its side and half its length
  static let halfLength = 0.075

  /// The lying kubb on the screen: its outline (the hull of its eight projected corners)
  /// and the middles of its two end faces.
  public struct Geometry: Sendable {
    public let outline: [CGPoint]
    public let caps: [CGPoint]
  }

  /// A drag on the kubb: toward end `i` (an index into the need's ends), `t` of the way up.
  public struct Drag: Equatable, Sendable {
    public let i: Int
    public let t: Double
  }

  /// The kubb's long axis, a unit vector from its middle toward end i, on the ground.
  static func axis(_ need: MatchNeed, _ i: Int) -> V2 {
    let a = need.pose?.angle ?? 0
    var u = V2(cos(a), sin(a))
    if let p = need.pose, let ends = need.ends, ends.indices.contains(i) {
      let d = V2(ends[i].pose.x - p.x, ends[i].pose.y - p.y)
      let l = simd_length(d)
      if l > 1e-6 { return d / l }
      if i == 1 { u = -u }
    }
    return u
  }

  /// Convex hull (monotone chain), anticlockwise.
  static func hull(_ points: [CGPoint]) -> [CGPoint] {
    let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    guard p.count >= 3 else { return p }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for q in p {
      while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 {
        lower.removeLast()
      }
      lower.append(q)
    }
    for q in p.reversed() {
      while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 {
        upper.removeLast()
      }
      upper.append(q)
    }
    return Array(lower.dropLast() + upper.dropLast())
  }

  /// Corner k of a kubb's box (bit 0 across x, bit 1 across y, bit 2 along its
  /// length). Typed step by step: as one sum, a CI compiler gave up on it.
  static func corner(_ k: Int, of piece: Piece, x: V3, y: V3, z: V3) -> V3 {
    let sx: Double = k & 1 == 0 ? -halfSide : halfSide
    let sy: Double = k & 2 == 0 ? -halfSide : halfSide
    let sz: Double = k & 4 == 0 ? -halfLength : halfLength
    // the same order as the sum it was: centre, then x, y, z
    let ax: V3 = piece.center + sx * x
    let ay: V3 = ax + sy * y
    return ay + sz * z
  }

  static func geometry(_ need: MatchNeed, piece: Piece, projection: PitchProjection) -> Geometry? {
    guard let pose = need.pose, need.ends?.count == 2 else { return nil }
    let r = piece.rotation
    let x = r.act(V3(1, 0, 0)), y = r.act(V3(0, 1, 0)), z = r.act(V3(0, 0, 1))
    var outline: [CGPoint] = []
    for k in 0..<8 {
      let c = corner(k, of: piece, x: x, y: y, z: z)
      guard let p = projection.project(c) else { return nil }
      outline.append(p)
    }
    var caps: [CGPoint] = []
    for i in 0..<2 {
      let u = axis(need, i)
      guard
        let p = projection.project(
          V3(pose.x + u.x * halfLength, pose.y + u.y * halfLength, halfSide))
      else { return nil }
      caps.append(p)
    }
    return Geometry(outline: hull(outline), caps: caps)
  }

  /// The lowest frame y (the 400 x 240 frame) of the raise scene's working parts: the
  /// lying kubb's corners, both footprints and both numbers' centres. Lowest on the
  /// screen; a number's circle reaches `numberR` pt below its centre.
  static func lowest(_ need: MatchNeed, camera: Camera) -> Double? {
    guard let pose = need.pose, let id = need.kubb, let ends = need.ends else { return nil }
    let frame = PitchProjection(size: CGSize(width: 400, height: 240), camera: camera)
    let piece = pose.piece(id: id)
    let r = piece.rotation
    let x = r.act(V3(1, 0, 0)), y = r.act(V3(0, 1, 0)), z = r.act(V3(0, 0, 1))
    var points: [V3] = (0..<8).map { corner($0, of: piece, x: x, y: y, z: z) }
    for e in ends {
      let d = V2(e.pose.x - pose.x, e.pose.y - pose.y)
      let l = simd_length(d) == 0 ? 1 : simd_length(d)
      points.append(V3(e.pose.x, e.pose.y, 0))
      points.append(V3(e.pose.x + d.x / l * 0.07, e.pose.y + d.y / l * 0.07, 0))
    }
    return points.compactMap { frame.project($0).map { Double($0.y) } }.max()
  }

  /// How far `p` is outside a convex polygon: 0 inside.
  static func outside(_ poly: [CGPoint], _ p: CGPoint) -> CGFloat {
    var inside = true
    var best = CGFloat.infinity
    for k in poly.indices {
      let a = poly[k], b = poly[(k + 1) % poly.count]
      let ex = b.x - a.x, ey = b.y - a.y
      if ex * (p.y - a.y) - ey * (p.x - a.x) < 0 { inside = false }
      let l2 = ex * ex + ey * ey == 0 ? 1 : ex * ex + ey * ey
      let t = max(0, min(1, ((p.x - a.x) * ex + (p.y - a.y) * ey) / l2))
      best = min(best, hypot(p.x - (a.x + t * ex), p.y - (a.y + t * ey)))
    }
    return inside ? 0 : best
  }

  /// A press on the drawn kubb, or within `margin` of it.
  public static func on(_ g: Geometry?, _ p: CGPoint, margin: CGFloat = margin) -> Bool {
    guard let g else { return false }
    return outside(g.outline, p) <= margin
  }

  static func along(_ g: Geometry, _ p: CGPoint) -> CGFloat {
    let a = g.caps[0], b = g.caps[1]
    let ex = b.x - a.x, ey = b.y - a.y
    let l2 = ex * ex + ey * ey == 0 ? 1 : ex * ex + ey * ey
    return ((p.x - a.x) * ex + (p.y - a.y) * ey) / l2
  }

  /// The end nearer a tap on the kubb: 0 or 1.
  public static func nearerEnd(_ g: Geometry, _ p: CGPoint) -> Int { along(g, p) < 0.5 ? 0 : 1 }

  /// A drag from `from` to `to`: toward which end, and how far up. The finger moves
  /// toward the end the kubb will stand on, along the kubb as it is drawn.
  public static func drag(_ g: Geometry, from: CGPoint, to: CGPoint) -> Drag {
    let a = g.caps[0], b = g.caps[1]
    let len = hypot(b.x - a.x, b.y - a.y) == 0 ? 1 : hypot(b.x - a.x, b.y - a.y)
    let d = ((to.x - from.x) * (b.x - a.x) + (to.y - from.y) * (b.y - a.y)) / len
    let travel = max(travelMin, len * travelK)
    return Drag(i: d < 0 ? 0 : 1, t: Double(min(1, abs(d) / travel)))
  }

  /// The end to stand it on, or the one the rules allow when `i` is refused (nil when
  /// neither is).
  static func allowed(_ need: MatchNeed, _ i: Int) -> (i: Int?, ok: Bool) {
    let ends = need.ends ?? []
    if ends.indices.contains(i), ends[i].ok != false { return (i, true) }
    return (ends.firstIndex { $0.ok != false }, false)
  }

  /// The kubb tipped `t` of the way up onto end i, as a hand lifts it: the other end rises,
  /// pivoting on the bottom edge of end i's face, until at t = 1 it stands on that end's
  /// footprint. The engine's own crank raise (core/raising.lua tipPose), for drawing only.
  static func tilt(_ need: MatchNeed, lying: Piece, i: Int, t: Double) -> Piece {
    guard t > 0, let pose = need.pose else { return lying }
    let u = axis(need, i)
    let th = t * .pi / 2
    let q = simd_quatd(angle: th, axis: V3(-u.y, u.x, 0)) * lying.rotation
    let px = pose.x + u.x * halfLength, py = pose.y + u.y * halfLength
    let a = -halfLength * cos(th) + halfSide * sin(th)
    let z = halfLength * sin(th) + halfSide * cos(th)
    var p = lying
    p.x = px + u.x * a
    p.y = py + u.y * a
    p.z = z
    p.qw = q.real
    p.qx = q.imag.x
    p.qy = q.imag.y
    p.qz = q.imag.z
    return p
  }
}

/// One end of the kubb on the raise screen: its footprint and its numbered label.
public struct RaiseEndPoint: Sendable {
  public let index: Int, which: Int
  public let footprint: CGPoint, label: CGPoint
  public let ok: Bool, lit: Bool
  public let why: String?
}

extension PitchSession {
  /// The lying kubb as drawn on the raise screen, or nil.
  public func raiseGeometry(in size: CGSize) -> RaiseTouch.Geometry? {
    guard let n = need, n.kind == "raise", let pose = n.pose, let id = n.kubb else { return nil }
    return RaiseTouch.geometry(
      n, piece: pose.piece(id: id), projection: scene.projection(size, camera))
  }

  /// The end lit on the raise screen: a drag past half way, or the allowed end's hint.
  var raiseLit: Int? { raiseSelected ?? raiseHint?.i }

  /// Where the ends' footprints and their numbers sit on the screen. A number sits a
  /// little beyond its footprint, along the kubb from its middle.
  public func raiseEnds(in size: CGSize) -> [RaiseEndPoint] {
    guard let n = need, n.kind == "raise", let pose = n.pose else { return [] }
    let p = scene.projection(size, camera)
    return (n.ends ?? []).enumerated().compactMap { i, e in
      let d = V2(e.pose.x - pose.x, e.pose.y - pose.y)
      let l = simd_length(d) == 0 ? 1 : simd_length(d)
      guard let f = p.project(V3(e.pose.x, e.pose.y, 0)),
        let q = p.project(V3(e.pose.x + d.x / l * 0.07, e.pose.y + d.y / l * 0.07, 0))
      else { return nil }
      return RaiseEndPoint(
        index: i, which: e.which, footprint: f, label: q, ok: e.ok != false, lit: i == raiseLit,
        why: e.why)
    }
  }

  /// Which end a tap means: an end's number, anywhere on the drawn kubb (the nearer end),
  /// or near an end's footprint on the ground. nil for none of them.
  public func raisePick(at point: CGPoint, size: CGSize) -> Int? {
    var pick: Int?
    for e in raiseEnds(in: size) where e.label.distance(to: point) < RaiseTouch.labelR {
      pick = e.index
    }
    if let pick { return pick }
    if let g = raiseGeometry(in: size), RaiseTouch.on(g, point) {
      return RaiseTouch.nearerEnd(g, point)
    }
    guard let n = need, let ground = scene.projection(size, camera).ground(point) else {
      return nil
    }
    var best: Int?
    var bd = 0.45
    for (i, e) in (n.ends ?? []).enumerated() {
      let d = hypot(e.pose.x - ground.x, e.pose.y - ground.y)
      if d < bd {
        bd = d
        best = i
      }
    }
    return best
  }

  /// A tap, or a drag let go, on end i: stand it there, or, when the rules refuse that
  /// end, light the one they allow for a moment and send nothing. True when it stood.
  @discardableResult public func raiseTap(_ i: Int) throws -> Bool {
    guard let n = need, n.kind == "raise" else { return false }
    let pick = RaiseTouch.allowed(n, i)
    if pick.ok, let e = n.ends?[i] { return try raise(end: e.which) }
    if let j = pick.i { try showRaiseHint(j) }
    return false
  }

  /// A drag that started on the kubb (`geometry`, kept from the press): tip it up toward
  /// the end the finger moves to, never toward a refused end (that lights the allowed one).
  public func raiseDrag(_ g: RaiseTouch.Geometry, from: CGPoint, to: CGPoint) throws {
    guard let n = need, n.kind == "raise", acceptsInput else { return }
    let d = RaiseTouch.drag(g, from: from, to: to)
    if n.ends?[d.i].ok == false {
      let was = raiseDragging != nil
      raiseDragging = nil
      raiseSelected = nil
      if let j = RaiseTouch.allowed(n, d.i).i, raiseHint?.i != j || was {
        try showRaiseHint(j)
      } else if was {
        try settleScene()
        revision += 1
      }
      return
    }
    guard d != raiseDragging else { return }
    raiseDragging = d
    raiseSelected = d.t >= RaiseTouch.stand ? d.i : nil
    try settleScene()
    revision += 1
  }

  /// The finger lifted after a drag: past half way it stands on the end it was tipped
  /// toward; short of that it lies back down and nothing is sent.
  public func raiseLetGo() throws {
    let d = raiseDragging
    raiseDragging = nil
    raiseSelected = nil
    if let d, d.t >= RaiseTouch.stand, try raiseTap(d.i) { return }
    if d != nil, need?.kind == "raise" {
      try settleScene()
      revision += 1
    }
  }

  /// A drag cancelled (the system took the touch): the kubb lies back down.
  public func raiseCancel() {
    guard raiseDragging != nil || raiseSelected != nil else { return }
    raiseDragging = nil
    raiseSelected = nil
    try? settleScene()
    revision += 1
  }

  private func showRaiseHint(_ i: Int) throws {
    raiseHint = (i, RaiseTouch.hint)
    try settleScene()
    revision += 1
  }

  /// The hint's second passing. True when it went out.
  func raiseHintTick(_ dt: Double) throws -> Bool {
    guard let h = raiseHint else { return false }
    if h.left - dt > 0 {
      raiseHint = (h.i, h.left - dt)
      return false
    }
    raiseHint = nil
    try settleScene()
    revision += 1
    return true
  }

  func resetRaiseTouch() {
    raiseDragging = nil
    raiseSelected = nil
    raiseHint = nil
  }
}

extension PitchSession {
  /// The ends as a screen reader hears them: "end 1 on the left", "end 2 on the right
  /// (blocked)" (the web's describeRaise). Left and right are as drawn: the projection is
  /// the same up to scale on any screen, so any size gives the same order.
  public func raiseEndNames() -> [(index: Int, which: Int, name: String, ok: Bool)] {
    let pts = raiseEnds(in: CGSize(width: 400, height: 800))
    return pts.map { e in
      let other = pts.first { $0.index != e.index }
      let side = other.map { e.label.x < $0.label.x ? " on the left" : " on the right" } ?? ""
      let why = e.ok ? "" : " (\((e.why ?? "blocked").lowercased()))"
      return (e.index, e.which, "end \(e.index + 1)\(side)\(why)", e.ok)
    }
  }
}
