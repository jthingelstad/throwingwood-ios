import CoreGraphics
import Foundation
import simd

/// Where a piece meets the ground hard (the engine's ground impacts, its docs/SESSION.md
/// "Ground impacts", since 0.14; the session asks for them with `setImpacts`): a scene
/// draws something at each, timed by the throw's own clock. Techno rings (the owner,
/// 2026-11-21: "when something hits the floor it should give a visual ring on impact");
/// Beach puffs sand and Minnesota sprays snow. The web's src/render/impacts.js is the
/// reference: its numbers are `tune`.
///
/// A ring is a circle on the ground growing from its spot, sized by how fast the piece
/// came down (`speed`, m/s), fading as it grows. Under Reduce Motion it does not grow: a
/// ring at its middle size fades out where it struck. A puff is a few soft blobs of the
/// ground's colour rising a little; reduced, a smaller one that does not rise. Nothing
/// here is in a snapshot, an action or a hash.
struct Impacts {
  enum Style { case ring, puff }
  enum Tune {
    /// s of the throw's clock
    static let ringLife = 0.75
    /// m: its radius at the strike, and its last: base + perSpeed x speed, at most max
    static let ringFrom = 0.06, ringBase = 0.22, ringPerSpeed = 0.17, ringMax = 0.95
    /// its share of the last radius, held still, under Reduce Motion
    static let ringReduced = 0.45
    /// pt: the ring's line, and its bloom (width, alpha)
    static let ringCore = 1.4
    static let ringGlow: [(w: Double, a: Double)] = [(7, 0.16), (3.5, 0.3)]
    /// m: a ring nearer the camera than this is not drawn (the impact camera's close
    /// shots would ring across the whole screen)
    static let ringNear = 2.2
    static let puffLife = 0.55
    /// m/s: a softer strike raises nothing
    static let puffFrom = 1.4
    /// m: a disc's radius at its fullest (times the strike's weight), how far it rises,
    /// and pt: its largest radius on the screen
    static let puffSize = 0.045, puffRise = 0.12, puffMaxPt = 11.0
    /// live at once
    static let max = 40
  }
  struct Live {
    let impact: Recording.Impact
    var age: Double
  }
  let style: Style
  let reduced: Bool
  /// A ring's colour by piece: each side's light, the king's own, the baton's.
  let colors: (a: Int, b: Int, king: Int, baton: Int)
  /// A puff's blobs.
  let puffs: [Int]
  private var list: [Recording.Impact] = []
  private var next = 0
  private(set) var live: [Live] = []
  private var lastT: Double?

  init(style: Style, reduced: Bool, colors: (a: Int, b: Int, king: Int, baton: Int) = (0, 0, 0, 0), puffs: [Int] = []) {
    self.style = style
    self.reduced = reduced
    self.colors = colors
    self.puffs = puffs
  }

  var active: Bool { !live.isEmpty }

  mutating func clear() {
    list = []
    next = 0
    live = []
    lastT = nil
  }
  mutating func watch(_ rec: Recording) {
    list = (rec.timeline.impacts ?? []).filter { $0.t.isFinite }.sorted { $0.t < $1.t }
    next = 0
    live = []
    lastT = nil
  }
  /// A playback frame at shown time `t` (slow motion included): every impact whose `t`
  /// is reached starts, and the live ones age by the shown time gone by.
  mutating func observe(_ t: Double) {
    let dt = lastT.map { t - $0 } ?? 0
    lastT = t
    if dt > 0 { age(dt) }
    while next < list.count && list[next].t <= t {
      let i = list[next]
      next += 1
      if style == .puff && !((i.speed ?? 0) >= Tune.puffFrom) { continue }
      if live.count >= Tune.max { live.removeFirst() }
      live.append(Live(impact: i, age: max(0, t - i.t)))
    }
  }
  /// After the throw: they age by real time.
  mutating func tick(_ dt: Double) { if dt > 0 { age(dt) } }
  private mutating func age(_ dt: Double) {
    let life = style == .ring ? Tune.ringLife : Tune.puffLife
    for i in live.indices { live[i].age += dt }
    live.removeAll { $0.age >= life }
  }

  private static func ease(_ u: Double) -> Double { 1 - (1 - u) * (1 - u) }

  /// A live ring's radius (m) and alpha now.
  func ring(_ l: Live) -> (r: Double, alpha: Double) {
    let u = min(1, l.age / Tune.ringLife)
    let last = min(Tune.ringMax, Tune.ringBase + Tune.ringPerSpeed * (l.impact.speed ?? 1))
    let r = reduced ? last * Tune.ringReduced : Tune.ringFrom + (last - Tune.ringFrom) * Self.ease(u)
    return (r, (1 - u) * (1 - u * 0.3))
  }

  func color(of i: Recording.Impact) -> Int {
    if i.with == "king" { return colors.king }
    if i.id.first == "a", i.id.dropFirst().first?.isNumber == true { return colors.a }
    if i.id.first == "b", i.id.dropFirst().first?.isNumber == true { return colors.b }
    return colors.baton
  }

  func draw(_ ctx: CGContext, _ projection: PitchProjection) {
    guard !live.isEmpty else { return }
    style == .ring ? drawRings(ctx, projection) : drawPuffs(ctx, projection)
  }

  private func drawRings(_ ctx: CGContext, _ projection: PitchProjection) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setBlendMode(.plusLighter)
    ctx.setLineJoin(.round)
    for l in live {
      let (r, alpha) = ring(l)
      guard projection.view(V3(l.impact.x, l.impact.y, 0)).z >= Tune.ringNear else { continue }
      let n = 40
      let pts = (0..<n).map { k -> V3 in
        let a = Double(k) / Double(n) * .pi * 2
        return V3(l.impact.x + r * cos(a), l.impact.y + r * sin(a), 0)
      }
      let p = projection.polygon(pts)
      guard p.count >= 3 else { continue }
      let shape = path(p)
      let c = color(of: l.impact)
      for g in Tune.ringGlow {
        ctx.setStrokeColor(KubbRenderer.color(c, g.a * alpha))
        ctx.setLineWidth(g.w)
        ctx.addPath(shape)
        ctx.strokePath()
      }
      ctx.setStrokeColor(KubbRenderer.color(c, alpha))
      ctx.setLineWidth(Tune.ringCore)
      ctx.addPath(shape)
      ctx.strokePath()
    }
  }

  /// A puff: a small cartoon cloud of three discs of the ground's colour with the ink
  /// line, swelling a little and rising, then shrinking away (no tint over the pitch:
  /// the flat style has none).
  private func drawPuffs(_ ctx: CGContext, _ projection: PitchProjection) {
    let cols = puffs.isEmpty ? [0xe8cf98] : puffs
    for l in live {
      let u = min(1, l.age / Tune.puffLife)
      let k = min(1.5, 0.55 + (l.impact.speed ?? 1) * 0.28)
      // swell to the middle of its life, then shrink to nothing
      let grow = reduced ? 1 - u : (u < 0.4 ? 0.6 + Self.ease(u / 0.4) * 0.6 : 1.2 * (1 - Self.ease((u - 0.4) / 0.6)))
      guard grow > 0.02 else { continue }
      let rise = reduced ? 0 : Tune.puffRise * Self.ease(u) * k
      var discs: [(CGPoint, Double, Int)] = []
      for j in 0..<3 {
        let ox = Double(j - 1) * Tune.puffSize * 1.1 * k
        let v = projection.view(V3(l.impact.x + ox, l.impact.y, Tune.puffSize * k * (j == 1 ? 1.3 : 0.9) + rise))
        guard v.z >= 0.05 else { continue }
        // never larger than puffMaxPt on the screen: a strike under a close camera stays
        // a small cloud
        let rr = min(Tune.puffMaxPt, Tune.puffSize * k * projection.c.f * projection.k / v.z) * grow * (j == 1 ? 1.25 : 0.9)
        discs.append((projection.screen(v), rr, cols[j % cols.count]))
      }
      guard let first = discs.first else { continue }
      let w = max(0.8, min(2.2, first.1 * 0.12))
      let outline = CGMutablePath()
      for (c, r, _) in discs { outline.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
      ctx.setStrokeColor(KubbRenderer.color(ink))
      ctx.setLineWidth(w * 2)
      ctx.addPath(outline)
      ctx.strokePath()
      for (c, r, rgb) in discs {
        ctx.setFillColor(KubbRenderer.color(rgb))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
      }
    }
  }
}
