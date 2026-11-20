import Foundation

/// A colour as the app paints it: sRGB components 0 to 1 and an alpha.
public struct SkinPaint: Equatable, Sendable {
  public let r, g, b, a: Double
  public init(r: Double, g: Double, b: Double, a: Double = 1) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }
  public init(_ hex: Int, _ a: Double = 1) {
    self.init(
      r: Double((hex >> 16) & 0xff) / 255, g: Double((hex >> 8) & 0xff) / 255,
      b: Double(hex & 0xff) / 255, a: a)
  }

  /// WCAG 2 relative luminance (alpha ignored).
  public var luminance: Double {
    func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  }
  /// The WCAG contrast ratio of two opaque colours, 1 to 21.
  public static func contrast(_ x: SkinPaint, _ y: SkinPaint) -> Double {
    let a = x.luminance, b = y.luminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}

/// The controls' skin for a scene (the web's palette.js `skin` and its CSS
/// tokens): what the plates, cards, sliders, STAND, the meters, the bursts and
/// the HUD's plaques are painted with. A scene skins the controls the way it
/// lights the pitch ("dark mode for the game"); it never changes what a
/// control does. The day's are the app's own colours, as they always were.
public struct SceneSkin: Equatable, Sendable {
  public let id: String
  /// True for the day: the app keeps the system's light look and its own
  /// secondary text there.
  public var isDay: Bool { id == "day" }
  // the plates and cards
  public let ink, paper, drop, accent, onAccent, muted: SkinPaint
  /// A slider plate's header, its knob's face and grain.
  public let header, knob, grain: SkinPaint
  /// STAND's ground: where the thrower may stand (run) and the shaded rest (zone).
  public let standRun, standZone, standRing: SkinPaint
  /// A wrong word's chip (a placement refused) and its type.
  public let warn, onWarn: SkinPaint
  /// The dimming over the pitch behind a raised card.
  public let dim: SkinPaint
  // the meters (the web's HUD)
  public let face, faceShade, frame, ring, tick, power, powerDeep, release, releaseDeep, dead, over,
    hand, handCore, meterKnob, knobGrab, glow, prompt, promptInk: SkinPaint
  /// A raise end's number: lit, refused.
  public let endLit, endRefused: SkinPaint
  // the bursts (the web's BURST)
  public let flash, star, inner, kingInner, crown, word: SkinPaint
  public let chip: [SkinPaint]
  /// The king's flash inverts the screen in the day; a scene lights it instead.
  public var kingFlashInverts: Bool { isDay }

  /// The skin `id` draws with (SceneID.shown: an unknown scene is the day's).
  public static func of(_ id: String?) -> SceneSkin {
    switch SceneID.shown(id) {
    case "night": .night
    case "neon": .neon
    default: .day
    }
  }

  private static let dayInk = SkinPaint(r: 23 / 255, g: 20 / 255, b: 15 / 255)
  private static let hudInk = SkinPaint(r: 0.09, g: 0.078, b: 0.059)
  private static let dayPaper = SkinPaint(r: 251 / 255, g: 246 / 255, b: 234 / 255)
  private static let hudPaper = SkinPaint(r: 0.984, g: 0.965, b: 0.918)
  private static let dayKnob = SkinPaint(r: 0.95, g: 0.89, b: 0.75)

  /// The day: the app's colours before scenes, each where it was.
  public static let day = SceneSkin(
    id: "day", ink: dayInk, paper: dayPaper, drop: dayInk, accent: SkinPaint(r: 0.96, g: 0.73, b: 0.13),
    onAccent: dayInk, muted: SkinPaint(0x5b4a2c), header: SkinPaint(r: 0.93, g: 0.85, b: 0.68), knob: dayKnob,
    grain: SkinPaint(r: 0.62, g: 0.42, b: 0.22), standRun: SkinPaint(r: 0.718, g: 0.78, b: 0.604),
    standZone: SkinPaint(r: 0.914, g: 0.941, b: 0.839), standRing: SkinPaint(0xffffff),
    warn: SkinPaint(r: 0.86, g: 0.25, b: 0.22), onWarn: SkinPaint(0xffffff), dim: SkinPaint(0x000000, 0.26),
    face: hudPaper, faceShade: SkinPaint(0xeadfc8), frame: hudInk, ring: SkinPaint(r: 0.94, g: 0.91, b: 0.82),
    tick: hudInk, power: SkinPaint(r: 1, g: 0.478, b: 0.239), powerDeep: SkinPaint(0xc4521f),
    release: SkinPaint(r: 0.2, g: 0.714, b: 0.91), releaseDeep: SkinPaint(0x1f7fa8),
    dead: SkinPaint(0xc9bfa9), over: SkinPaint(0xe5484d), hand: SkinPaint(0x7a5530),
    handCore: SkinPaint(r: 0.6, g: 0.4, b: 0.2), meterKnob: dayKnob, knobGrab: SkinPaint(0xffffff),
    glow: SkinPaint(r: 1, g: 246 / 255, b: 200 / 255, a: 0.55), prompt: hudPaper, promptInk: hudInk,
    endLit: SkinPaint(r: 0.95, g: 0.72, b: 0.02), endRefused: SkinPaint(r: 0.79, g: 0.76, b: 0.69),
    flash: SkinPaint(0xfff6c8), star: hudInk, inner: SkinPaint(r: 1, g: 0.82, b: 0.25),
    kingInner: SkinPaint(r: 1, g: 0.82, b: 0.25), crown: SkinPaint(r: 1, g: 0.82, b: 0.25),
    word: SkinPaint(0xffffff), chip: [hudInk, SkinPaint(r: 0.6, g: 0.4, b: 0.2)])

  /// The night (the web's NIGHT.skin): moonlit blue plates, pale blue type.
  public static let night = SceneSkin(
    id: "night", ink: SkinPaint(0xdbe9ff), paper: SkinPaint(0x0d1424), drop: SkinPaint(0x000000, 0.55),
    accent: SkinPaint(0x9cc8ff), onAccent: SkinPaint(0x0d1424), muted: SkinPaint(0xa9bcdc), header: SkinPaint(0x1c2a45),
    knob: SkinPaint(0xc9dcff), grain: SkinPaint(0x8fb4e8), standRun: SkinPaint(0x24452f), standZone: SkinPaint(0x17263a),
    standRing: SkinPaint(0x0a101d), warn: SkinPaint(0xffb3b0), onWarn: SkinPaint(0x0d1424),
    dim: SkinPaint(0x000000, 0.4), face: SkinPaint(0x0d1424), faceShade: SkinPaint(0x152038), frame: SkinPaint(0xdbe9ff),
    ring: SkinPaint(0x1a2540), tick: SkinPaint(0xdbe9ff), power: SkinPaint(0xff7a3d), powerDeep: SkinPaint(0xc4521f),
    release: SkinPaint(0x33b6e8), releaseDeep: SkinPaint(0x1f7fa8), dead: SkinPaint(0x2c3754), over: SkinPaint(0xe5484d),
    hand: SkinPaint(0xb9d3ff), handCore: SkinPaint(0x8fb4e8), meterKnob: SkinPaint(0xe3edff), knobGrab: SkinPaint(0xffffff),
    glow: SkinPaint(r: 150 / 255, g: 205 / 255, b: 1, a: 0.5), prompt: SkinPaint(0x0d1424),
    promptInk: SkinPaint(0xdbe9ff), endLit: SkinPaint(0x9cc8ff), endRefused: SkinPaint(0x2c3754),
    flash: SkinPaint(0xd9f6ff), star: SkinPaint(0x0d1424), inner: SkinPaint(0xffd23f), kingInner: SkinPaint(0xffd23f),
    crown: SkinPaint(0xffd23f), word: SkinPaint(0xffffff), chip: [SkinPaint(0xdbe9ff), SkinPaint(0x8fb4e8)])

  /// The neon (the web's NEON.skin): thin light on black, the meter's bands coloured light.
  public static let neon = SceneSkin(
    id: "neon", ink: SkinPaint(0xc8fdff), paper: SkinPaint(0x02050a), drop: SkinPaint(r: 43 / 255, g: 228 / 255, b: 1, a: 0.35),
    accent: SkinPaint(0x5ff0ff), onAccent: SkinPaint(0x02050a), muted: SkinPaint(0x86c4cf), header: SkinPaint(0x06141c),
    knob: SkinPaint(0xc8fdff), grain: SkinPaint(0x5ff0ff), standRun: SkinPaint(0x06303a), standZone: SkinPaint(0x041821),
    standRing: SkinPaint(0x000000), warn: SkinPaint(0xff5c9d), onWarn: SkinPaint(0x02050a),
    dim: SkinPaint(0x000000, 0.45), face: SkinPaint(0x02050a), faceShade: SkinPaint(0x061019), frame: SkinPaint(0x5ff0ff),
    ring: SkinPaint(0x04121a), tick: SkinPaint(0x8ff4ff), power: SkinPaint(0xff9a4a), powerDeep: SkinPaint(0xff7a1f),
    release: SkinPaint(0x3fe0ff), releaseDeep: SkinPaint(0x16b8e6), dead: SkinPaint(0x10222c), over: SkinPaint(0xff4d6a),
    hand: SkinPaint(0xc8fdff), handCore: SkinPaint(0x5ff0ff), meterKnob: SkinPaint(0xe9feff), knobGrab: SkinPaint(0xffffff),
    glow: SkinPaint(r: 95 / 255, g: 240 / 255, b: 1, a: 0.55), prompt: SkinPaint(0x02050a),
    promptInk: SkinPaint(0xc8fdff), endLit: SkinPaint(0x5ff0ff), endRefused: SkinPaint(0x10222c),
    flash: SkinPaint(0xc8fdff), star: SkinPaint(0x5ff0ff), inner: SkinPaint(0x02050a), kingInner: SkinPaint(0x1a0410),
    crown: SkinPaint(0xff5c9d), word: SkinPaint(0xffffff),
    chip: [SkinPaint(0x5ff0ff), SkinPaint(0xff5c9d), SkinPaint(0xffc94a)])

  /// The type and the ground it is read on, for the 7:1 check: every pair a
  /// skin puts words on.
  public var textPairs: [(name: String, fg: SkinPaint, bg: SkinPaint)] {
    [
      ("ink on paper", ink, paper), ("muted on paper", muted, paper),
      ("on-accent on accent", onAccent, accent), ("ink on header", ink, header),
      ("prompt", promptInk, prompt), ("paper on ink", paper, ink),
      ("the meter's lines on its face", frame, face), ("its face on its lines", face, frame),
      ("on-accent on a lit end", onAccent, endLit), ("ink on a refused end", ink, endRefused),
      ("on-warn on warn", onWarn, warn),
    ]
  }
}
