import CoreGraphics
import Foundation
import simd

// The night and the neon, drawn in the order of the web's drawWorld with a look
// (src/render/world.js, night.js, neon.js): the sky, the ground round the pitch,
// the pitch and its lines, the marks, the shadows, the pieces' light, the pieces,
// the effects and the planned arc. Web frame px are `k` points here; the web's
// CSS px are points.

private func mix(_ a: Int, _ b: Int, _ t: Double) -> Int {
  func ch(_ s: Int) -> Int {
    Int((Double(a >> s & 255) * (1 - t) + Double(b >> s & 255) * t).rounded()) << s
  }
  return ch(16) | ch(8) | ch(0)
}

/// A ground line from (x0, y0) to (x1, y1), axis aligned.
private typealias Segment = (x0: Double, y0: Double, x1: Double, y1: Double)

private func segments(_ scene: PitchScene) -> [Segment] {
  var segs: [Segment] = [(-2.5, 0, -2.5, 8), (2.5, 0, 2.5, 8), (-2.5, 0, 2.5, 0), (-2.5, 8, 2.5, 8)]
  func dashed(_ y: Double, _ on: Double, _ off: Double) {
    for x in stride(from: -2.5, to: 2.5, by: on + off) { segs.append((x, y, min(2.5, x + on), y)) }
  }
  dashed(4, 0.24, 0.16)
  if let adv = scene.advantageY { dashed(adv, 0.1, 0.1) }
  return segs
}

// ---------- the night's sky (made once) ----------

private struct Stars {
  var dir: [V3] = [], mag: [Double] = [], col: [Int] = [], tw: [Double] = []
  var band: (V3, V3) = (V3(0, 0, 0), V3(0, 0, 0))
}

private let stars: Stars = {
  let n = 5200
  func hash(_ i: Int) -> Double { woodHash(UInt32(truncatingIfNeeded: i)) }
  var s = Stars()
  // the milky band: a great circle through the aiming view's sky and the wide view's
  let a = V3(0, 1, -0.21)
  let b = V3(-1, 0.25, -0.46)
  let nrm = simd_normalize(cross(a, b))
  let u = simd_normalize(a)
  let v = cross(nrm, u)
  for i in 0..<n {
    var d: V3
    if hash(i * 7 + 3) < 0.38 {
      let t = hash(i * 11 + 1) * .pi * 2
      let off = (hash(i * 13 + 2) + hash(i * 17 + 5) + hash(i * 19 + 7) - 1.5) * 0.22
      d = u * cos(t) + v * sin(t) + nrm * off
      s.mag.append(0.15 + 0.5 * pow(hash(i * 23 + 9), 3))
    } else {
      let z = min(1, -0.75 + hash(i * 29 + 4) * 1.7)
      let r = max(0, 1 - z * z).squareRoot()
      let t = hash(i * 31 + 6) * .pi * 2
      d = V3(r * cos(t), r * sin(t), z)
      s.mag.append(0.12 + 0.88 * pow(hash(i * 37 + 8), 5))
    }
    s.dir.append(simd_normalize(d))
    s.col.append(Int(hash(i * 41 + 3) * 4))
    s.tw.append(hash(i * 43 + 1) < 0.025 ? .pi * 2 / (3 + hash(i * 47 + 2) * 4) : 0)
  }
  s.band = (u, v)
  return s
}()

private let moon: V3 = {
  let az = -4.5 * .pi / 180
  let el = -12.4 * .pi / 180
  return V3(sin(az) * cos(el), cos(az) * cos(el), sin(el))
}()

/// The rim's silhouette, one strip per side: along the side on the ground, back
/// along its tufts.
private let rim: [[V3]] = {
  let C = Night.clearing
  let sides = [
    (C.x0, C.y1, C.x1, C.y1), (C.x1, C.y1, C.x1, C.y0), (C.x1, C.y0, C.x0, C.y0),
    (C.x0, C.y0, C.x0, C.y1),
  ]
  return sides.enumerated().map { si, side in
    let (x0, y0, x1, y1) = side
    let n = Int((hypot(x1 - x0, y1 - y0) / 0.22).rounded(.up))
    func at(_ i: Int, _ z: Double) -> V3 {
      V3(x0 + (x1 - x0) * Double(i) / Double(n), y0 + (y1 - y0) * Double(i) / Double(n), z)
    }
    var pts = (0...n).map { at($0, 0) }
    for i in stride(from: n, through: 0, by: -1) {
      let h0 = woodHash(UInt32(si * 997 + i * 13))
      let clump = woodHash(UInt32(si * 991 + (i / 5) * 7)) > 0.8
      let h =
        clump
        ? 0.13 + (0.3 - 0.13) * sin(Double(i % 5) / 4 * .pi) * (0.6 + 0.4 * h0)
        : 0.03 + (0.13 - 0.03) * h0 * h0
      pts.append(at(i, h))
    }
    return pts
  }
}()

// ---------- the neon's grid (made once per spacing) ----------

private final class GridCache: @unchecked Sendable {
  private var grids: [Double: (major: [Segment], minor: [Segment])] = [:]
  private let lock = NSLock()
  func of(_ every: Double) -> (major: [Segment], minor: [Segment]) {
    lock.lock()
    defer { lock.unlock() }
    if let g = grids[every] { return g }
    var major: [Segment] = []
    var minor: [Segment] = []
    let far = 88.0
    let M = 4.0
    let chunk = 6.0
    let cy = 4.0
    for x in stride(from: -far, through: far + 1e-9, by: M) {
      for y in stride(from: cy - far, to: cy + far - 1e-9, by: chunk) { major.append((x, y, x, y + chunk)) }
    }
    for y in stride(from: cy - far, through: cy + far + 1e-9, by: M) {
      for x in stride(from: -far, to: far - 1e-9, by: chunk) { major.append((x, y, x + chunk, y)) }
    }
    func on(_ v: Double) -> Bool { abs(v / M - (v / M).rounded()) < 1e-6 }
    let R = 16.0
    let n = Int((R / every).rounded(.up))
    for i in -n...n {
      let v = Double(i) * every
      for u in stride(from: -R, to: R - 1e-9, by: 2) {
        if !on(v) { minor.append((v, cy + u, v, cy + u + 2)) }
        if !on(v + cy) { minor.append((u, cy + v, u + 2, cy + v)) }
      }
    }
    grids[every] = (major, minor)
    return (major, minor)
  }
}
private let gridCache = GridCache()
private let fade: [(to: Double, alpha: Double)] = [
  (5, 0.7), (10, 0.5), (18, 0.32), (32, 0.18), (.infinity, 0.08),
]

extension Painter {
  /// A direction at infinity on the screen, or nil behind the eye.
  func direction(_ d: V3) -> CGPoint? {
    let v = V3(dot(d, projection.c.right), dot(d, projection.c.up), dot(d, projection.c.forward))
    return v.z >= 0.05 ? projection.screen(v) : nil
  }
  /// Points per metre at eye depth `z`.
  func unit(_ z: Double) -> Double { projection.c.f * projection.k / z }

  func scenic(_ scene: PitchScene, look: String, effects: SceneEffects?, time: Double) {
    let night = look == "night"
    let g = night ? Night.ground(scene.surface) : Neon.ground(scene.surface)
    let bounds = CGRect(origin: .zero, size: projection.size)
    ctx.setFillColor(color(g.sky))
    ctx.fill(bounds.insetBy(dx: -2, dy: -2))
    if night {
      nightSky(time: time)
      clearing(g)
      specks(scene.surface, g.speck, inside: Night.clearing)
    } else {
      neonFloor(g)
    }
    fill(quad(-2.5, 0, 2.5, 8), g.pitch, alpha: g.pitchAlpha)
    if night { for x in [-2.5, -0.5, 1.5] { fill(quad(x, 0, x + 1, 8), g.stripe) } }
    let segs = segments(scene)
    let bands: [(w: Double, a: Double, pt: Double)] =
      night
      ? [(0.2, 0.05, 7), (0.12, 0.08, 4.5), (0.07, 0.12, 2.6)]
      : [(0.18, 0.07, 7), (0.09, 0.14, 3.5), (0.045, 0.28, 2)]
    ctx.saveGState()
    if g.additiveGlow { ctx.setBlendMode(.plusLighter) }
    for b in bands { paintLines(segs, g.glow, b.w, b.pt, alpha: b.a) }
    ctx.restoreGState()
    if night {
      paintLines(segs, g.line, 0.016, 0.65 * projection.k)
    } else {
      ctx.saveGState()
      ctx.setBlendMode(.plusLighter)
      paintLines(segs, g.line, 0.018, 1.1)
      ctx.restoreGState()
    }
    marks(scene, track: night ? (0xc8e1ff, 0.2) : (0x5ff0ff, 0.22))
    if g.reflect > 0 { reflections(scene, paint: .of(look), alpha: g.reflect) }
    pieces(
      scene, paint: .of(look),
      before: { halos($0, neon: !night) },
      baton: { s, _ in night ? moonlitBaton(s) : neonBaton(s) })
    effects?.draw(ctx, projection)
    if let arc = scene.arc { trajectory(arc, ground: false) }
  }

  /// The lines in one colour, `width` metres across on the ground, never under
  /// `least` points (the web's paintLines).
  private func paintLines(
    _ segs: [Segment], _ rgb: Int, _ width: Double, _ least: Double, alpha: Double = 1
  ) {
    let w = width / 2
    let quads = CGMutablePath()
    let cores = CGMutablePath()
    for s in segs {
      let q =
        s.y0 == s.y1 ? quad(s.x0 - w, s.y0 - w, s.x1 + w, s.y0 + w) : quad(s.x0 - w, s.y0 - w, s.x0 + w, s.y1 + w)
      quads.addPath(q)
      let n = max(1, Int(hypot(s.x1 - s.x0, s.y1 - s.y0).rounded(.up)))
      for i in 0..<n {
        let a = V3(s.x0 + (s.x1 - s.x0) * Double(i) / Double(n), s.y0 + (s.y1 - s.y0) * Double(i) / Double(n), 0)
        let b = V3(
          s.x0 + (s.x1 - s.x0) * Double(i + 1) / Double(n), s.y0 + (s.y1 - s.y0) * Double(i + 1) / Double(n), 0)
        cores.addPath(line(a, b))
      }
    }
    ctx.setAlpha(alpha)
    fill(quads, rgb)
    ctx.setLineCap(.butt)
    stroke(cores, rgb, least)
    ctx.setLineCap(.round)
    ctx.setAlpha(1)
  }

  // ---------- the night ----------

  /// The sky: the gradient, the milky band's haze, the moon's halo, the stars and
  /// the full moon, only in the rows down to the clearing's lowest corner.
  private func nightSky(time: Double) {
    let C = Night.clearing
    let size = projection.size
    var low = -Double.infinity
    for (x, y) in [(C.x0, C.y0), (C.x1, C.y0), (C.x0, C.y1), (C.x1, C.y1)] {
      guard let p = projection.project(V3(x, y, 0)) else {
        low = size.height
        break
      }
      low = max(low, p.y)
    }
    let rows = max(0, min(size.height, low + 4))
    guard rows > 0 else { return }
    let box = CGRect(x: -2, y: -2, width: size.width + 4, height: rows + 2)
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.clip(to: box)
    let c = projection.c
    let hl = max(hypot(c.fx, c.fy), 1e-9)
    let dip = -3 * Double.pi / 180
    let lowAt = direction(V3(c.fx / hl * cos(dip), c.fy / hl * cos(dip), sin(dip)))
    let y1 = lowAt.map { min(size.height, max(20, $0.y)) } ?? size.height
    rowGradient(box, from: 0, to: y1, [(0, 0x02040b, 1), (0.6, 0x081127, 1), (1, 0x16264a, 1)])
    ctx.setBlendMode(.plusLighter)
    let (u, v) = stars.band
    let r0 = 0.12 * c.f * projection.k
    for i in 0..<28 {
      let a = Double(i) / 28 * .pi * 2
      guard let p = direction(u * cos(a) + v * sin(a)) else { continue }
      if p.x + r0 < box.minX || p.x - r0 > box.maxX || p.y + r0 < box.minY || p.y - r0 > box.maxY { continue }
      Glow.draw(ctx, p.x, p.y, r0 * 1.3, r0 * 0.7, 0x9fb4ff, 0.075)
    }
    let mp = direction(moon)
    let R = 0.011 * c.f * projection.k
    if let mp {
      Glow.draw(ctx, mp.x, mp.y, R * 9, R * 9, 0xc9d8ff, 0.22)
      Glow.draw(ctx, mp.x, mp.y, R * 3.2, R * 3.2, 0xc9d8ff, 0.35)
    }
    // the stars: the steady ones in a few batches by colour and brightness, the
    // twinklers and the bright ones as glows
    let cols = [0xffffff, 0xfff1d2, 0xd6e4ff, 0xc9d8ff]
    var batches = [[CGRect]](repeating: [], count: 12)
    let px = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.d))
    var glows: [(CGPoint, Int)] = []
    for i in stars.dir.indices {
      guard let p = direction(stars.dir[i]), box.contains(p) else { continue }
      let m = stars.mag[i]
      if stars.tw[i] > 0 || m >= 0.7 { glows.append((p, i)) }
      if stars.tw[i] > 0 { continue }
      let band = m < 0.3 ? 0 : (m < 0.6 ? 1 : 2)
      let r = max(0.45, 0.35 + 1.3 * m * m)
      // its square in whole device pixels, about its own area, on the nearest pixels
      let side = max(1, (2 * r * px).rounded())
      batches[stars.col[i] * 3 + band].append(
        CGRect(
          x: (p.x * px - side / 2).rounded() / px, y: (p.y * px - side / 2).rounded() / px, width: side / px,
          height: side / px))
    }
    // a steady star is a few whole pixels, filled without antialiasing: thousands
    // of tiny antialiased squares were most of a night frame
    ctx.setShouldAntialias(false)
    for (k, rects) in batches.enumerated() where !rects.isEmpty {
      ctx.setFillColor(color(cols[k / 3], [0.38, 0.65, 0.95][k % 3]))
      ctx.fill(rects)
    }
    ctx.setShouldAntialias(true)
    for (p, i) in glows {
      let tw = stars.tw[i] > 0 ? 0.55 + 0.45 * sin(time * stars.tw[i] + Double(i)) : 1
      let r = 0.6 + 1.8 * stars.mag[i]
      Glow.draw(ctx, p.x, p.y, r * 2.6, r * 2.6, cols[stars.col[i]], 0.55 * tw, core: true)
    }
    guard let mp else { return }
    ctx.setBlendMode(.normal)
    let disc = CGPath(ellipseIn: CGRect(x: mp.x - R, y: mp.y - R, width: 2 * R, height: 2 * R), transform: nil)
    ctx.saveGState()
    ctx.addPath(disc)
    ctx.clip()
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
      let gradient = CGGradient(
        colorsSpace: space, colors: [color(0xf6f3e4), color(0xf6f3e4), color(0xddd6bd)] as CFArray,
        locations: [0, 0.8, 1])
    {
      ctx.drawRadialGradient(
        gradient, startCenter: CGPoint(x: mp.x - R * 0.2, y: mp.y - R * 0.2), startRadius: R * 0.1,
        endCenter: mp, endRadius: R, options: [.drawsAfterEndLocation])
    }
    ctx.restoreGState()
    let mares = CGMutablePath()
    for (ox, oy, rx, ry) in [
      (-0.3, -0.25, 0.28, 0.22), (0.18, -0.35, 0.2, 0.16), (0.05, 0.1, 0.32, 0.2),
      (-0.25, 0.38, 0.16, 0.12), (0.42, 0.2, 0.12, 0.1),
    ] {
      mares.addEllipse(
        in: CGRect(x: -rx * R, y: -ry * R, width: 2 * rx * R, height: 2 * ry * R),
        transform: CGAffineTransform(translationX: mp.x + ox * R, y: mp.y + oy * R).rotated(by: 0.4))
    }
    fill(mares, 0xcfc7ad, alpha: 0.55)
  }

  /// A vertical gradient over `box`, from `y0` to `y1` (held past both ends),
  /// each device pixel row in its 8-bit colour: a run of rows of one colour is
  /// one rectangle, filled whole. The same picture as shading every pixel, for a
  /// few dozen fills (CG shades a gradient pixel by pixel, the slowest part of a
  /// night frame).
  func rowGradient(
    _ box: CGRect, from y0: Double, to y1: Double, _ stops: [(t: Double, rgb: Int, a: Double)]
  ) {
    let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.d))
    let h = Int((box.height * scale).rounded(.up))
    guard h > 0, stops.count > 1, y1 > y0 else { return }
    // a row's colour as 0xAARRGGBB
    func at(_ j: Int) -> Int {
      let t = min(1, max(0, (box.minY + (Double(j) + 0.5) / scale - y0) / (y1 - y0)))
      let k = min(stops.count - 2, max(0, stops.lastIndex { $0.t <= t } ?? 0))
      let f = min(1, max(0, (t - stops[k].t) / max(1e-12, stops[k + 1].t - stops[k].t)))
      let a = stops[k], b = stops[k + 1]
      func ch(_ x: Double, _ y: Double) -> Int { Int((x + (y - x) * f).rounded()) }
      var v = ch(a.a * 255, b.a * 255) << 24
      for sh in [16, 8, 0] { v |= ch(Double((a.rgb >> sh) & 0xff), Double((b.rgb >> sh) & 0xff)) << sh }
      return v
    }
    ctx.saveGState()
    ctx.setShouldAntialias(false)
    var start = 0
    var run = at(0)
    for j in 1...h {
      let next = j < h ? at(j) : -1
      if next == run { continue }
      if run >> 24 > 0 {
        ctx.setFillColor(color(run & 0xffffff, Double(run >> 24) / 255))
        ctx.fill(
          CGRect(
            x: box.minX, y: box.minY + Double(start) / scale, width: box.width,
            height: Double(j - start) / scale))
      }
      start = j
      run = next
    }
    ctx.restoreGState()
  }

  /// The clearing: the ground ends round the pitch, darker toward its rim, and the
  /// rim's tufts stand against the sky.
  private func clearing(_ g: SceneGround) {
    let C = Night.clearing
    let tones = [0, 0.3, 0.52, 0.7, 0.84, 0.94, 1].map { mix(g.edge, g.rough, $0) }
    for (i, d) in [0, 0.25, 0.55, 0.9, 1.35, 1.9, 2.6].enumerated() {
      let p = projection.polygon([
        V3(C.x0 + d, C.y0 + d, 0), V3(C.x1 - d, C.y0 + d, 0), V3(C.x1 - d, C.y1 - d, 0),
        V3(C.x0 + d, C.y1 - d, 0),
      ])
      if p.count >= 3 { fill(path(p), tones[i]) }
    }
    let strips = CGMutablePath()
    for r in rim {
      let p = projection.polygon(r)
      if p.count >= 3 { strips.addPath(path(p)) }
    }
    fill(strips, g.rim)
  }

  // ---------- the neon ----------

  /// What stands on a glossy floor, mirrored in it: each piece turned over the ground
  /// (z to -z), drawn faint with no shadow, under the pieces.
  private func reflections(_ scene: PitchScene, paint: PiecePaint, alpha: Double) {
    var mirror = scene
    mirror.items = scene.items.map { p in
      var q = p
      q.z = -p.z
      // the rotation mirrored in the ground plane: (w, x, y, z) to (w, -x, -y, z)
      q.qx = -p.qx
      q.qy = -p.qy
      return q
    }
    if !mirror.items.contains(where: { $0.kind == "stake" }) {
      mirror.items += [0.0, 4, 8].flatMap { y in
        [-2.5, 2.5].map { x in
          Piece(id: "stake", kind: "stake", team: nil, x: x, y: y, z: -0.075, qw: 1, qx: 0, qy: 0, qz: 0)
        }
      }
    }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    pieces(mirror, paint: paint, shadows: false, baton: { s, _ in self.neonBaton(s) })
    ctx.endTransparencyLayer()
    ctx.restoreGState()
  }

  private func neonFloor(_ g: SceneGround) {
    let c = projection.c
    let size = projection.size
    if let floor = g.floor { glossy(floor, g.sheen) }
    // the horizon's glow: a soft band of the surface's light where floor meets black
    let hl = hypot(c.fx, c.fy)
    if hl >= 0.05 {
      let hx = c.fx / hl
      let hy = c.fy / hl
      let df = hx * c.fx + hy * c.fy
      if df > 0.01 {
        let y = projection.principal.y - projection.k * c.f * (hx * c.ux + hy * c.uy) / df
        let up = size.height * 0.1
        let down = size.height * 0.16
        if y + down >= 0, y - up <= size.height {
          ctx.saveGState()
          ctx.setBlendMode(.plusLighter)
          // the band's rows on the screen, whole device pixels
          let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.d))
          let top = (max(-2, y - up) * scale).rounded(.down) / scale
          let foot = (min(size.height + 2, y + down) * scale).rounded(.up) / scale
          rowGradient(
            CGRect(x: -2, y: top, width: size.width + 4, height: foot - top), from: y - up, to: y + down,
            [(0, g.glow, 0), (up / (up + down), g.glow, 0.4), (1, g.glow, 0)])
          ctx.restoreGState()
        }
      }
    }
    let grid = gridCache.of(g.gridEvery)
    ctx.saveGState()
    ctx.setLineCap(.butt)
    strokeGrid(grid.minor, g.grid, alpha: 0.55 * g.gridAlpha, width: 0.8, minor: true)
    strokeGrid(grid.major, g.grid, alpha: g.gridAlpha, width: 1.1, minor: false)
    ctx.restoreGState()
  }

  /// The grid floor's own near-black under the horizon, and a sheen where it meets the
  /// haze (a glossy floor catches the far light), 22% of the screen's height deep.
  private func glossy(_ floor: Int, _ sheen: Int) {
    let c = projection.c
    let size = projection.size
    let hl = hypot(c.fx, c.fy)
    var y = -2.0
    if hl >= 0.05 {
      let hx = c.fx / hl, hy = c.fy / hl
      let df = hx * c.fx + hy * c.fy
      if df > 0.01 { y = projection.principal.y - projection.k * c.f * (hx * c.ux + hy * c.uy) / df }
    }
    guard y <= size.height else { return }
    let top = max(-2, y)
    ctx.setFillColor(color(floor))
    ctx.fill(CGRect(x: -2, y: top, width: size.width + 4, height: size.height - top + 2))
    let deep = size.height * 0.22
    guard y + deep > 0 else { return }
    let box = CGRect(x: -2, y: top, width: size.width + 4, height: min(size.height + 2, y + deep) - top)
    if box.height > 0 { rowGradient(box, from: y, to: y + deep, [(0, sheen, 1), (1, floor, 1)]) }
  }

  private func strokeGrid(_ segs: [Segment], _ rgb: Int, alpha: Double, width: Double, minor: Bool) {
    let c = projection.c
    let near = 0.15
    var buckets = fade.map { _ in CGMutablePath() }
    for s in segs {
      var a = V3(s.x0, s.y0, 0)
      var b = V3(s.x1, s.y1, 0)
      var d0 = dot(a - c.eye, c.forward)
      var d1 = dot(b - c.eye, c.forward)
      if d0 < near && d1 < near { continue }
      if d0 < near || d1 < near {
        let m = a + (b - a) * ((near - d0) / (d1 - d0))
        if d0 < near {
          a = m
          d0 = near
        } else {
          b = m
          d1 = near
        }
      }
      let mean = (d0 + d1) / 2
      var k = fade.firstIndex { mean < $0.to } ?? fade.count - 1
      if minor {
        let r = hypot((a.x + b.x) / 2, (a.y + b.y) / 2 - 4)
        if r > 16 { continue }
        if r > 9 { k = min(fade.count - 1, k + Int(((r - 9) / 7 * 2).rounded(.up))) }
      }
      buckets[k].move(to: projection.screen(projection.view(a)))
      buckets[k].addLine(to: projection.screen(projection.view(b)))
    }
    for (k, p) in buckets.enumerated() where !p.isEmpty {
      stroke(p, rgb, width, alpha: fade[k].alpha * alpha)
    }
  }

  // ---------- the pieces' light ----------

  private func halos(_ shown: [Projected], neon: Bool) {
    let c = projection.c
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    for s in shown {
      let it = s.solid.piece
      let h: (foot: Double, body: Double, a: Double, b: Double)
      let rgb: Int
      var dim = 1.0
      switch it.kind {
      case "kubb":
        h = neon ? (0.24, 0.16, 0.5, 0.22) : (0.26, 0.17, 0.5, 0.24)
      case "king":
        h = neon ? (0.36, 0.26, 0.6, 0.3) : (0.38, 0.28, 0.6, 0.3)
      case "stake":
        h = neon ? (0.14, 0.1, 0.45, 0.25) : (0.18, 0.12, 0.55, 0.3)
      default: continue
      }
      if neon {
        rgb = Neon.litOf(it).ink
        if it.kind != "stake" && Neon.lying(it) { dim = 0.35 }
      } else {
        rgb = it.kind == "stake" ? Night.halo.stake : (it.kind == "king" ? Night.halo.king : Night.halo.kubb)
      }
      let foot = projection.view(V3(it.x, it.y, 0))
      guard foot.z >= 0.1 else { continue }
      let p = projection.screen(foot)
      let delta = V3(it.x, it.y, 0) - c.eye
      let squash = max(0.18, min(1, c.pz / simd_length(delta)))
      let r = h.foot * unit(foot.z)
      Glow.draw(ctx, p.x, p.y, r, r * squash, rgb, h.a * dim)
      let body = projection.view(it.center)
      if body.z > 0.1 {
        let q = projection.screen(body)
        let rb = h.body * unit(body.z)
        Glow.draw(ctx, q.x, q.y, rb, rb, rgb, h.b * dim)
      }
    }
    ctx.restoreGState()
  }

  /// A baton's two ends on the screen, their radii and how much each end faces the
  /// eye, and the screen axes along and across it.
  private func batonShape(_ s: Solid) -> (
    p1: CGPoint, p2: CGPoint, r1: Double, r2: Double, c1: Double, c2: Double, across: CGPoint,
    angle: Double, depth: Double
  )? {
    let it = s.piece
    let a = s.axes[2]
    let e1 = it.center - a * 0.15
    let e2 = it.center + a * 0.15
    let v1 = projection.view(e1)
    let v2 = projection.view(e2)
    guard v1.z >= 0.15, v2.z >= 0.15 else { return nil }
    let p1 = projection.screen(v1)
    let p2 = projection.screen(v2)
    var ux = p2.x - p1.x
    var uy = p2.y - p1.y
    let ul = max(hypot(ux, uy), 1e-9)
    ux /= ul
    uy /= ul
    func faces(_ e: V3, _ sign: Double) -> Double {
      let v = projection.c.eye - e
      return sign * dot(a, v) / simd_length(v)
    }
    return (
      p1, p2, 0.022 * unit(v1.z), 0.022 * unit(v2.z), faces(e1, -1), faces(e2, 1), CGPoint(x: -uy, y: ux),
      atan2(ux, -uy), (v1.z + v2.z) / 2
    )
  }

  private func batonOutline(
    _ b: (p1: CGPoint, p2: CGPoint, r1: Double, r2: Double, c1: Double, c2: Double, across: CGPoint, angle: Double, depth: Double),
    caps: Bool = true
  ) -> CGMutablePath {
    let n = b.across
    let shape = CGMutablePath()
    shape.addLines(between: [
      CGPoint(x: b.p1.x - n.x * b.r1, y: b.p1.y - n.y * b.r1),
      CGPoint(x: b.p2.x - n.x * b.r2, y: b.p2.y - n.y * b.r2),
      CGPoint(x: b.p2.x + n.x * b.r2, y: b.p2.y + n.y * b.r2),
      CGPoint(x: b.p1.x + n.x * b.r1, y: b.p1.y + n.y * b.r1),
    ])
    shape.closeSubpath()
    if caps {
      for (p, r, c) in [(b.p1, b.r1, b.c1), (b.p2, b.r2, b.c2)] { shape.addPath(cap(p, r, c, b.angle)) }
    }
    return shape
  }

  private func cap(_ p: CGPoint, _ r: Double, _ c: Double, _ angle: Double) -> CGPath {
    let ry = max(0.01, r * abs(c))
    return CGPath(
      ellipseIn: CGRect(x: -r, y: -ry, width: 2 * r, height: 2 * ry),
      transform: [CGAffineTransform(translationX: p.x, y: p.y).rotated(by: angle)])
  }

  /// Plain wood by moonlight (no bands, as every baton): the side away from the
  /// moon in shade, a cold rim of moonlight on the lit side, the end that faces the
  /// eye showing its rings.
  private func moonlitBaton(_ s: Solid) {
    guard let b = batonShape(s) else { return }
    let tall = projection.c.f * 0.3 / b.depth * projection.k
    let ow = min(3.4, max(1, tall / 20))
    let outline = batonOutline(b)
    stroke(outline, 0x060a13, ow * 2)
    ctx.addPath(outline)
    ctx.setFillColor(color(0xd6c7a4))
    ctx.fillPath(using: .winding)
    // which screen side faces away from the moon
    let it = s.piece
    let a = s.axes[2]
    let L = PiecePaint.night.light
    let nl = L - a * dot(L, a)
    var side = -1.0
    if let q = projection.project(it.center - nl * 0.022), let m = projection.project(it.center),
      (q.x - m.x) * b.across.x + (q.y - m.y) * b.across.y > 0
    {
      side = 1
    }
    let n = b.across
    func off(_ p: CGPoint, _ r: Double, _ f: Double) -> CGPoint {
      CGPoint(x: p.x + n.x * side * r * f, y: p.y + n.y * side * r * f)
    }
    fill(path([off(b.p1, b.r1, 0.1), off(b.p2, b.r2, 0.1), off(b.p2, b.r2, 1), off(b.p1, b.r1, 1)]), 0x0a0e1e, alpha: 0.36)
    stroke(
      path([off(b.p1, b.r1, -0.62), off(b.p2, b.r2, -0.62)], closed: false), 0xf4f2e8,
      max(ow * 0.5, b.r1 * 0.14), alpha: 0.55)
    let (p, r, c) = b.c2 > b.c1 ? (b.p2, b.r2, b.c2) : (b.p1, b.r1, b.c1)
    if c > 0.02 {
      let end = cap(p, r, c, b.angle)
      fill(end, 0xc3b08b)
      stroke(end, 0x060a13, ow * 0.7)
      if r > 6 {
        let rings = CGMutablePath()
        for f in [0.35, 0.68] { rings.addPath(cap(p, r * f, c, b.angle)) }
        stroke(rings, 0x9a8868, ow * 0.45)
      }
    }
  }

  /// A dark body, its outline in white light and a faint core of light along it.
  func neonBaton(_ s: Solid) {
    guard let b = batonShape(s) else { return }
    let tall = projection.c.f * 0.3 / b.depth * projection.k
    let ow = min(2.6, max(0.9, tall / 26))
    let outline = batonOutline(b)
    stroke(outline, 0xf2fdff, ow * 2)
    ctx.addPath(outline)
    ctx.setFillColor(color(0x070b12))
    ctx.fillPath(using: .winding)
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    stroke(path([b.p1, b.p2], closed: false), 0x8fefff, max(ow * 0.6, (b.r1 + b.r2) * 0.22), alpha: 0.6)
    ctx.restoreGState()
  }
}
