import CoreGraphics
import Foundation
import simd

/// A scene's effects for the throws it shows: the night's stardust, the
/// neon's ribbon, sparks and impact rings, the beach's sand and Minnesota's snow
/// where a piece strikes the ground (the web's Stage.fx). Fed by the session's
/// playback (`watch` a recording, `observe` each shown frame, `tick` between), drawn
/// by the renderer after the pieces. Reduce Motion calms them: no trail and no
/// ribbon, fewer and shorter puffs, no hit flash, rings that do not grow.
public final class SceneEffects {
  public let look: String
  public let reduced: Bool
  var dust: Stardust?
  /// The ground impacts' rings or puffs (Impacts.swift), where the scene has them.
  var impacts: Impacts?
  /// The scene's impacts ring (the catalogue's `ring`: Techno).
  public var rings: Bool { impacts?.style == .ring }
  // the neon's ribbon: the thrown piece's two ends, kept for a moment; Techno's light
  // trail lingers (the web's 0.55 s)
  private static let ribbonN = 40, ribbonLife = 0.55, ribbonAlpha = 0.26, ribbonCore = 0.012
  private var poses: [(a: V3, b: V3, t: Double)] = []
  private var now = 0.0

  /// nil for the scenes that have none (Park, the Tournament, Black & White) and an
  /// unknown scene (drawn as the day).
  public init?(look id: String, reduced: Bool) {
    switch SceneID.shown(id) {
    case "night": dust = Stardust(.night(reduced: reduced))
    case "neon":
      dust = Stardust(.neon(reduced: reduced))
      impacts = Impacts(
        style: .ring, reduced: reduced,
        colors: (Neon.team["A"]!.lit, Neon.team["B"]!.lit, Neon.kingLit, Neon.stakeLit))
    case "beach": impacts = Impacts(style: .puff, reduced: reduced, puffs: [0xe8cf98, 0xdcbd80, 0xf3e2b8])
    case "minnesota": impacts = Impacts(style: .puff, reduced: reduced, puffs: [0xffffff, 0xeef4fb, 0xdfe9f4])
    default: return nil
    }
    look = SceneID.shown(id)
    self.reduced = reduced
  }

  /// True while anything is still to be drawn (the display stays awake).
  public var active: Bool {
    dust?.active == true || impacts?.active == true
      || (poses.last.map { now - $0.t <= Self.ribbonLife } ?? false)
  }
  /// Most particles alive at once since the effects were made.
  public var peak: Int { dust?.peak ?? 0 }

  public func clear() {
    dust?.clear()
    impacts?.clear()
    poses = []
  }
  func watch(_ rec: Recording) {
    dust?.watch(rec)
    impacts?.watch(rec)
    poses = []
  }
  func observe(_ items: [Piece], _ t: Double) {
    dust?.observe(items, t)
    impacts?.observe(t)
    now = t
    guard look == "neon", !reduced, let dust, let id = dust.pid, let p = dust.byId[id] else { return }
    let hz = dust.pkind == "baton" ? 0.15 : 0.075
    let axis = V3(
      2 * (p.qx * p.qz + p.qw * p.qy), 2 * (p.qy * p.qz - p.qw * p.qx),
      1 - 2 * (p.qx * p.qx + p.qy * p.qy))
    // a piece at rest adds nothing: its ribbon fades out
    if let last = poses.last, simd_length_squared((last.a + last.b) / 2 - p.center) < 1e-4 { return }
    poses.append((p.center + axis * hz, p.center - axis * hz, t))
    if poses.count > Self.ribbonN { poses.removeFirst(poses.count - Self.ribbonN) }
  }
  func tick(_ dt: Double) {
    dust?.tick(dt)
    impacts?.tick(dt)
    if dt > 0 { now += dt }
  }

  func draw(_ ctx: CGContext, _ projection: PitchProjection) {
    impacts?.draw(ctx, projection)
    if poses.count > 1 { ribbon(ctx, projection) }
    dust?.draw(ctx, projection)
  }

  // Each unbroken run of poses is one band and two edge lines, faded along the
  // run from its oldest pose to its newest.
  private func ribbon(_ ctx: CGContext, _ projection: PitchProjection) {
    var run: [(a: V3, b: V3, u: Double, d: Double)] = []
    func flush() {
      if run.count > 1 { band(ctx, projection, run) }
      run = []
    }
    for p in poses {
      let age = now - p.t
      let va = projection.view(p.a)
      let vb = projection.view(p.b)
      if age <= Self.ribbonLife, age >= -0.05, va.z >= 0.15, vb.z >= 0.15 {
        run.append((va, vb, 1 - max(0, age) / Self.ribbonLife, (va.z + vb.z) / 2))
      } else {
        flush()
      }
    }
    flush()
  }

  private func band(
    _ ctx: CGContext, _ projection: PitchProjection, _ run: [(a: V3, b: V3, u: Double, d: Double)]
  ) {
    let a = run.map { projection.screen($0.a) }
    let b = run.map { projection.screen($0.b) }
    let mid = zip(a, b).map { CGPoint.between($0, $1, 0.5) }
    let o = mid[0]
    let h = mid[mid.count - 1]
    let v = CGPoint(x: h.x - o.x, y: h.y - o.y)
    let vv = v.x * v.x + v.y * v.y
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
    func gradient(_ rgb: Int, _ k: Double) -> CGGradient? {
      var locations: [CGFloat] = []
      var colors: [CGColor] = []
      var last = 0.0
      for (i, m) in mid.enumerated() {
        let f = vv < 1 ? 1 : min(1, max(last, ((m.x - o.x) * v.x + (m.y - o.y) * v.y) / vv, 0))
        last = f
        locations.append(f)
        colors.append(color(rgb, min(1, run[i].u * run[i].u * k)))
      }
      return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }
    let end = vv < 1 ? CGPoint(x: o.x + 1, y: o.y) : h
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    let shape = CGMutablePath()
    shape.addLines(between: a + b.reversed())
    shape.closeSubpath()
    ctx.addPath(shape)
    ctx.clip()
    if let g = gradient(0x2be4ff, Self.ribbonAlpha) {
      ctx.drawLinearGradient(g, start: o, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    let edges = CGMutablePath()
    edges.addLines(between: a)
    edges.addLines(between: b)
    let d = run[run.count - 1].d
    ctx.setLineWidth(max(0.8, Self.ribbonCore * projection.c.f * projection.k / d))
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(edges)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if let g = gradient(0xffffff, Self.ribbonAlpha * 2.2) {
      ctx.drawLinearGradient(g, start: o, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
  }
}
