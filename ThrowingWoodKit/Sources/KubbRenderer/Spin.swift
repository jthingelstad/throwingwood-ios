import CoreGraphics
import Foundation
import simd

// A piece that spins faster than the frames can show (the web's src/render/scenes.js
// spinAmount and world.js drawSpin). Two players said a thrown kubb "looks really weird"
// (2026-11-22): at SPIN's most a kubb leaves the hand at about 69 rad/s, eleven turns a
// second, 66 degrees a frame at 60 frames a second. A kubb's square section looks the
// same every quarter turn, so a turn of more than an eighth a frame is read the wrong way
// round: it seems to stand, jitter or turn back. Its end over end turn looks the same
// every half turn. So each shown frame measures each piece's turn since the frame before,
// split into the twist about its long axis and the rest (a swing-twist split), and a
// piece turning too fast is drawn with its in-between poses, the piece's own pose fading
// a little, back to the plain drawing as it slows. The physics is never touched: only
// the shown poses are read, so 120 frames a second (half the turn a frame) and slow
// motion (a fraction of it) draw less blur or none.

/// How much of the spin drawing a piece gets this frame, and where it was the frame before.
struct Spin: Decodable, Sendable {
  let u: Double
  let from: Piece
}

enum SpinTune {
  /// Degrees a frame about the long axis: the drawing starts to blur, and is fully a
  /// spin by here (a square section's eighth turn is 45).
  static let twistFrom = 30.0, twistFull = 50.0
  /// End over end: a half turn repeats, so twice those.
  static let swingFrom = 60.0, swingFull = 100.0
  /// In-between poses drawn, each this strong at full blur; the piece's own pose fades
  /// this much at full blur.
  static let ghosts = 4
  static let ghostAlpha = 0.42, sharpFade = 0.55

  /// How much of a spin to draw for a piece of `kind` that turned from pose `a` to pose
  /// `b` in one shown frame: 0 to 1.
  static func amount(_ a: Piece, _ b: Piece, kind: String) -> Double {
    let q1 = a.rotation, q2 = b.rotation
    // the turn between them in the world: d = q2 * conj(q1)
    var d = q2 * q1.conjugate
    if d.real < 0 { d = simd_quatd(real: -d.real, imag: -d.imag) }
    let axis = q2.act(V3(0, 0, 1))
    let along = dot(d.imag, axis)
    let twist = 2 * atan2(abs(along), d.real) * 180 / .pi
    // the swing: what is left once the twist is taken out. The twist is (w, along) made
    // whole, so the swing's real part is their dot, |(w, along)| itself
    let swing = 2 * acos(min(1, hypot(d.real, along))) * 180 / .pi
    func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
    // a baton is round about its long axis: its twist never shows
    let ut = kind == "baton" ? 0 : clamp01((twist - twistFrom) / (twistFull - twistFrom))
    let us = clamp01((swing - swingFrom) / (swingFull - swingFrom))
    return max(ut, us)
  }

  /// Each moving piece's spin from the poses of the frame before to these.
  static func spins(from before: [String: Piece], to now: [Piece]) -> [String: Spin]? {
    var out: [String: Spin] = [:]
    for p in now where p.kind != "stake" {
      guard let was = before[p.id] else { continue }
      let u = amount(was, p, kind: p.kind)
      if u > 0 { out[p.id] = Spin(u: u, from: was) }
    }
    return out.isEmpty ? nil : out
  }

  /// The pose `t` of the way from `a` to `b` (the turn by the shortest way).
  static func between(_ a: Piece, _ b: Piece, _ t: Double) -> Piece {
    var g = b
    g.x = a.x + (b.x - a.x) * t
    g.y = a.y + (b.y - a.y) * t
    g.z = a.z + (b.z - a.z) * t
    let q = simd_slerp(a.rotation, b.rotation, t)
    (g.qw, g.qx, g.qy, g.qz) = (q.real, q.imag.x, q.imag.y, q.imag.z)
    return g
  }
}

extension Painter {
  /// A piece turning faster than a frame can show: its in-between poses from where it was
  /// the frame before, faded in by how fast it turns, then its own pose a little faded.
  /// Black & White draws them solid, never a grey (the web's spinOpaque). `draw` draws one
  /// projected pose.
  func spinning(_ p: Projected, _ spin: Spin, _ draw: (Projected) -> Void) {
    let u = min(1, spin.u)
    let it = p.solid.piece
    let n = SpinTune.ghosts
    for j in 1...n {
      let g = SpinTune.between(spin.from, it, Double(j) / Double(n + 1))
      guard let gp = Projected(Solid(g, projection.c), projection) else { continue }
      faded(mono ? 1 : SpinTune.ghostAlpha * u) { draw(gp) }
    }
    faded(mono ? 1 : 1 - SpinTune.sharpFade * u) { draw(p) }
  }

  /// `body` drawn as one layer at `alpha` (its overlaps not doubled).
  func faded(_ alpha: Double, _ body: () -> Void) {
    guard alpha < 0.999 else { return body() }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
  }
}
