import CoreGraphics

extension PitchScene {
  public var scenery: PitchScene {
    var background = self
    background.arc = nil
    background.marker = nil
    background.thrower = nil
    return background
  }

  /// From the same thrower-frame poses as the pitch, with the far baseline at the top.
  public func drawMap(in ctx: CGContext, rect: CGRect) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setFillColor(color(ink))
    ctx.fill(rect.offsetBy(dx: 2, dy: 2))
    ctx.setFillColor(color(paper))
    ctx.fill(rect)
    ctx.setStrokeColor(color(ink))
    ctx.setLineWidth(2)
    ctx.stroke(rect)
    let s = min((rect.width - 8) / 5, (rect.height - 8) / 8)
    let field = CGRect(x: rect.midX - 2.5 * s, y: rect.midY - 4 * s, width: 5 * s, height: 8 * s)
    let ground = surface == .grass ? 0x6bb146 : (surface == .sand ? 0xe8cf98 : 0xd3dfec)
    ctx.setFillColor(color(ground))
    ctx.fill(field)
    ctx.setLineWidth(1)
    ctx.stroke(field)
    func point(_ x: Double, _ y: Double) -> CGPoint {
      CGPoint(x: field.midX + x * s, y: field.maxY - y * s)
    }
    func segment(_ a: CGPoint, _ b: CGPoint, _ rgb: Int) {
      ctx.setStrokeColor(color(rgb))
      ctx.beginPath()
      ctx.move(to: a)
      ctx.addLine(to: b)
      ctx.strokePath()
    }
    ctx.setLineDash(phase: 0, lengths: [3, 2])
    segment(point(-2.5, 4), point(2.5, 4), white)
    if let y = advantageY { segment(point(-2.5, y), point(2.5, y), ink) }
    ctx.setLineDash(phase: 0, lengths: [])
    if let t = thrower, let m = marker, m.shown != false {
      segment(point(t.x, t.y), point(m.x, m.y), white)
    }
    for piece in items where piece.kind != "stake" {
      let p = point(piece.x, piece.y)
      guard rect.contains(p) else { continue }
      let dot = CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)
      let paint = piece.team == "B" ? 0x8e44ad : (piece.team == "A" ? 0xf2b705 : ink)
      ctx.setFillColor(color(paint))
      ctx.fill(dot)
      ctx.setStrokeColor(color(ink))
      ctx.stroke(dot)
    }
    if let m = marker, m.shown != false {
      let p = point(m.x, m.y)
      ctx.setStrokeColor(color(ink))
      ctx.strokeEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
    }
  }
}
