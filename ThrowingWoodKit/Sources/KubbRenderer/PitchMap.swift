import CoreGraphics
import simd

extension PitchScene {
  public var scenery: PitchScene {
    var background = self
    background.arc = nil
    background.marker = nil
    background.thrower = nil
    return background
  }

  /// The minimap's plate: the same as a tray plate's (the 1.0 design, "Minimap: one
  /// home"): a 3 pt ink line, radius 6 and a 3 pt hard shadow.
  public static let mapLine: CGFloat = 3, mapRadius: CGFloat = 6, mapShadow: CGFloat = 3

  /// From the same thrower-frame poses as the pitch, with the far baseline at the top.
  /// `look`: the scene the map is skinned for (the web's skin hud.mapGround). Teams are
  /// told apart by shape as well as colour (the 1.0 design): Team A circles, Team B
  /// squares, the king a triangle. `rect` is the plate, its shadow outside it.
  public func drawMap(in ctx: CGContext, rect: CGRect, look: String? = nil) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    let m = MapPaint.of(SceneID.shown(look ?? self.look), surface)
    let ink = m.ink, white = m.line
    let r = Self.mapRadius
    ctx.setFillColor(color(m.drop.rgb, m.drop.a))
    ctx.addPath(CGPath(roundedRect: rect.offsetBy(dx: Self.mapShadow, dy: Self.mapShadow), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()
    let inner = rect.insetBy(dx: Self.mapLine / 2, dy: Self.mapLine / 2)
    ctx.setFillColor(color(m.paper))
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: r - Self.mapLine / 2, cornerHeight: r - Self.mapLine / 2, transform: nil))
    ctx.fillPath()
    ctx.setStrokeColor(color(ink))
    ctx.setLineWidth(Self.mapLine)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: r - Self.mapLine / 2, cornerHeight: r - Self.mapLine / 2, transform: nil))
    ctx.strokePath()
    let s = min((rect.width - 10) / 5, (rect.height - 10) / 8)
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
      let shape = Self.mapShape(piece)
      let paint = shape == .square ? m.teamB : (shape == .circle ? m.teamA : m.king)
      let path = CGMutablePath()
      switch shape {
      case .circle: path.addEllipse(in: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2))
      case .square: path.addRect(CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4))
      case .triangle:
        path.addLines(between: [CGPoint(x: p.x, y: p.y - 3.4), CGPoint(x: p.x + 3.2, y: p.y + 2.4), CGPoint(x: p.x - 3.2, y: p.y + 2.4)])
        path.closeSubpath()
      }
      ctx.setFillColor(color(paint))
      ctx.addPath(path)
      ctx.fillPath()
      ctx.setStrokeColor(color(ink))
      ctx.addPath(path)
      ctx.strokePath()
    }
    if let m = marker, m.shown != false {
      let p = point(m.x, m.y)
      ctx.setStrokeColor(color(ink))
      ctx.strokeEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
    }
  }
}

extension PitchScene {
  /// A piece's mark on the minimap: Team A a circle, Team B a square (the 1.0 design's
  /// "Teams"), anything else (the king, a baton) a triangle.
  public enum MapShape: Sendable { case circle, square, triangle }
  public static func mapShape(_ p: Piece) -> MapShape {
    p.team == "A" ? .circle : (p.team == "B" ? .square : .triangle)
  }

  /// Is a piece standing (its own z axis within about 45 degrees of up)?
  static func standing(_ p: Piece) -> Bool {
    // the local z axis turned into the world: its z component
    let q = p.rotation
    let z = q.act(SIMD3<Double>(0, 0, 1)).z
    return z > 0.7
  }

  /// The minimap as VoiceOver reads it, one image with a summary: each team's kubbs
  /// standing and their shape, the king, and the aim ("Map of the pitch. Computer: 5
  /// kubbs standing, squares. Brave Birch: 5 kubbs standing, circles. The king standing.
  /// The aim ringed.").
  public func mapSummary(teamA: String?, teamB: String?) -> String {
    func count(_ team: String) -> Int {
      items.filter { $0.kind == "kubb" && $0.team == team && Self.standing($0) }.count
    }
    func side(_ name: String?, _ team: String, _ shape: String) -> String {
      let n = count(team)
      return "\(name ?? "Team \(team)"): \(n) \(n == 1 ? "kubb" : "kubbs") standing, \(shape)."
    }
    var parts = ["Map of the pitch.", side(teamB, "B", "squares"), side(teamA, "A", "circles")]
    if let king = items.first(where: { $0.kind == "king" }) {
      parts.append(Self.standing(king) ? "The king standing." : "The king down.")
    }
    if let m = marker, m.shown != false { parts.append("The aim ringed.") }
    return parts.joined(separator: " ")
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
