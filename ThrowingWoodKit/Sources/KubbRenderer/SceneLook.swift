import CoreGraphics
import simd

/// A match's scene (engine 0.9's `scene`): the whole look of a pitch, its world,
/// the skin on its controls and its effects. A look only: it never changes a
/// throw, the engine or a hash. The web's src/render/scenes.js is the reference.
public enum SceneID {
  /// The scenes this build draws besides the day.
  public static let drawn: Set<String> = ["night", "neon"]
  /// The Scene row, the web's SCENE_ROW: Day, Night, Neon.
  public static let row = MatchOption(
    id: "scene", label: "Scene", choices: [["day", "Day"], ["night", "Night"], ["neon", "Neon"]])
  /// The scene drawn for `id`: a scene this build knows, else the day. An unknown
  /// id is drawn as the day and passed through untouched wherever it is carried.
  public static func shown(_ id: String?) -> String {
    guard let id, drawn.contains(id) else { return "day" }
    return id
  }
  /// The engine takes a scene (0.9 on): `scene` is in its OPTION_DEFAULTS.
  static func taken(by optionDefaults: [String: String]) -> Bool {
    optionDefaults["scene"] != nil
  }
}

/// The tones a piece's faces take, by how they face the light (the web's WOOD).
struct Tones {
  let top, light, shade, end, endShade, grain, grainShade, ring, bevel: Int
}

/// How a scene lights one piece (the neon's litOf): its edges, bevel and band.
struct Lit {
  let ink, bevel: Int
  let band, bandDeep: Int?
}

/// A scene's light and paint for the pieces (the web's DAYLIGHT and DAY_PAINT,
/// or a look's `light` and `paint`).
struct PiecePaint {
  let isDay: Bool
  let wood, kingWood, stake: Tones
  let outline, kingMark: Int
  let light: V3
  let awayBelow, topAbove: Double
  /// Shadows fall this far along x and y per metre of height.
  let shadowX, shadowY: Double
  let shadowFill: Int, shadowAlpha: Double
  let litOf: (@Sendable (Piece) -> Lit)?

  static let dayWood = Tones(
    top: 0xf6e4bf, light: 0xecd2a0, shade: 0xb88a4f, end: 0xe2bf86, endShade: 0xa87a42,
    grain: 0xc79d63, grainShade: 0x8d6535, ring: 0xc0935a, bevel: 0xfff3d8)
  /// The day exactly as Wood.swift always drew it (RendererTests pins it).
  static let day = PiecePaint(
    isDay: true, wood: dayWood, kingWood: dayWood,
    stake: Tones(
      top: 0xc9a06a, light: 0xc9a06a, shade: 0x8a6234, end: 0xb38550, endShade: 0xb38550,
      grain: 0, grainShade: 0, ring: 0, bevel: 0),
    outline: ink, kingMark: 0x2a2118, light: simd_normalize(V3(-0.55, 0.3, 1)),
    awayBelow: -0.35, topAbove: 0.75, shadowX: 0.55, shadowY: -0.3, shadowFill: ink,
    shadowAlpha: 1, litOf: nil)

  static let night: PiecePaint = {
    let l = simd_normalize(V3(Night.lightX, Night.lightY, 1))
    return PiecePaint(
      isDay: false,
      wood: Tones(
        top: 0xf4fffc, light: 0xc8f8ec, shade: 0x82d3c2, end: 0xddfcf4, endShade: 0x6fbfae,
        grain: 0xa9ebdc, grainShade: 0x66b5a5, ring: 0xa4e7d8, bevel: 0xffffff),
      kingWood: Tones(
        top: 0xfff8dc, light: 0xffe8a6, shade: 0xe1b45c, end: 0xfff1c4, endShade: 0xcb9c48,
        grain: 0xf1cf80, grainShade: 0xba8b3c, ring: 0xeec872, bevel: 0xffffff),
      stake: Tones(
        top: 0xeafaff, light: 0xc4ecff, shade: 0x86bddf, end: 0xdcf5ff, endShade: 0x86bddf,
        grain: 0, grainShade: 0, ring: 0, bevel: 0),
      outline: 0x060a13, kingMark: 0x6e4512, light: l, awayBelow: -0.8, topAbove: 0.72,
      shadowX: -Night.lightX * 0.9, shadowY: -Night.lightY * 0.9, shadowFill: 0x01030a,
      shadowAlpha: 0.5, litOf: nil)
  }()

  static let neon: PiecePaint = {
    let l = simd_normalize(V3(0.12, -0.2, 1))
    let solid = Tones(
      top: 0x111827, light: 0x0b111c, shade: 0x060a12, end: 0x0e1522, endShade: 0x05080e,
      grain: 0x0b111c, grainShade: 0x060a12, ring: 0x0e1522, bevel: 0x5d6b80)
    return PiecePaint(
      isDay: false, wood: solid, kingWood: solid, stake: solid, outline: Neon.stakeLit,
      kingMark: Neon.kingLit, light: l, awayBelow: -0.8, topAbove: 0.72,
      shadowX: -l.x * 0.5, shadowY: -l.y * 0.5, shadowFill: 0, shadowAlpha: 0.6,
      litOf: Neon.litOf)
  }()

  static func of(_ look: String) -> PiecePaint {
    switch look {
    case "night": night
    case "neon": neon
    default: day
    }
  }
}

/// A scene's ground on one surface.
struct SceneGround {
  var pitch, stripe, rough, speck, sky, line, glow: Int
  var pitchAlpha = 1.0
  /// Night's rim and clearing edge; neon's grid and its spacing.
  var edge = 0, rim = 0, grid = 0
  var gridEvery = 1.0
  /// Night snow's bloom is painted, not added (it would wash out the snow).
  var additiveGlow = true
}

enum Night {
  static let lightX = -0.1, lightY = 0.62
  static let clearing = (x0: -6.5, x1: 6.5, y0: -7.0, y1: 10.6)
  static func ground(_ s: Surface) -> SceneGround {
    switch s {
    case .grass:
      SceneGround(
        pitch: 0x284a3b, stripe: 0x2e5242, rough: 0x1a3329, speck: 0x10241b, sky: 0x02040b,
        line: 0xe6f8ff, glow: 0x6fcfff, edge: 0x0b1813, rim: 0x04090a)
    case .sand:
      SceneGround(
        pitch: 0x6e6452, stripe: 0x776c59, rough: 0x554c3e, speck: 0x3e372d, sky: 0x02040b,
        line: 0xfff3dc, glow: 0xffc86b, edge: 0x29241d, rim: 0x0a0907)
    case .snow:
      SceneGround(
        pitch: 0xb9cbe4, stripe: 0xc5d6ec, rough: 0x9fb4d3, speck: 0x8399bd, sky: 0x02040b,
        line: 0x1f7bff, glow: 0x3f9dff, edge: 0x61779c, rim: 0x0b1222, additiveGlow: false)
    }
  }
  static let halo = (kubb: 0x5ff0d2, king: 0xffcf5c, stake: 0x7fd4ff)
}

enum Neon {
  static let stakeLit = 0xe9fbff
  static let kingLit = 0xff5c9d, kingDim = 0x7c2d4c
  static let team: [String: (lit: Int, dim: Int, deep: Int, dimDeep: Int)] = [
    "A": (0xffc94a, 0x7a5b1c, 0xd99a14, 0x4a3710),
    "B": (0xcf8bff, 0x5f3f7c, 0x9a55d6, 0x3a2650),
  ]
  static func ground(_ s: Surface) -> SceneGround {
    switch s {
    case .grass:
      SceneGround(
        pitch: 0x04242e, stripe: 0, rough: 0, speck: 0, sky: 0, line: 0xc8fdff, glow: 0x2be4ff,
        pitchAlpha: 0.4, grid: 0x11a3b4, gridEvery: 1)
    case .sand:
      SceneGround(
        pitch: 0x301c02, stripe: 0, rough: 0, speck: 0, sky: 0, line: 0xfff0c8, glow: 0xffad33,
        pitchAlpha: 0.4, grid: 0xc07a12, gridEvery: 2)
    case .snow:
      SceneGround(
        pitch: 0x1a2646, stripe: 0, rough: 0, speck: 0, sky: 0, line: 0xffffff, glow: 0x9cc2ff,
        pitchAlpha: 0.4, grid: 0x8fb4ff, gridEvery: 0.5)
    }
  }
  /// A piece that lies: its long axis well off upright, on the floor.
  static func lying(_ p: Piece) -> Bool {
    let az = 1 - 2 * (p.qx * p.qx + p.qy * p.qy)
    return abs(az) < 0.6 && p.z < 0.2
  }
  /// What lights a piece: its side's colour (the king his own), dimmed while it lies.
  @Sendable static func litOf(_ p: Piece) -> Lit {
    if p.kind == "stake" { return Lit(ink: stakeLit, bevel: stakeLit, band: nil, bandDeep: nil) }
    let down = lying(p)
    if p.kind == "king" {
      return down
        ? Lit(ink: kingDim, bevel: kingDim, band: nil, bandDeep: nil)
        : Lit(ink: kingLit, bevel: kingDim, band: nil, bandDeep: nil)
    }
    if let team = p.team, let t = team.isEmpty ? nil : Self.team[team] {
      return down
        ? Lit(ink: t.dim, bevel: t.dimDeep, band: t.dim, bandDeep: t.dimDeep)
        : Lit(ink: t.lit, bevel: t.deep, band: t.lit, bandDeep: t.deep)
    }
    return Lit(ink: stakeLit, bevel: 0x5d6b80, band: nil, bandDeep: nil)
  }
}
