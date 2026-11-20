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
  /// `look`: the scene the map is skinned for (the web's skin hud.mapGround);
  /// the day, or an unknown scene, draws it as it always was.
  public func drawMap(in ctx: CGContext, rect: CGRect, look: String? = nil) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    let m = MapPaint.of(SceneID.shown(look ?? self.look), surface)
    let ink = m.ink, white = m.line
    ctx.setFillColor(color(m.drop.rgb, m.drop.a))
    ctx.fill(rect.offsetBy(dx: 2, dy: 2))
    ctx.setFillColor(color(m.paper))
    ctx.fill(rect)
    ctx.setStrokeColor(color(ink))
    ctx.setLineWidth(2)
    ctx.stroke(rect)
    let s = min((rect.width - 8) / 5, (rect.height - 8) / 8)
    let field = CGRect(x: rect.midX - 2.5 * s, y: rect.midY - 4 * s, width: 5 * s, height: 8 * s)
    ctx.setFillColor(color(m.ground))
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
      let paint = piece.team == "B" ? m.teamB : (piece.team == "A" ? m.teamA : m.king)
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

/// The minimap's colours in a scene (palette.js NIGHT.skin and NEON.skin
/// hud.mapGround, and the pieces in their scene's light).
struct MapPaint {
  let ink, paper, ground, line, teamA, teamB, king: Int
  let drop: (rgb: Int, a: Double)
  static func of(_ look: String, _ surface: Surface) -> MapPaint {
    switch look {
    case "night":
      let g: (Int, Int) =
        switch surface {
        case .grass: (0x284a3b, 0xe6f8ff)
        case .sand: (0x6e6452, 0xfff3dc)
        case .snow: (0x9fb4d3, 0x1f5fd0)
        }
      return MapPaint(
        ink: 0xdbe9ff, paper: 0x0d1424, ground: g.0, line: g.1, teamA: 0xf2b705, teamB: 0xb07ad0,
        king: 0xf4cf6a, drop: (0x000000, 0.55))
    case "neon":
      let g: (Int, Int) =
        switch surface {
        case .grass: (0x0a2a33, 0xc8fdff)
        case .sand: (0x30200a, 0xfff0c8)
        case .snow: (0x1c2a48, 0xffffff)
        }
      return MapPaint(
        ink: 0x5ff0ff, paper: 0x02050a, ground: g.0, line: g.1, teamA: 0xffc94a, teamB: 0xcf8bff,
        king: 0xff5c9d, drop: (0x2be4ff, 0.35))
    default:
      return MapPaint(
        ink: dayInk, paper: dayPaper,
        ground: surface == .grass ? 0x6bb146 : (surface == .sand ? 0xe8cf98 : 0xd3dfec),
        line: dayWhite, teamA: 0xf2b705, teamB: 0x8e44ad, king: dayInk,
        drop: (dayInk, 1))
    }
  }
}
private let dayInk = ink, dayPaper = paper, dayWhite = white
