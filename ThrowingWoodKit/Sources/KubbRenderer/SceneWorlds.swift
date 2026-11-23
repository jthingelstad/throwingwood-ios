import CoreGraphics
import Foundation
import simd

// The daylight scenes (Beach, Minnesota, Tournament) and Black & White, in the game's flat
// cartoon style: the day's pitch and pieces under each scene's own ground, sky and
// scenery. The scenery stands off the pitch (outside |x| 3.5 or past y 10.5), so it never
// hides a piece or the ground a throw lands on, and is drawn before the pieces.

/// The daylight scenes' colours and scenery.
enum Daylit {
  static let looks: Set<String> = ["beach", "minnesota", "tournament"]

  /// The ground in each: Beach's raked sand pitch by pale dry sand, its lines a navy rope
  /// (white on sand is 1.4:1); Minnesota's packed snow by drifts, blue lines; the
  /// Tournament's mown grass, the day's lines.
  static func ground(_ look: String, _ s: Surface) -> GroundColors {
    switch (look, s) {
    case ("beach", _), (_, .sand):
      GroundColors(
        pitch: 0xe6c88c, stripe: 0xedd39c, rough: 0xf4e3b9, speck: 0xcfae72, sky: 0x9fd8f0, haze: 0xdff1f6,
        line: 0x24507a)
    case ("minnesota", _), (_, .snow):
      GroundColors(
        pitch: 0xf2f6fb, stripe: 0xfbfdff, rough: 0xdce6f1, speck: 0xb4c5da, sky: 0xc9d7e6, haze: 0xe8eff6,
        line: 0x2f6db5)
    default:
      // a shade deeper than the park's, so its white lines hold 3:1 on the stripes too
      GroundColors(
        pitch: 0x579a35, stripe: 0x5fa43c, rough: 0x4c8c30, speck: 0x3a7124, sky: 0xa9d6f2, haze: 0xcfe6d4,
        line: 0xffffff)
    }
  }

  /// The sky's gradient, top to the horizon.
  static func sky(_ look: String) -> [(t: Double, rgb: Int, a: Double)] {
    switch look {
    case "beach": [(0, 0x4fb3e3, 1), (0.7, 0x8fd3ef, 1), (1, 0xd6f0f7, 1)]
    case "minnesota": [(0, 0x9fb3cc, 1), (0.6, 0xc4d2e2, 1), (1, 0xe9eff5, 1)]
    default: [(0, 0x5aa9e0, 1), (0.7, 0x9dcdef, 1), (1, 0xd8ecf2, 1)]
    }
  }

  /// The sea off the beach: from this far down the pitch (m), past the far baseline.
  static let sea = 14.5
  static let seaColors = (deep: 0x2f8fc4, near: 0x4fb0d8, foam: 0xffffff, wet: 0xd4b77c)
}

/// A neighbouring pitch at a tournament: where it is (its own frame's origin in this
/// pitch's frame) and its pieces in its own frame, as data. Fixed (`Tournament.neighbours`)
/// under Reduce Motion and until the live field answers; live from engine 0.15.1
/// (`TournamentNeighbours`, Neighbours.swift), when only the data changes
/// (`Painter.neighbours`).
struct NeighbourPitch {
  let dx, dy: Double
  /// The pieces in the neighbour's own frame (x across, y along, as this pitch's).
  let pieces: [Piece]
  /// Its scoreboard: base kubbs standing a side. No people, live or fixed (the owner,
  /// 2026-11-22: "Tournament mode should not have people. Just pitches with live play.").
  let score: (a: Int, b: Int)
}

enum Tournament {
  private static func kubb(_ id: String, _ team: String, _ x: Double, _ y: Double, down: Bool = false) -> Piece {
    down
      ? Piece(id: id, kind: "kubb", team: team, x: x, y: y, z: 0.035, qw: 0.7071, qx: 0.7071, qy: 0, qz: 0)
      : Piece(id: id, kind: "kubb", team: team, x: x, y: y, z: 0.075, qw: 1, qx: 0, qy: 0, qz: 0)
  }
  private static func king(_ x: Double, _ y: Double) -> Piece {
    Piece(id: "king", kind: "king", team: nil, x: x, y: y, z: 0.15, qw: 1, qx: 0, qy: 0, qz: 0)
  }
  private static func stakes() -> [Piece] {
    [0.0, 4, 8].flatMap { y in [-2.5, 2.5].map { x in
      Piece(id: "stake", kind: "stake", team: nil, x: x, y: y, z: 0.075, qw: 1, qx: 0, qy: 0, qz: 0)
    } }
  }
  /// Two pitches either side, in mid-match: some base kubbs down, field kubbs standing.
  static let neighbours: [NeighbourPitch] = [
    NeighbourPitch(
      dx: -8, dy: 0,
      pieces: stakes() + [
        kubb("a1", "A", -2, 0), kubb("a2", "A", -1, 0), kubb("a3", "A", 0, 0, down: true), kubb("a4", "A", 1, 0),
        kubb("a5", "A", 2, 0), kubb("b1", "B", -2, 8, down: true), kubb("b2", "B", -1, 8), kubb("b3", "B", 0, 8),
        kubb("b4", "B", 1, 8, down: true), kubb("b5", "B", 2, 8), kubb("f1", "B", -0.6, 5.3), kubb("f2", "B", 0.4, 5.6),
        king(0, 4),
      ], score: (5, 3)),
    NeighbourPitch(
      dx: 8, dy: 0,
      pieces: stakes() + [
        kubb("a1", "A", -2, 0, down: true), kubb("a2", "A", -1, 0), kubb("a3", "A", 0, 0), kubb("a4", "A", 1, 0, down: true),
        kubb("a5", "A", 2, 0, down: true), kubb("b1", "B", -2, 8), kubb("b2", "B", -1, 8), kubb("b3", "B", 0, 8),
        kubb("b4", "B", 1, 8), kubb("b5", "B", 2, 8), kubb("f1", "A", 1.1, 2.4), king(0, 4),
      ], score: (2, 5)),
    NeighbourPitch(
      dx: -16, dy: 0,
      pieces: stakes() + [
        kubb("a1", "A", -2, 0), kubb("a2", "A", -1, 0), kubb("a3", "A", 0, 0), kubb("a4", "A", 1, 0), kubb("a5", "A", 2, 0),
        kubb("b2", "B", -1, 8), kubb("b5", "B", 2, 8), king(0, 4),
      ], score: (5, 2)),
    NeighbourPitch(
      dx: 16, dy: 0,
      pieces: stakes() + [
        kubb("a1", "A", -2, 0), kubb("a3", "A", 0, 0), kubb("b1", "B", -2, 8), kubb("b2", "B", -1, 8),
        kubb("b3", "B", 0, 8), kubb("b4", "B", 1, 8), king(0, 4),
      ], score: (2, 4)),
  ]
  /// The bunting's flags, in turn.
  static let flags = [0xd8343c, 0xffffff, 0x2a5fb0, 0xf2b705]
}

/// Black & White: the Playdate's 1-bit look (playdate-kubb's render/world.lua).
enum Mono {
  /// Pure black or pure white by lightness.
  static func of(_ rgb: Int) -> Int {
    let r = Double(rgb >> 16 & 255), g = Double(rgb >> 8 & 255), b = Double(rgb & 255)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 >= 0.5 ? 0xffffff : 0x000000
  }
  /// Each surface's rough, 8 rows of 8 bits (1 white, 0 black): grass short dashes, sand
  /// a denser stipple, snow a sparse sprinkle on white (the Playdate's roughBySurface).
  static let rough: [Surface: [UInt8]] = [
    .grass: [0xFF, 0x9F, 0xFF, 0xFF, 0xFF, 0xF9, 0xFF, 0xFF],
    .sand: [0xFF, 0xDF, 0xFF, 0xFB, 0xFF, 0x7F, 0xFF, 0xF7],
    .snow: [0xFF, 0xFF, 0xFF, 0xEF, 0xFF, 0xFF, 0xFF, 0xFF],
    .grid: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
  ]
  nonisolated(unsafe) private static var images: [[UInt8]: CGImage] = [:]
  private static let lock = NSLock()
  /// The pattern as an 8 x 8 image, white where a bit is set and clear where it is not
  /// (`opaque`: black there).
  static func image(_ bits: [UInt8], opaque: Bool = true) -> CGImage? {
    let key = bits + [opaque ? 1 : 0]
    lock.lock()
    defer { lock.unlock() }
    if let i = images[key] { return i }
    var px = [UInt8](repeating: 0, count: 64 * 4)
    for y in 0..<8 {
      for x in 0..<8 {
        let white = bits[y] >> (7 - x) & 1 == 1
        let i = (y * 8 + x) * 4
        if white {
          px[i] = 255; px[i + 1] = 255; px[i + 2] = 255; px[i + 3] = opaque ? 255 : 0
        } else {
          px[i + 3] = 255
        }
      }
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: &px, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let image = ctx.makeImage()
    else { return nil }
    images[key] = image
    return image
  }
}

extension Painter {
  // ---------- scenery helpers ----------

  /// m: scenery nearer the eye than this is not drawn.
  static let sceneryNear = 2.6

  /// Draws `body` standing on the ground at `p`, facing the eye, in metres with y up
  /// (one unit a metre at that depth), turned with the camera's roll. `u` is points per
  /// metre there, for line widths.
  func billboard(_ p: V3, _ body: (_ u: Double) -> Void) {
    let v = projection.view(p)
    // scenery the camera has come right up to (the impact camera's close shots) is left
    // out rather than filling the screen
    guard v.z > Self.sceneryNear else { return }
    let up = projection.view(p + V3(0, 0, 1))
    guard up.z > 0.05 else { return }
    let base = projection.screen(v)
    let top = projection.screen(up)
    let u = unit(v.z)
    guard u > 0.8 else { return }
    ctx.saveGState()
    ctx.translateBy(x: base.x, y: base.y)
    ctx.rotate(by: atan2(top.x - base.x, base.y - top.y))
    ctx.scaleBy(x: u, y: -u)
    body(u)
    ctx.restoreGState()
  }

  /// A shape in billboard metres, filled and outlined in ink `w` points wide.
  func cutout(_ points: [CGPoint], _ rgb: Int, _ u: Double, w: Double = 1.6) {
    let shape = path(points)
    fill(shape, rgb)
    stroke(shape, ink, w / u)
  }

  /// Scenery drawn far to near (each item's ground point and its drawing).
  func scenery(_ items: [(at: V3, draw: () -> Void)]) {
    let eye = projection.c.eye
    let f = projection.c.forward
    for item in items.sorted(by: { dot($0.at - eye, f) > dot($1.at - eye, f) }) { item.draw() }
  }

  /// The sky's gradient from the top of the screen to the horizon's lower end.
  func skyGradient(_ left: CGPoint, _ right: CGPoint, _ stops: [(t: Double, rgb: Int, a: Double)]) {
    let low = max(left.y, right.y)
    guard low > 0 else { return }
    let box = CGRect(x: -2, y: -2, width: projection.size.width + 4, height: min(projection.size.height, low) + 2)
    rowGradient(box, from: min(0, low - projection.size.height), to: low, stops)
  }

  /// A flat cartoon cloud: three overlapping lobes, white with a pale underside, in the sky
  /// at direction `d` (a point at infinity), `r` its size in points per unit of `f`.
  func cloud(_ d: V3, _ r: Double, _ under: Int) {
    guard let p = direction(d) else { return }
    let s = r * projection.k
    let lobes = CGMutablePath()
    for (ox, oy, rr) in [(-1.1, 0.15, 0.7), (0, -0.25, 1.0), (1.05, 0.1, 0.75), (0.45, 0.3, 0.6), (-0.5, 0.3, 0.6)] {
      lobes.addEllipse(in: CGRect(x: p.x + (ox - rr) * s, y: p.y + (oy - rr) * s, width: 2 * rr * s, height: 2 * rr * s))
    }
    ctx.saveGState()
    ctx.addPath(lobes)
    ctx.clip()
    ctx.setFillColor(color(0xffffff))
    ctx.fill(CGRect(x: p.x - 2.2 * s, y: p.y - 1.4 * s, width: 4.4 * s, height: 2.8 * s))
    ctx.setFillColor(color(under))
    ctx.fill(CGRect(x: p.x - 2.2 * s, y: p.y + 0.35 * s, width: 4.4 * s, height: 1.4 * s))
    ctx.restoreGState()
  }

  // ---------- the daylight scenes ----------

  func daylit(
    _ scene: PitchScene, look: String, effects: SceneEffects?, time: Double, still: Bool, live: LiveNeighbours? = nil
  ) {
    let g = Daylit.ground(look, scene.surface)
    ground(
      scene, colors: g,
      sky: { l, r in
        skyGradient(l, r, Daylit.sky(look))
        switch look {
        case "beach":
          cloud(V3(-0.5, 1, 0.12), 26, 0xd6ecf5)
          cloud(V3(0.35, 1, 0.2), 20, 0xd6ecf5)
          cloud(V3(0.95, 0.6, 0.1), 18, 0xd6ecf5)
        case "tournament":
          cloud(V3(-0.3, 1, 0.16), 22, 0xdbe9f2)
          cloud(V3(0.6, 1, 0.1), 18, 0xdbe9f2)
        default:
          // Minnesota's winter sky: one low bank of cloud
          cloud(V3(-0.6, 1, 0.08), 30, 0xd5dfea)
          cloud(V3(0.15, 1, 0.1), 34, 0xd5dfea)
          cloud(V3(0.8, 0.9, 0.07), 28, 0xd5dfea)
        }
      },
      beyond: {
        if look == "beach" { sea(time: time) }
        if look == "tournament" { mown() }
      }, specksUpTo: look == "beach" ? Daylit.sea - 1.2 : nil)
    switch look {
    case "beach": beachScenery()
    case "minnesota": winterScenery()
    default:
      neighbours(live?.pitches ?? Tournament.neighbours, live: live != nil)
      tournamentScenery(scene, live: live?.pitches)
    }
    marks(scene)
    kidCones(scene)
    pieces(scene)
    effects?.draw(ctx, projection)
    if look == "minnesota" && !still { snowfall(time: time) }
    if let arc = scene.arc { trajectory(arc, ground: false) }
  }

  // ---------- the beach ----------

  /// The sea past the far baseline: a strip of wet sand, the foam's edge and the water in
  /// two blues with lines of swell, to the horizon. `time` rolls the foam a little.
  private func sea(time: Double) {
    let y0 = Daylit.sea
    let c = Daylit.seaColors
    fill(quad(-400, y0 - 1.2, 400, y0 + 0.2), c.wet)
    fill(quad(-400, y0, 400, 400), c.near)
    fill(quad(-400, y0 + 9, 400, 400), c.deep)
    // the foam's scalloped edge
    let foam = CGMutablePath()
    let roll = sin(time * 0.6) * 0.12
    var x = -40.0
    while x < 40 {
      let pts = (0...6).map { i -> V3 in
        let u = Double(i) / 6
        return V3(x + u * 1.6, y0 - 0.05 + roll - sin(u * .pi) * 0.35, 0)
      }
      let back = [V3(x + 1.6, y0 + 0.3 + roll, 0), V3(x, y0 + 0.3 + roll, 0)]
      let p = projection.polygon(pts + back)
      if p.count >= 3 { foam.addPath(path(p)) }
      x += 1.6
    }
    fill(foam, c.foam)
    // the swell: short pale dashes across the water, sparser toward the horizon
    var n: UInt32 = 0
    for row in 0..<14 {
      let y = y0 + 1.6 + pow(Double(row), 1.45) * 1.2
      var x = -30.0 + woodHash(UInt32(row) * 7) * 3
      while x < 30 {
        n += 1
        let len = 0.8 + woodHash(n * 11) * 1.4
        stroke(line(V3(x, y, 0), V3(x + len, y, 0)), 0xd9f2fb, max(1, 1.6 * projection.k * 6 / y), alpha: 0.85)
        x += len + 1.5 + woodHash(n * 17) * 3
      }
    }
  }

  private func beachScenery() {
    var items: [(at: V3, draw: () -> Void)] = []
    // towels on the sand, flat
    for (x, y, a, rgb) in [(-5.2, 3.2, 0.3, 0xd8343c), (5.6, 6.5, -0.2, 0x2a8fd0), (-6.4, 9.8, 0.1, 0xf2b705)] {
      let ca = cos(a), sa = sin(a)
      func at(_ u: Double, _ v: Double) -> V3 { V3(x + u * ca - v * sa, y + u * sa + v * ca, 0) }
      let towel = poly([at(-0.45, -0.9), at(0.45, -0.9), at(0.45, 0.9), at(-0.45, 0.9)])
      fill(towel, rgb)
      for v in stride(from: -0.6, through: 0.6, by: 0.4) {
        fill(poly([at(-0.45, v - 0.06), at(0.45, v - 0.06), at(0.45, v + 0.06), at(-0.45, v + 0.06)]), 0xffffff)
      }
      stroke(towel, ink, 1.4)
    }
    // umbrellas
    for (x, y, a, b) in [(-5.6, 4.6, 0xd8343c, 0xffffff), (6.2, 8.2, 0x2a8fd0, 0xffffff), (-7.0, 11.4, 0xf2b705, 0xd8343c), (7.4, 1.0, 0x22a37a, 0xffffff)] {
      let p = V3(x, y, 0)
      items.append((p, { umbrella(p, a, b) }))
    }
    // a beach ball at rest
    let ball = V3(4.6, 3.6, 0)
    items.append((ball, {
      billboard(ball) { u in
        let r = 0.2
        let disc = CGPath(ellipseIn: CGRect(x: -r, y: 0, width: 2 * r, height: 2 * r), transform: nil)
        fill(disc, 0xffffff)
        for (i, rgb) in [0xd8343c, 0x2a8fd0, 0xf2b705].enumerated() {
          let a0 = Double(i) * 2 * .pi / 3
          let wedge = CGMutablePath()
          wedge.move(to: CGPoint(x: 0, y: r))
          wedge.addArc(center: CGPoint(x: 0, y: r), radius: r, startAngle: a0, endAngle: a0 + .pi / 3, clockwise: false)
          wedge.closeSubpath()
          fill(wedge, rgb)
        }
        stroke(disc, ink, 1.4 / u)
      }
    }))
    scenery(items)
  }

  private func umbrella(_ p: V3, _ a: Int, _ b: Int) {
    // its shadow on the sand, then the pole and canopy
    fill(ring(p + V3(0.25, -0.1, 0), 0.9), 0xcfae72, alpha: 0.55)
    billboard(p) { u in
      cutout([CGPoint(x: -0.03, y: 0), CGPoint(x: 0.03, y: 0), CGPoint(x: 0.03, y: 2.05), CGPoint(x: -0.03, y: 2.05)], 0xf6f1e4, u)
      let n = 6
      for i in 0..<n {
        let x0 = -1.0 + 2 * Double(i) / Double(n), x1 = -1.0 + 2 * Double(i + 1) / Double(n)
        func top(_ x: Double) -> Double { 1.62 + 0.5 * (1 - x * x).squareRoot() }
        var pts = [CGPoint(x: x0, y: 1.62)]
        for k in 0...6 {
          let x = x0 + (x1 - x0) * Double(k) / 6
          pts.append(CGPoint(x: x, y: top(x)))
        }
        pts.append(CGPoint(x: x1, y: 1.62))
        pts.append(CGPoint(x: (x0 + x1) / 2, y: 1.7))
        fill(path(pts), i % 2 == 0 ? a : b)
      }
      var rim = [CGPoint]()
      for k in 0...24 {
        let x = -1.0 + 2 * Double(k) / 24
        rim.append(CGPoint(x: x, y: 1.62 + 0.5 * (1 - x * x).squareRoot()))
      }
      for i in stride(from: n, through: 0, by: -1) {
        let x = -1.0 + 2 * Double(i) / Double(n)
        rim.append(CGPoint(x: x, y: 1.62))
        if i > 0 { rim.append(CGPoint(x: x - 1.0 / Double(n), y: 1.7)) }
      }
      stroke(path(rim), ink, 1.6 / u)
    }
  }

  // ---------- Minnesota ----------

  private func winterScenery() {
    var items: [(at: V3, draw: () -> Void)] = []
    // a ring of pines round the clearing, and bare birches between them
    var n: UInt32 = 5
    func jitter() -> Double {
      n += 1
      return woodHash(n * 13) - 0.5
    }
    var spots: [(V3, Double, Bool)] = []
    for x in stride(from: -16.0, through: 16, by: 2.4) where abs(x) > 3 || true {
      spots.append((V3(x + jitter() * 1.2, 15.5 + jitter() * 2.5, 0), 4.2 + jitter() * 1.6, jitter() > 0.32))
    }
    for y in stride(from: -2.0, through: 12, by: 2.6) {
      for side in [-1.0, 1.0] {
        spots.append((V3(side * (7.2 + jitter() * 1.6), y + jitter(), 0), 3.6 + jitter() * 1.4, jitter() > 0.25))
      }
    }
    for (p, h, birch) in spots {
      items.append((p, { birch ? self.birch(p, h * 0.9) : self.pine(p, h) }))
    }
    // drifts: soft white mounds on the ground by the trees, with a blue shade on their
    // side away from the light
    for (x, y, r) in [(-4.6, 9.8, 0.9), (4.9, 11.4, 1.2), (-5.6, 1.6, 0.8), (5.4, 4.4, 0.7)] {
      fill(ring(V3(x + r * 0.15, y - r * 0.08, 0), r), 0xbccbe0)
      fill(ring(V3(x, y, 0), r * 0.92), 0xffffff)
    }
    scenery(items)
  }

  private func pine(_ p: V3, _ h: Double) {
    fill(ring(p + V3(h * 0.12, -h * 0.06, 0), h * 0.22), 0xb9c8dc, alpha: 0.7)
    billboard(p) { u in
      let w = h * 0.36
      cutout([CGPoint(x: -0.09, y: 0), CGPoint(x: 0.09, y: 0), CGPoint(x: 0.09, y: h * 0.2), CGPoint(x: -0.09, y: h * 0.2)], 0x6b4a2e, u)
      for (i, (b, t, half)) in [(0.16, 0.56, 1.0), (0.4, 0.8, 0.78), (0.62, 1.0, 0.55)].enumerated() {
        let bw = w * half
        let tier = [CGPoint(x: -bw, y: h * b), CGPoint(x: bw, y: h * b), CGPoint(x: 0, y: h * t)]
        fill(path(tier), 0x2f6247)
        // the shaded side away from the light, which comes from the left
        fill(path([CGPoint(x: 0, y: h * b), CGPoint(x: bw, y: h * b), CGPoint(x: 0, y: h * t)]), 0x234c37)
        // snow on the tier
        let sh = (t - b) * h
        let cap = [
          CGPoint(x: 0, y: h * t), CGPoint(x: -bw * 0.42, y: h * t - sh * 0.42), CGPoint(x: -bw * 0.22, y: h * t - sh * 0.36),
          CGPoint(x: -bw * 0.08, y: h * t - sh * 0.46), CGPoint(x: bw * 0.12, y: h * t - sh * 0.34),
          CGPoint(x: bw * 0.36, y: h * t - sh * 0.42),
        ]
        fill(path(cap), 0xffffff)
        if i == 0 {
          // a lip of snow along the lowest tier's edge
          fill(path([CGPoint(x: -bw, y: h * b), CGPoint(x: bw, y: h * b), CGPoint(x: bw * 0.9, y: h * b + 0.08), CGPoint(x: -bw * 0.9, y: h * b + 0.08)]), 0xffffff)
        }
        stroke(path(tier), ink, 1.5 / u)
      }
    }
  }

  private func birch(_ p: V3, _ h: Double) {
    billboard(p) { u in
      let trunk = [CGPoint(x: -0.07, y: 0), CGPoint(x: 0.07, y: 0), CGPoint(x: 0.04, y: h), CGPoint(x: -0.04, y: h)]
      cutout(trunk, 0xf3f1ea, u)
      for k in 1..<6 {
        let y = h * Double(k) / 6.5
        fill(path([CGPoint(x: -0.06, y: y), CGPoint(x: 0.02, y: y), CGPoint(x: 0.0, y: y + 0.06), CGPoint(x: -0.06, y: y + 0.05)]), ink)
      }
      let branches = CGMutablePath()
      for (y, dx, dy) in [(0.55, -0.7, 0.45), (0.62, 0.6, 0.5), (0.74, -0.45, 0.4), (0.82, 0.4, 0.35), (0.45, 0.5, 0.3)] {
        branches.move(to: CGPoint(x: 0, y: h * y))
        branches.addLine(to: CGPoint(x: dx, y: h * y + dy))
        branches.move(to: CGPoint(x: dx * 0.6, y: h * y + dy * 0.6))
        branches.addLine(to: CGPoint(x: dx * 0.6 + dx * 0.35, y: h * y + dy * 1.15))
      }
      stroke(branches, 0x3b3128, 1.6 / u)
    }
  }

  /// Snow falling: small flakes drifting down the screen, the same flakes every frame for
  /// a time (no randomness per frame), light enough never to hide a piece.
  private func snowfall(time: Double) {
    let size = projection.size
    let flakes = 70
    let unitPt = max(1.0, projection.k)
    for i in 0..<flakes {
      let h0 = woodHash(UInt32(i * 31 + 7)), h1 = woodHash(UInt32(i * 17 + 3)), h2 = woodHash(UInt32(i * 13 + 11))
      let fall = 18 + h2 * 22
      let y = (h1 * (size.height + 40) + time * fall).truncatingRemainder(dividingBy: size.height + 40) - 20
      let x = h0 * size.width + sin(time * (0.6 + h2) + Double(i)) * 8
      let r = (1.1 + h2 * 1.5) * unitPt
      let flake = CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
      fill(flake, 0xffffff, alpha: 0.9)
      stroke(flake, 0x8ea4c4, 0.8, alpha: 0.7)
    }
  }

  // ---------- the tournament ----------

  /// The neighbouring pitches, each from its data, the farthest first: its lines, its
  /// stakes and its pieces in the day's light and the USA set's colouring at a far pitch's
  /// detail (no shadows on the live field), then its scoreboard behind its far end. A pitch
  /// wholly off the screen is left out.
  func neighbours(_ list: [NeighbourPitch], live: Bool = false) {
    let eye = projection.c.eye, f = projection.c.forward
    func depth(_ n: NeighbourPitch) -> Double { dot(V3(n.dx, n.dy + 4, 0) - eye, f) }
    let screen = CGRect(origin: .zero, size: projection.size).insetBy(dx: -24, dy: -24)
    for n in list.sorted(by: { depth($0) > depth($1) }) {

      // its footprint and the height of its board: nothing of it on the screen,
      // nothing drawn
      let box = path(projection.polygon([
        V3(n.dx - 3.5, n.dy - 2, 0), V3(n.dx + 3.5, n.dy - 2, 0), V3(n.dx + 3.5, n.dy + 10, 0),
        V3(n.dx - 3.5, n.dy + 10, 0), V3(n.dx - 3.5, n.dy + 10, 2), V3(n.dx + 3.5, n.dy - 2, 2),
      ]))
      guard !box.isEmpty, box.boundingBoxOfPath.intersects(screen) else { continue }
      let o = V3(n.dx, n.dy, 0)
      // its ground: a mown pitch and white lines
      fill(quad(n.dx - 2.5, n.dy, n.dx + 2.5, n.dy + 8), 0x579a35)
      for x in [-2.5, -0.5, 1.5] { fill(quad(n.dx + x, n.dy, n.dx + x + 1, n.dy + 8), 0x5fa43c) }
      for (a, b) in [((-2.5, 0.0), (-2.5, 8.0)), ((2.5, 0), (2.5, 8)), ((-2.5, 0), (2.5, 0)), ((-2.5, 8), (2.5, 8))] {
        stroke(line(o + V3(a.0, a.1, 0), o + V3(b.0, b.1, 0)), 0xffffff, max(1, 0.5 * projection.k))
      }
      var s = PitchScene(surface: .grass, set: "usa", items: n.pieces.map { p in
        var q = p
        q.x += n.dx
        q.y += n.dy
        return q
      })
      s.look = "tournament"
      pieces(s, shadows: !live)
      let board = o + V3(3.4, 9.6, 0)
      scoreboard(board, n.score)
    }
  }

  /// The tournament field's mowing: big squares in two greens round the pitches.
  private func mown() {
    let light = CGMutablePath()
    for i in -8..<8 {
      for j in -4..<8 where (i + j) % 2 == 0 {
        let x = Double(i) * 4, y = Double(j) * 4
        light.addPath(quad(x, y, x + 4, y + 4))
      }
    }
    fill(light, 0x56993a)
  }

  /// `live`: the live field's pitches stand ahead as well as beside (the grid), so the
  /// tents stand back beyond its far row.
  private func tournamentScenery(_ scene: PitchScene, live: [NeighbourPitch]? = nil) {
    var items: [(at: V3, draw: () -> Void)] = []
    // bunting on poles between the pitches, and across the far end
    for x in [-5.0, 5.0, -11.0, 11.0] {
      items.append((V3(x, 4, 0), { self.bunting([V3(x, -2, 0), V3(x, 2, 0), V3(x, 6, 0), V3(x, 10.2, 0)]) }))
    }
    // across the far end its posts stand clear of the pitch's width, never behind a target
    items.append((V3(0, 10.2, 0), { self.bunting([V3(-11, 10.2, 0), V3(-5, 10.2, 0), V3(5, 10.2, 0), V3(11, 10.2, 0)]) }))
    // the pitch's own scoreboard, the kubbs each side has standing (three a side in a Kid
    // match, five in any other), and the tent beyond the end
    func standing(_ team: String) -> Int {
      scene.items.filter { $0.kind == "kubb" && $0.team == team && !Neon.lying($0) }.count
    }
    let board = V3(-3.6, 12.6, 0)
    let score = (standing("A"), standing("B"))
    items.append((board, { self.scoreboard(board, score) }))
    let ahead = live?.contains { $0.dy > 0 } == true
    let tent = ahead ? V3(4.2, 23.5, 0) : V3(5.5, 15.5, 0)
    items.append((tent, { self.tent(tent) }))
    let tent2 = ahead ? V3(-12, 24.5, 0) : V3(-9, 16.5, 0)
    items.append((tent2, { self.tent(tent2, stripe: 0x2a5fb0) }))
    scenery(items)
  }

  /// A rope of triangular flags on posts, sagging between them.
  private func bunting(_ posts: [V3]) {
    let top = 1.25
    let a = posts[0], b = posts[posts.count - 1], poles = posts.count
    let w = max(1, 0.04 * unit(max(0.5, dot((a + b) / 2 - projection.c.eye, projection.c.forward))))
    func near(_ q: V3) -> Bool { dot(q - projection.c.eye, projection.c.forward) < Self.sceneryNear }
    for p in posts where !near(p) {
      stroke(line(p, p + V3(0, 0, top + 0.1)), ink, min(5, w * 1.2) + 2)
      stroke(line(p, p + V3(0, 0, top + 0.1)), 0xb98a52, min(5, w * 1.2))
    }
    var flag = 0
    for i in 0..<(poles - 1) {
      let p0 = posts[i] + V3(0, 0, top), p1 = posts[i + 1] + V3(0, 0, top)
      let span = simd_length(p1 - p0)
      let n = max(3, Int(span / 0.55))
      func rope(_ t: Double) -> V3 { p0 + (p1 - p0) * t - V3(0, 0, 0.35 * 4 * t * (1 - t)) }
      var pts: [V3] = []
      for k in 0...n * 2 { pts.append(rope(Double(k) / Double(n * 2))) }
      for k in 0..<n {
        let t0 = (Double(k) + 0.15) / Double(n), t1 = (Double(k) + 0.85) / Double(n)
        let q0 = rope(t0), q1 = rope(t1)
        let tip = (q0 + q1) / 2 - V3(0, 0, 0.32)
        if near(tip) {
          flag += 1
          continue
        }
        let shape = poly([q0, q1, tip])
        fill(shape, Tournament.flags[flag % Tournament.flags.count])
        stroke(shape, ink, 1)
        flag += 1
      }
      var run: [CGPoint] = []
      for q in pts {
        if near(q) {
          if run.count > 1 { stroke(path(run, closed: false), ink, 1) }
          run = []
        } else if let s = projection.project(q) {
          run.append(s)
        }
      }
      if run.count > 1 { stroke(path(run, closed: false), ink, 1) }
    }
  }

  /// A scoreboard on two posts: the base kubbs standing a side, in big digits.
  private func scoreboard(_ p: V3, _ score: (a: Int, b: Int)) {
    billboard(p) { u in
      for x in [-0.45, 0.45] {
        cutout([CGPoint(x: x - 0.04, y: 0), CGPoint(x: x + 0.04, y: 0), CGPoint(x: x + 0.04, y: 1), CGPoint(x: x - 0.04, y: 1)], 0x6b4a2e, u)
      }
      cutout([CGPoint(x: -0.7, y: 0.9), CGPoint(x: 0.7, y: 0.9), CGPoint(x: 0.7, y: 1.7), CGPoint(x: -0.7, y: 1.7)], 0x1f3d2b, u)
      for (x, n, rgb) in [(-0.34, score.a, 0xf2b705), (0.34, score.b, 0xffffff)] {
        digit(n, at: CGPoint(x: x, y: 1.3), height: 0.5, rgb)
      }
      fill(path([CGPoint(x: -0.03, y: 1.22), CGPoint(x: 0.03, y: 1.22), CGPoint(x: 0.03, y: 1.38), CGPoint(x: -0.03, y: 1.38)]), 0xffffff)
    }
  }

  /// A seven-segment digit centred at `c`, `height` tall (billboard metres, y up).
  private func digit(_ n: Int, at c: CGPoint, height: Double, _ rgb: Int) {
    let segs: [[Int]] = [
      [0, 1, 2, 4, 5, 6], [2, 5], [0, 2, 3, 4, 6], [0, 2, 3, 5, 6], [1, 2, 3, 5],
      [0, 1, 3, 5, 6], [0, 1, 3, 4, 5, 6], [0, 2, 5], [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 5, 6],
    ]
    let w = height * 0.5, t = height * 0.13, h = height / 2
    let rects: [CGRect] = [
      CGRect(x: c.x - w / 2, y: c.y + h - t, width: w, height: t),  // 0 top
      CGRect(x: c.x - w / 2, y: c.y, width: t, height: h),  // 1 upper left
      CGRect(x: c.x + w / 2 - t, y: c.y, width: t, height: h),  // 2 upper right
      CGRect(x: c.x - w / 2, y: c.y - t / 2, width: w, height: t),  // 3 middle
      CGRect(x: c.x - w / 2, y: c.y - h, width: t, height: h),  // 4 lower left
      CGRect(x: c.x + w / 2 - t, y: c.y - h, width: t, height: h),  // 5 lower right
      CGRect(x: c.x - w / 2, y: c.y - h, width: w, height: t),  // 6 bottom
    ]
    let shape = CGMutablePath()
    for i in segs[max(0, min(9, n))] { shape.addRect(rects[i]) }
    fill(shape, rgb)
  }

  /// A tournament tent: a white peaked canopy with a striped valance on four legs.
  private func tent(_ p: V3, stripe: Int = 0xd8343c) {
    billboard(p) { u in
      for x in [-1.35, 1.35] {
        cutout([CGPoint(x: x - 0.04, y: 0), CGPoint(x: x + 0.04, y: 0), CGPoint(x: x + 0.04, y: 2), CGPoint(x: x - 0.04, y: 2)], 0xd9d4c8, u)
      }
      cutout([CGPoint(x: -1.5, y: 2), CGPoint(x: 1.5, y: 2), CGPoint(x: 0, y: 2.8)], 0xffffff, u)
      for i in 0..<6 {
        let x0 = -1.5 + Double(i) * 0.5
        let scallop = [CGPoint(x: x0, y: 2), CGPoint(x: x0 + 0.5, y: 2), CGPoint(x: x0 + 0.5, y: 1.8), CGPoint(x: x0 + 0.25, y: 1.72), CGPoint(x: x0, y: 1.8)]
        fill(path(scallop), i % 2 == 0 ? stripe : 0xffffff)
      }
      stroke(path([CGPoint(x: -1.5, y: 2), CGPoint(x: 1.5, y: 2), CGPoint(x: 1.5, y: 1.8), CGPoint(x: -1.5, y: 1.8)]), ink, 1.4 / u)
    }
  }

  // ---------- Black & White ----------

  /// The Playdate's look (playdate-kubb render/world.lua): white sky and pitch, the rough's
  /// 8 x 8 pattern on the ground round it (grass dashes, sand stipple, snow sprinkle), black
  /// lines two Playdate pixels wide, and the day's pieces made 1-bit: white faces, black
  /// where they face away, solid black shadows and stakes, no team bands. No antialiasing,
  /// so every pixel is black or white.
  func blackAndWhite(_ scene: PitchScene) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setShouldAntialias(false)
    ctx.interpolationQuality = .none
    let bounds = CGRect(origin: .zero, size: projection.size)
    ctx.setFillColor(color(0xffffff))
    ctx.fill(bounds.insetBy(dx: -2, dy: -2))
    // the rough: everything below the far edge but the pitch's own footprint
    let c = projection.c
    let hl = hypot(c.fx, c.fy)
    let roughArea = CGMutablePath()
    if hl > 0.05 {
      let far = V3(c.px, c.py, 0) + V3(c.fx, c.fy, 0) * (200 / hl)
      let side = V3(c.fy, -c.fx, 0) * (2000 / hl)
      if let a = projection.project(far - side), let b = projection.project(far + side), abs(b.x - a.x) > 1 {
        let slope = (b.y - a.y) / (b.x - a.x)
        let left = CGPoint(x: -4, y: a.y + (-4 - a.x) * slope)
        let right = CGPoint(x: bounds.width + 4, y: a.y + (bounds.width + 4 - a.x) * slope)
        roughArea.addPath(path([left, right, CGPoint(x: right.x, y: bounds.height + 4), CGPoint(x: left.x, y: bounds.height + 4)]))
      } else {
        roughArea.addPath(quad(-400, -400, 400, 400))
      }
    } else {
      roughArea.addPath(quad(-400, -400, 400, 400))
    }
    let pd = projection.k  // points per Playdate pixel
    if let tile = Mono.image(Mono.rough[scene.surface] ?? Mono.rough[.grass]!) {
      ctx.saveGState()
      ctx.addPath(roughArea)
      ctx.clip()
      // the pattern's phase follows the far baseline's middle, as on the Playdate
      let anchor = projection.project(V3(0, 8, 0)) ?? .zero
      let s = 8 * pd
      let ox = anchor.x - (anchor.x / s).rounded(.down) * s - s
      let oy = anchor.y - (anchor.y / s).rounded(.down) * s - s
      ctx.draw(tile, in: CGRect(x: ox, y: oy, width: s, height: s), byTiling: true)
      ctx.restoreGState()
    }
    fill(quad(-2.5, -20, 2.5, 8), 0xffffff)
    // the lines: 2 Playdate pixels, the centre line 6 on 4 off, the advantage line 2 on 2 off
    let lw = max(1, 2 * pd)
    let lines = CGMutablePath()
    for (a, b) in [((-2.5, 0.0), (-2.5, 8.0)), ((2.5, 0), (2.5, 8)), ((-2.5, 0), (2.5, 0)), ((-2.5, 8), (2.5, 8))] {
      lines.addPath(line(V3(a.0, a.1, 0), V3(b.0, b.1, 0)))
    }
    func dashed(_ y: Double, _ on: Double, _ off: Double) {
      for x in stride(from: -2.5, to: 2.5, by: on + off) { lines.addPath(line(V3(x, y, 0), V3(min(2.5, x + on), y, 0))) }
    }
    dashed(4, 0.24, 0.16)
    if let adv = scene.advantageY { dashed(adv, 0.1, 0.1) }
    if let kid = scene.shownKidY { dashed(kid, KidLine.dot, KidLine.gap) }
    ctx.setLineCap(.butt)
    stroke(lines, 0x000000, lw)
    ctx.setLineCap(.round)
    marks(scene)
    kidCones(scene, KidLine.cone("bw"))
    pieces(scene, paint: .mono)
    if let arc = scene.arc { trajectory(arc, ground: false) }
  }
}

/// The Kid line (a Kid match, engine 0.15): short dots across the pitch, told apart from
/// the advantage line's dashes and the centre line's, with a traffic cone just off each
/// sideline, so a child sees where to stand (the web's world.js `kidDot`, `kidGap`,
/// `kidConeX`).
enum KidLine {
  /// m: a dot and the gap after it.
  static let dot = 0.05, gap = 0.09
  /// m from the middle: each cone, just off its sideline.
  static let coneX = 2.85
  /// m: a cone's height.
  static let coneHeight = 0.3
  /// A cone's body, band and line in a scene: orange with a white band; Black & White's
  /// white with a black band; Techno's lit from within.
  static func cone(_ look: String) -> (body: Int, band: Int, ink: Int) {
    switch look {
    case "bw": (0xffffff, 0x000000, 0x000000)
    case "neon": (0x2a1204, 0xff9a4a, 0xff9a4a)
    case "night": (0xff7a1f, 0xf4f2e8, 0x060a13)
    default: (0xff7a1f, 0xffffff, ink)
    }
  }
}

extension PitchScene {
  /// The Kid line to draw: none where it is the advantage line itself.
  var shownKidY: Double? {
    guard let k = kidY else { return nil }
    if let a = advantageY, abs(a - k) < 1e-6 { return nil }
    return k
  }
}

extension Painter {
  /// The Kid line's two cones, standing just off the sidelines at its ends.
  func kidCones(_ scene: PitchScene, _ c: (body: Int, band: Int, ink: Int) = KidLine.cone("day")) {
    guard let y = scene.kidY else { return }
    for x in [-KidLine.coneX, KidLine.coneX] {
      billboard(V3(x, y, 0)) { u in
        let s = KidLine.coneHeight
        let w = max(1, min(2.6, s * u / 12)) / u
        let base = CGPath(ellipseIn: CGRect(x: -s * 0.42, y: -s * 0.12, width: s * 0.84, height: s * 0.24), transform: nil)
        fill(base, c.body)
        stroke(base, c.ink, w)
        let body = path([
          CGPoint(x: -s * 0.3, y: 0), CGPoint(x: -s * 0.06, y: s), CGPoint(x: s * 0.06, y: s), CGPoint(x: s * 0.3, y: 0),
        ])
        fill(body, c.body)
        fill(
          path([
            CGPoint(x: -s * 0.21, y: s * 0.38), CGPoint(x: -s * 0.15, y: s * 0.6), CGPoint(x: s * 0.15, y: s * 0.6),
            CGPoint(x: s * 0.21, y: s * 0.38),
          ]), c.band)
        stroke(body, c.ink, w)
      }
    }
  }
}
