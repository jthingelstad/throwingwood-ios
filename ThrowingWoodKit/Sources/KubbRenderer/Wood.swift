import CoreGraphics
import simd

private let light = simd_normalize(V3(-0.55, 0.3, 1))
private let faces = [
  [0, 2, 6, 4], [1, 3, 7, 5], [0, 1, 5, 4], [2, 3, 7, 6], [0, 1, 3, 2], [4, 5, 7, 6],
]
private let stakes = [0.0, 4, 8].flatMap { y in
  [-2.5, 2.5].map { x in
    Piece(id: "stake", kind: "stake", team: nil, x: x, y: y, z: 0.075, qw: 1, qx: 0, qy: 0, qz: 0)
  }
}

private struct Paint {
  typealias Band = (lo: Double, hi: Double, rgb: Int)
  let bands: [Band]
  let detail: Int
  init?(_ set: String) {
    switch set {
    case "usa":
      bands = [(0.8, 1, 0x1f3a7a), (0.71, 0.75, 0xc8102e), (0.62, 0.66, 0xc8102e)]
      detail = white
    case "sweden":
      bands = [(0.9, 1, 0x006aa7), (0.76, 0.86, 0x006aa7), (0.86, 0.9, 0xfecc02)]
      detail = 0xfecc02
    case "minnesota":
      bands = [(0.76, 1, 0x0b2a55)]
      detail = 0x7ec8e3
    case "wisconsin":
      bands = [(0.78, 1, 0xf7c33b), (0.73, 0.78, 0xc5050c)]
      detail = 0xd9961a
    default: return nil
    }
  }
}

struct Solid {
  let piece: Piece, axes: [V3], extents: V3, corners: [V3], depth: Double
  init(_ item: Piece, _ c: Camera) {
    piece = item
    depth = dot(item.center - c.eye, c.forward)
    let side: Double
    switch item.kind {
    case "king": side = 0.045
    case "baton": side = 0.022
    case "stake": side = max(0.0095, 1.5 * depth / c.f)
    default: side = 0.035
    }
    let length = ["king", "baton"].contains(item.kind) ? 0.15 : 0.075
    extents = V3(side, side, length)
    let rot = item.rotation
    let x = rot.act(V3(1, 0, 0))
    let y = rot.act(V3(0, 1, 0))
    let z = rot.act(V3(0, 0, 1))
    axes = [x, y, z]
    corners = (0..<8).map { i in
      let a = (i & 1 == 0 ? -side : side) * x
      let b = (i & 2 == 0 ? -side : side) * y
      let c = (i & 4 == 0 ? -length : length) * z
      return item.center + a + b + c
    }
  }

  // For overlapping screen boxes, choose the separating plane with the largest gap.
  func precedes(_ b: Solid, eye: V3) -> Bool {
    var gap = -Double.infinity
    var behind = depth >= b.depth
    func consider(_ n: V3) {
      let ca = dot(piece.center, n)
      let cb = dot(b.piece.center, n)
      func radius(_ s: Solid) -> Double {
        (0..<3).reduce(0) { $0 + s.extents[$1] * abs(dot(n, s.axes[$1])) }
      }
      let ra = radius(self)
      let rb = radius(b)
      let separation = abs(cb - ca) - ra - rb
      if separation > gap {
        gap = separation
        let split = (ca + cb + (cb >= ca ? ra - rb : rb - ra)) / 2
        behind = cb >= ca ? dot(eye, n) > split : dot(eye, n) < split
      }
    }
    for n in axes + b.axes { consider(n) }
    for a in axes {
      for axis in b.axes {
        let n = cross(a, axis)
        let len = simd_length(n)
        if len > 1e-6 { consider(n / len) }
      }
    }
    return behind
  }
}

struct Projected {
  let solid: Solid, points: [CGPoint], bounds: CGRect
  init?(_ s: Solid, _ projection: PitchProjection) {
    let points = s.corners.compactMap(projection.project)
    guard points.count == 8 else { return nil }
    var bounds = CGRect.null
    for p in points { bounds = bounds.union(CGRect(origin: p, size: .zero)) }
    self.bounds = bounds.insetBy(dx: -2, dy: -2)
    guard self.bounds.intersects(CGRect(origin: .zero, size: projection.size)) else { return nil }
    self.points = points
    solid = s
  }
}

extension Painter {
  /// `paint`: the scene's light and paint (the day by default). `before`: drawn
  /// after the shadows and under the pieces (a scene's halos), `baton`: a scene's
  /// own baton.
  func pieces(
    _ scene: PitchScene, paint pp: PiecePaint = .day, shadows drawShadows: Bool = true,
    before: (([Projected]) -> Void)? = nil, baton sceneBaton: ((Solid, Double) -> Void)? = nil
  ) {
    let all = scene.items.contains { $0.kind == "stake" } ? scene.items : scene.items + stakes
    var shown: [Projected] = []
    // a scene's shadows are one translucent fill, so two that overlap are not darker
    let shadows = CGMutablePath()
    for item in all {
      let s = Solid(item, projection.c)
      if item.kind != "stake" && drawShadows {
        let shadow = s.corners.map { v in
          CGPoint(x: v.x + pp.shadowX * max(v.z, 0), y: v.y + pp.shadowY * max(v.z, 0))
        }
        let outline = poly(hull(shadow).map { V3($0.x, $0.y, 0) })
        if pp.isDay { fill(outline, ink) } else { shadows.addPath(outline) }
      }
      if let p = Projected(s, projection) { shown.append(p) }
    }
    if !pp.isDay && drawShadows { fill(shadows, pp.shadowFill, alpha: pp.shadowAlpha) }
    before?(shown)
    shown.sort { $0.solid.depth > $1.solid.depth }
    var before = Array(repeating: Set<Int>(), count: shown.count)
    for i in shown.indices {
      for j in 0..<i where shown[i].bounds.intersects(shown[j].bounds) {
        if shown[i].solid.precedes(shown[j].solid, eye: projection.c.eye) {
          before[j].insert(i)
        } else {
          before[i].insert(j)
        }
      }
    }
    var remaining = Array(shown.indices)
    while let fallback = remaining.first {
      let i = remaining.first { before[$0].isEmpty } ?? fallback
      if let spin = scene.spins?[shown[i].solid.piece.id] {
        spinning(shown[i], spin) { wood($0, set: scene.set, paint: pp, baton: sceneBaton) }
      } else {
        wood(shown[i], set: scene.set, paint: pp, baton: sceneBaton)
      }
      remaining.removeAll { $0 == i }
      for j in remaining { before[j].remove(i) }
    }
  }

  private func wood(
    _ projected: Projected, set: String, paint pp: PiecePaint, baton sceneBaton: ((Solid, Double) -> Void)?
  ) {
    let s = projected.solid
    let p = projected.points
    let item = s.piece
    let tall = projection.k * projection.c.f * 2 * s.extents.z / s.depth
    let width = min(3.4, max(1, tall / 20))
    if item.kind == "baton" {
      if let sceneBaton { sceneBaton(s, width) } else { baton(s, width: width) }
      return
    }
    let king = item.kind == "king"
    let stake = item.kind == "stake"
    // a scene paints the whole body (the night's glowing set, the neon's solids)
    let paint = pp.isDay ? Paint(set) : nil
    let lit = pp.litOf?(item)
    let edge = lit?.ink ?? pp.outline
    let tones = stake ? pp.stake : (king ? pp.kingWood : pp.wood)
    let light = pp.light
    let eye = projection.c.eye - item.center
    // The far walls and the recessed floor show through the crown's V cuts.
    if king && dot(eye, s.axes[2]) > 0 {
      let floor = (0..<4).map { CGPoint.between(p[$0], p[$0 + 4], 0.89) }
      for i in 0..<4 {
        let n = s.axes[i / 2] * (i.isMultiple(of: 2) ? -1.0 : 1)
        if dot(eye, n) > s.extents[i / 2] { continue }
        let a = faces[i][0]
        let b = faces[i][1]
        let wall = path([
          .between(p[a], p[a + 4], 0.73), .between(p[b], p[b + 4], 0.73),
          p[b + 4], .between(floor[a], floor[b], 0.75), .between(p[a + 4], p[b + 4], 0.5),
          .between(floor[a], floor[b], 0.25), p[a + 4],
        ])
        fill(wall, paint?.bands[0].rgb ?? tones.shade)
        stroke(wall, edge, width * 0.55)
      }
      fill(path([floor[0], floor[1], floor[3], floor[2]]), paint?.bands[0].rgb ?? tones.endShade)
    }
    let seed = item.id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    for i in faces.indices {
      let axis = i / 2
      let n = s.axes[axis] * (i.isMultiple(of: 2) ? -1.0 : 1.0)
      let visible = dot(eye, n) > s.extents[axis]
      guard visible else { continue }
      let f = faces[i].map { p[$0] }
      func at(_ u: Double, _ h: Double) -> CGPoint {
        .between(.between(f[0], f[3], h), .between(f[1], f[2], h), u)
      }
      func band(_ lo: Double, _ hi: Double, _ rgb: Int, _ left: Double = 0, _ right: Double = 1) {
        fill(path([at(left, lo), at(right, lo), at(right, hi), at(left, hi)]), rgb)
      }
      func teeth(_ base: Double) -> CGPath {
        path([
          at(0, base), at(1, base), at(1, 1), at(0.75, 0.89), at(0.5, 1), at(0.25, 0.89), at(0, 1),
        ])
      }
      let dark = dot(n, light) <= pp.awayBelow
      func pigment(_ rgb: Int) -> Int {
        guard dark else { return rgb }
        func channel(_ shift: Int) -> Int {
          Int((Double((rgb >> shift) & 255) * 0.58 + Double((ink >> shift) & 255) * 0.42).rounded())
            << shift
        }
        return channel(16) | channel(8) | channel(0)
      }
      let end = axis == 2
      if king && i == 5 { continue }
      let face = king && !end ? teeth(0) : path(f)
      let wood: Int =
        end
        ? (dark ? tones.endShade : tones.end)
        : (dark ? tones.shade : (dot(n, light) >= pp.topAbove ? tones.top : tones.light))
      fill(face, wood)
      if !stake {
        if !end {
          if tall >= 26 {
            let top = king ? 0.6 : 1.0
            let count = king ? 3 : (tall >= 52 ? 4 : 2)
            let faceSeed = seed &+ UInt32(i * (king ? 7 : 101))
            for j in 0..<count {
              func hash(_ stride: Int) -> Double { woodHash(faceSeed &+ UInt32(j * stride)) }
              let u = 0.16 + 0.68 * (Double(j) + hash(17)) / Double(count)
              let lo = (0.06 + hash(29) * 0.18) * top
              let hi = (0.62 + hash(41) * 0.32) * top
              let grain = CGMutablePath()
              grain.move(to: at(u, lo))
              grain.addQuadCurve(
                to: at(u, hi), control: at(u + (hash(53) - 0.5) * 0.12, (lo + hi) / 2))
              stroke(grain, dark ? tones.grainShade : tones.grain, width * 0.5)
            }
          }
          if king {
            if let paint { fill(teeth(0.66), pigment(paint.bands[0].rgb)) }
            band(0.66, 0.73, pp.kingMark)
            if tall >= 40 && !dark {
              stroke(path([at(0, 0.6), at(1, 0.6)], closed: false), pp.kingMark, width * 0.7)
              fill(path([at(0.5, 0.54), at(0.72, 0.47), at(0.5, 0.4), at(0.28, 0.47)]), pp.kingMark)
            }
          } else {
            if let team = item.team, pp.teamBands {
              if let b = lit?.band, let deep = lit?.bandDeep {
                band(0.05, 0.13, dark ? deep : b)
              } else {
                band(
                  0.05, 0.13,
                  team == "A" ? (dark ? 0xb98500 : 0xf2b705) : (dark ? 0x5e2777 : 0x8e44ad))
              }
            }
            for b in paint?.bands ?? [] { band(b.lo, b.hi, pigment(b.rgb)) }
          }
          if let paint, tall >= (king ? 40 : 34), !king || !dark {
            let b = paint.bands[0]
            let lo = king ? 0.73 : b.lo
            let hi = king ? 0.89 : b.hi
            let mid = (hi + lo) / 2
            let h = at(0.5, lo).distance(to: at(0.5, hi))
            let detail = king && set == "minnesota" ? white : pigment(paint.detail)
            switch set {
            case "sweden":
              band(king ? lo : 0.76, hi, detail, 0.3, 0.4)
              if king { band(mid - 0.02, mid + 0.02, detail, 0.06, 0.94) }
            case "wisconsin":
              for (u, v, r) in [(0.2, 0.3, 0.09), (0.55, 0.62, 0.12), (0.8, 0.25, 0.07)] {
                let c = at(u, lo + (hi - lo) * v)
                fill(
                  CGPath(
                    ellipseIn: CGRect(
                      x: c.x - r * h, y: c.y - r * h, width: 2 * r * h, height: 1.6 * r * h),
                    transform: nil), detail)
              }
            case "minnesota" where !king:
              let wave = (0...12).map {
                at(0.08 + Double($0) * 0.07, mid + sin(Double($0) * 1.3) * (hi - lo) * 0.18)
              }
              stroke(path(wave, closed: false), detail, max(width * 0.7, h * 0.12))
            default:
              for u in king ? [0.5] : [0.25, 0.5, 0.75] {
                let c = at(u, mid)
                let count = set == "minnesota" ? 8 : 10
                let star = (0..<count).map { j in
                  let a = Double(j) * 2 * .pi / Double(count) - .pi / 2
                  let r = h * (j.isMultiple(of: 2) ? 0.37 : 0.15)
                  return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                }
                fill(path(star), detail)
              }
            }
          }
        } else if let paint, i == 5 {
          fill(face, pigment(paint.bands[0].rgb))
        } else if tall >= 34 {
          for radius in [0.19, 0.36] {
            let ring = (0..<18).map { j in
              let a = Double(j) * .pi / 9
              return at(0.5 + radius * cos(a), 0.5 + radius * sin(a))
            }
            stroke(path(ring), pp.isDay || !dark ? tones.ring : tones.grainShade, width * 0.45)
          }
        }
        if !king && !dark && tall >= 46 {
          let center = at(0.5, 0.5)
          stroke(path(f.map { .between($0, center, 0.07) }), lit?.bevel ?? tones.bevel, width * 0.55)
        }
      }
      stroke(face, edge, width * (king ? 1 : 0.55))
    }
    if !king { stroke(path(hull(p)), edge, width) }
  }

  // Circular cross sections in world space. A baton is plain wood in every set,
  // with no bands (Jamie, 2026-11-20: "Batons are always plain and never
  // changed for the set."); the end cap shows its turn in flight.
  private func baton(_ s: Solid, width: Double) {
    let c = s.piece.center
    let axis = s.axes[2]
    func section(_ t: Double, radius: Double = 0.022) -> [CGPoint] {
      let center = c + axis * ((t - 0.5) * 0.30)
      return (0..<24).compactMap { i in
        let a = Double(i) * .pi / 12
        return projection.project(center + (s.axes[0] * cos(a) + s.axes[1] * sin(a)) * radius)
      }
    }
    let a = section(0)
    let b = section(1)
    let body = path(hull(a + b))
    fill(body, 0xecd2a0)
    let eye = simd_normalize(projection.c.eye - c)
    let normal = cross(axis, eye)
    if simd_length(normal) > 1e-8 {
      let side = simd_normalize(normal) * (dot(normal, light) > 0 ? -0.022 : 0.022)
      func edge(_ t: Double, _ r: Double) -> V3 { c + axis * ((t - 0.5) * 0.3) + side * r }
      fill(poly([edge(0, 0.25), edge(1, 0.25), edge(1, 1), edge(0, 1)]), ink, alpha: 0.32)
    }
    let projectedRadius = s.extents.x * projection.c.f * projection.k / s.depth
    if projectedRadius > 3 && simd_length(normal) > 1e-8 {
      let side = simd_normalize(normal) * (dot(normal, light) > 0 ? 0.011 : -0.011)
      stroke(
        line(c - axis * 0.15 + side, c + axis * 0.15 + side), 0xfff3d8,
        max(width * 0.6, projectedRadius * 0.18))
    }
    stroke(body, ink, width)
    let t = dot(axis, eye) > 0 ? 1.0 : 0
    let cap = path(t == 1 ? b : a)
    fill(cap, 0xe2bf86)
    stroke(cap, ink, width * 0.7)
    if projectedRadius > 6 {
      for r in [0.35, 0.68] { stroke(path(section(t, radius: 0.022 * r)), 0xc0935a, width * 0.45) }
    }
  }
}
