import CoreGraphics
import Foundation
import simd

let ink = 0x17140f
let paper = 0xfbf6ea
let white = 0xffffff

func color(_ rgb: Int, _ alpha: Double = 1) -> CGColor {
  CGColor(
    srgbRed: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255,
    blue: Double(rgb & 255) / 255, alpha: alpha)
}

func path(_ points: [CGPoint], closed: Bool = true) -> CGPath {
  let path = CGMutablePath()
  guard let first = points.first else { return path }
  path.move(to: first)
  for p in points.dropFirst() { path.addLine(to: p) }
  if closed { path.closeSubpath() }
  return path
}

func hull(_ points: [CGPoint]) -> [CGPoint] {
  let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
  func half(_ seq: [CGPoint]) -> [CGPoint] {
    var chain: [CGPoint] = []
    for p in seq {
      while chain.count >= 2 {
        let a = chain[chain.count - 2]
        let b = chain[chain.count - 1]
        if (b.x - a.x) * (p.y - a.y) > (b.y - a.y) * (p.x - a.x) { break }
        chain.removeLast()
      }
      chain.append(p)
    }
    return chain
  }
  return Array(half(sorted).dropLast() + half(sorted.reversed()).dropLast())
}

struct Painter {
  let ctx: CGContext
  let projection: PitchProjection

  func fill(_ p: CGPath, _ paint: Int, alpha: Double = 1) {
    ctx.setFillColor(color(paint, alpha))
    ctx.addPath(p)
    ctx.fillPath()
  }
  func stroke(_ p: CGPath, _ paint: Int, _ width: Double, alpha: Double = 1) {
    ctx.setStrokeColor(color(paint, alpha))
    ctx.setLineWidth(width)
    ctx.addPath(p)
    ctx.strokePath()
  }
  func outlined(_ p: CGPath, _ paint: Int, _ width: Double) {
    stroke(p, ink, width + 2.2)
    stroke(p, paint, width)
  }
  func poly(_ world: [V3]) -> CGPath { path(projection.polygon(world)) }
  func quad(_ x: Double, _ y: Double, _ X: Double, _ Y: Double) -> CGPath {
    poly([V3(x, y, 0), V3(X, y, 0), V3(X, Y, 0), V3(x, Y, 0)])
  }
  func ring(_ center: V3, _ r: Double) -> CGPath {
    poly(
      (0..<48).map { i in
        let a = Double(i) * .pi / 24
        return center + r * V3(cos(a), sin(a), 0)
      })
  }
  func line(_ a: V3, _ b: V3) -> CGPath {
    let points = projection.polygon([a, b])
    return path(points, closed: false)
  }
}

public enum PitchRenderer {
  /// Draws in a top-left-origin context. The caller supplies the backing scale.
  /// `look`: the scene to draw (nil: the scene's own, `scene.look`); an unknown one
  /// is the day. `effects`: its stardust or sparks; `time` (s) moves the night's
  /// twinkling stars, still under Reduce Motion (`reduced`).
  public static func draw(
    in context: CGContext, size: CGSize, camera: Camera, scene: PitchScene, look: String? = nil,
    effects: SceneEffects? = nil, time: Double = 0, reduced: Bool = false
  ) {
    guard size.width > 0, size.height > 0 else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.setLineJoin(.round)
    context.setLineCap(.round)
    let p = Painter(ctx: context, projection: scene.projection(size, camera))
    let shown = SceneID.shown(look ?? scene.look)
    if shown != "day" {
      p.scenic(scene, look: shown, effects: effects?.look == shown ? effects : nil, time: reduced ? 0 : time)
      return
    }
    p.ground(scene)
    p.marks(scene)
    p.pieces(scene)
    if let arc = scene.arc { p.trajectory(arc, ground: false) }
  }
}

private struct GroundColors {
  let pitch, stripe, rough, speck, sky, haze, line: Int
  init(_ s: Surface) {
    switch s {
    case .grass:
      (pitch, stripe, rough, speck, sky, haze, line) = (
        0x5fa43c, 0x6bb146, 0x3f7a2a, 0x2f6120, 0xd8ecf2, 0xc4dfc0, white
      )
    case .sand:
      (pitch, stripe, rough, speck, sky, haze, line) = (
        0xe8cf98, 0xefd8a6, 0xd2b277, 0xb8955a, 0xf3e6cf, 0xeadbb9, white
      )
    case .snow:
      (pitch, stripe, rough, speck, sky, haze, line) = (
        0xeef3f8, 0xf7fafd, 0xd3dfec, 0xb4c6da, 0xc9d9ea, 0xdfe8f2, 0x4f86c6
      )
    case .grid:
      // Techno's floor seen by daylight: only a match from before scenes decided the
      // ground could put it here (the engine keeps a recorded surface)
      (pitch, stripe, rough, speck, sky, haze, line) = (
        0x3a4250, 0x414a59, 0x2a313c, 0x1f252e, 0xd8e2ec, 0xb9c4d0, white
      )
    }
  }
}

// Match the web's unsigned 32-bit texture seed. Immutable marks, generated once.
func woodHash(_ value: UInt32) -> Double {
  var n = (value ^ 61 ^ (value >> 16)) &* 9
  n = (n ^ (n >> 4)) &* 0x27d4_eb2d
  return Double(n ^ (n >> 15)) / 4_294_967_296
}
private func texture(_ step: Double) -> [V3] {
  var pts = [V3]()
  var n: UInt32 = 0
  var x = -12.0
  while x <= 12 {
    var y = -6.0
    while y <= 22 {
      n += 1
      let jx = x + (woodHash(n * 7 + 1) - 0.5) * step
      let jy = y + (woodHash(n * 13 + 5) - 0.5) * step
      if abs(jx) >= 2.62 || jy <= -0.12 || jy >= 8.12 {
        pts.append(V3(jx, jy, woodHash(n * 31 + 11)))
      }
      y += step
    }
    x += step
  }
  return pts
}
let grassMarks = texture(0.42)
let otherMarks = texture(0.36)

extension Painter {
  fileprivate func ground(_ scene: PitchScene) {
    let g = GroundColors(scene.surface)
    let c = projection.c
    let bounds = CGRect(origin: .zero, size: projection.size)
    let horizontal = hypot(c.fx, c.fy)
    // Project both ends of the far edge so the same fit works with a rolled camera.
    let far = V3(c.px, c.py, 0) + V3(c.fx, c.fy, 0) * (200 / max(horizontal, 0.001))
    let side = V3(c.fy, -c.fx, 0) * (2000 / max(horizontal, 0.001))
    if horizontal > 0.05, let a = projection.project(far - side),
      let b = projection.project(far + side),
      abs(b.x - a.x) > 1
    {
      let slope = (b.y - a.y) / (b.x - a.x)
      let left = CGPoint(x: 0, y: a.y - a.x * slope)
      let right = CGPoint(x: bounds.width, y: left.y + bounds.width * slope)
      let skyHeight = min(bounds.height, max(left.y, right.y) + 1)
      if skyHeight > 0 {
        ctx.setFillColor(color(g.sky))
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: skyHeight))
      }
      fill(
        path([
          left, right, CGPoint(x: right.x, y: max(right.y, bounds.height) + 4),
          CGPoint(x: 0, y: max(left.y, bounds.height) + 4),
        ]), g.rough)
      if max(left.y, right.y) + 14 * projection.k * hypot(1, slope) >= 0,
        min(left.y, right.y) <= bounds.height,
        let gradient = CGGradient(
          colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
          colors: [color(g.haze), color(g.rough)] as CFArray, locations: [0, 1])
      {
        let band = 14 * projection.k / hypot(1, slope)
        ctx.drawLinearGradient(
          gradient, start: left,
          end: CGPoint(x: left.x - band * slope, y: left.y + band), options: [])
      }
    } else {
      ctx.setFillColor(color(g.sky))
      ctx.fill(bounds)
      fill(quad(-400, -400, 400, 400), g.rough)
    }

    specks(scene.surface, g.speck)
    fill(quad(-2.5, 0, 2.5, 8), g.pitch)
    for x in [-2.5, -0.5, 1.5] { fill(quad(x, 0, x + 1, 8), g.stripe) }
    func stripe(_ x: Double, _ y: Double, _ X: Double, _ Y: Double) {
      let w = 0.006
      fill(quad(x - w, y - w, X + w, Y + w), g.line)
      stroke(line(V3(x, y, 0), V3(X, Y, 0)), g.line, 0.6 * projection.k)
    }
    for x in [-2.5, 2.5] { stripe(x, 0, x, 8) }
    for y in [0.0, 8.0] { stripe(-2.5, y, 2.5, y) }
    func dashed(_ y: Double, _ on: Double, _ off: Double) {
      for x in stride(from: -2.5, to: 2.5, by: on + off) { stripe(x, y, min(x + on, 2.5), y) }
    }
    dashed(4, 0.24, 0.16)
    if let adv = scene.advantageY { dashed(adv, 0.1, 0.1) }
  }

  /// The rough's texture: tufts on grass, grains on sand and snow; `inside`: only
  /// those in a scene's clearing.
  func specks(
    _ surface: Surface, _ speck: Int, inside: (x0: Double, x1: Double, y0: Double, y1: Double)? = nil
  ) {
    let c = projection.c
    let bounds = CGRect(origin: .zero, size: projection.size)
    let grass = surface == .grass
    // Short batches of straight-sided ink marks avoid Quartz constructing a
    // rounded stroke outline for every blade on every display tick.
    ctx.saveGState()
    ctx.setShouldAntialias(false)
    ctx.setFillColor(color(speck))
    var count = 0
    ctx.beginPath()
    let visible = bounds.insetBy(dx: -4, dy: -4)
    for m in grass ? grassMarks : otherMarks {
      if let r = inside, m.x < r.x0 || m.x > r.x1 || m.y < r.y0 || m.y > r.y1 { continue }
      let eye = projection.view(V3(m.x, m.y, 0))
      guard eye.z > 0.3, eye.z < 30 else { continue }
      let point = projection.screen(eye)
      guard visible.contains(point) else { continue }
      let unit = c.f * projection.k / eye.z
      let x = point.x
      let y = point.y
      if grass {
        let h = (0.035 + m.z * 0.03) * unit
        let w = h * 0.45
        guard h >= 1.2 else { continue }
        ctx.move(to: CGPoint(x: x - w - 0.45, y: y - h * 0.8))
        ctx.addLine(to: CGPoint(x: x - 0.45, y: y + 0.4))
        ctx.addLine(to: CGPoint(x: x + 0.45, y: y + 0.4))
        ctx.addLine(to: CGPoint(x: x + w * 0.6 + 0.45, y: y - h))
        ctx.addLine(to: CGPoint(x: x + 0.25, y: y - h * 0.36))
        ctx.addLine(to: CGPoint(x: x - w * 0.1, y: y - h * 1.1))
        ctx.addLine(to: CGPoint(x: x - 0.35, y: y - h * 0.30))
        ctx.closePath()
      } else {
        let w = (0.03 + m.z * 0.03) * unit
        guard w >= 1 else { continue }
        ctx.addRect(CGRect(x: x - w / 2, y: y - 0.55, width: w, height: 1.1))
      }
      count += 1
      if count.isMultiple(of: 32) { ctx.fillPath() }
    }
    ctx.fillPath()
    ctx.restoreGState()
  }

  /// `track`: the planned throw's trace on the ground (a scene's skin).
  func marks(_ scene: PitchScene, track: (rgb: Int, alpha: Double) = (ink, 0.28)) {
    for m in scene.keepOut ?? [] {
      let p = ring(m.point, m.r ?? 0)
      fill(p, 0xe5484d, alpha: 0.32)
      ctx.setLineDash(phase: 0, lengths: [5, 4])
      stroke(p, 0xc42b31, 2)
      ctx.setLineDash(phase: 0, lengths: [])
    }
    for m in scene.footprints ?? [] {
      let a = m.angle ?? 0
      let u = V3(cos(a), sin(a), 0) * 0.035
      let v = V3(-sin(a), cos(a), 0) * 0.035
      let c = m.point
      let p = poly([c - u - v, c + u - v, c + u + v, c - u + v])
      if m.allowed == false {
        for mark in [p, line(c - u - v, c + u + v), line(c - u + v, c + u - v)] {
          outlined(mark, 0xe5484d, 2.5)
        }
      } else if m.chosen == true {
        fill(p, 0xfff6c8, alpha: 0.45)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        outlined(p, 0xfff6c8, 3)
        ctx.setLineDash(phase: 0, lengths: [])
      } else {
        outlined(p, white, 2.5)
      }
    }
    if let arc = scene.arc { trajectory(arc, ground: true, track: track) }
    if let t = scene.thrower {
      outlined(ring(t.point, 0.2), white, 2.5)
      let sign = t.facing == -1 ? -1.0 : 1.0
      let p = poly([
        t.point + V3(0, 0.42 * sign, 0), t.point + V3(-0.12, 0.24 * sign, 0),
        t.point + V3(0.12, 0.24 * sign, 0),
      ])
      fill(p, white)
      stroke(p, ink, 2)
    }
    if let m = scene.marker, m.shown != false, let r = m.r {
      let p = ring(m.point, r)
      fill(p, 0xfff6c8, alpha: 0.18)
      outlined(p, 0xfff6c8, 3)
      let d = r * 0.45
      for v in [V3(d, 0, 0), V3(0, d, 0)] {
        outlined(line(m.point - v, m.point + v), 0xfff6c8, 2.5)
      }
    }
  }

  func trajectory(_ arc: [V3], ground: Bool, track: (rgb: Int, alpha: Double) = (ink, 0.28)) {
    guard let end = arc.last else { return }
    let p = CGMutablePath()
    var last: V3?
    var pen = false
    for var v in arc {
      var stop = false
      if ground {
        v.z = 0
      } else if let last {
        func distance(_ q: V3) -> Double { hypot(q.x - end.x, q.y - end.y) }
        let da = distance(last)
        let db = distance(v)
        if db <= 0.45 && da > db {
          v = last + (v - last) * max(0, (da - 0.45) / (da - db))
          stop = true
        }
      }
      if let q = projection.project(v) {
        if pen { p.addLine(to: q) } else { p.move(to: q) }
        pen = true
      } else {
        pen = false
      }
      last = v
      if stop { break }
    }
    ctx.setLineDash(phase: 0, lengths: ground ? [3, 5] : [7, 6])
    if ground { stroke(p, track.rgb, 2.5, alpha: track.alpha) } else { outlined(p, white, 2.5) }
    ctx.setLineDash(phase: 0, lengths: [])
  }
}
