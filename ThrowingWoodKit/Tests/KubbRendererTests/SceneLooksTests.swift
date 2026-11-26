import CoreGraphics
import Foundation
import ImageIO
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// Every scene of the engine's catalogue drawn on a real pitch: the thrower's view upright
/// and on its side, the side view (ARC open) and the watcher's wide view.
/// `SCENE_LOOKS_OUT=<dir>` writes each picture (`<scene>-<view>.png`) for a look at it.
@MainActor struct SceneLooksTests {
  static let upright = CGSize(width: 390, height: 844), side = CGSize(width: 844, height: 390)

  static func picture(_ size: CGSize, scale: Double = 2, _ draw: (CGContext) -> Void) -> CGContext {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: Double(h))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx)
    return ctx
  }
  static func keep(_ ctx: CGContext, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["SCENE_LOOKS_OUT"], let image = ctx.makeImage() else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let dest = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
    if let w = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil) {
      CGImageDestinationAddImage(w, image, nil)
      CGImageDestinationFinalize(w)
    }
  }
  static func pixels(_ ctx: CGContext) -> [UInt8] {
    Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * ctx.height))
  }

  /// A match in `scene` with its first hand-off closed, at the aim.
  static func match(_ scene: String, surface: String? = nil) throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    var chosen = app.options.choosing(scene: scene, app.options.withoutTogo)
    if let surface { chosen["surface"] = surface }
    try app.startSolo(name: "Mighty Maple", selections: chosen, save: nil)
    app.dismissHandoff()
    return app
  }

  static func draw(_ app: PitchSession, _ size: CGSize, look: String? = nil) -> CGContext {
    picture(size) { ctx in
      PitchRenderer.draw(
        in: ctx, size: size, camera: app.shownCamera, scene: app.scene, look: look ?? app.scene.look,
        effects: app.effects, time: app.lookTime)
    }
  }

  /// Each scene's views, kept for review; each differs from the day's.
  @Test(arguments: SceneID.catalogue.map(\.id))
  func everySceneDrawsEveryView(scene: String) throws {
    let app = try Self.match(scene)
    #expect(app.scene.look == scene)
    let aim = Self.draw(app, Self.upright)
    let wide = Self.draw(app, Self.side)
    Self.keep(aim, "\(scene)-aim")
    Self.keep(wide, "\(scene)-aim-landscape")
    if scene != "day" {
      let day = Self.pixels(Self.draw(app, Self.upright, look: "day"))
      let mine = Self.pixels(aim)
      var differ = 0
      for i in stride(from: 0, to: mine.count, by: 4) where mine[i] != day[i] || mine[i + 1] != day[i + 1] { differ += 1 }
      #expect(Double(differ) / Double(mine.count / 4) > 0.2, "\(scene) looks like the day")
    }
    try app.togglePlan()
    for _ in 0..<60 { try app.tick(1.0 / 60) }
    Self.keep(Self.draw(app, Self.upright), "\(scene)-side")
    try app.togglePlan()
    for _ in 0..<60 { try app.tick(1.0 / 60) }
    #expect(try app.watchWide(size: Self.side, safe: ScreenInsets()))
    Self.keep(Self.draw(app, Self.side), "\(scene)-wide")
  }

  /// Black & White draws every pixel pure black or pure white, on every surface it allows.
  @Test(arguments: ["grass", "sand", "snow"])
  func blackAndWhiteIsOneBit(surface: String) throws {
    let app = try Self.match("bw", surface: surface)
    #expect(app.scene.surface.rawValue == surface)
    let ctx = Self.draw(app, Self.upright)
    Self.keep(ctx, "bw-\(surface)")
    let px = Self.pixels(ctx)
    var grey = 0
    for i in stride(from: 0, to: px.count, by: 4) {
      let (r, g, b) = (px[i], px[i + 1], px[i + 2])
      if !((r == 0 && g == 0 && b == 0) || (r == 255 && g == 255 && b == 255)) { grey += 1 }
    }
    #expect(grey == 0, "\(grey) pixels neither black nor white")
  }

  /// The pitch's lines hold 3:1 (WCAG's for a graphical object) on the pitch and its
  /// stripes in every daylight scene: Beach's navy rope 5.2:1 on the sand, Minnesota's blue
  /// 4.9:1 on the snow, the Tournament's white 3.1:1 on its deeper grass.
  @Test func theLinesHoldTheirContrast() {
    for look in Daylit.looks.sorted() {
      let e = SceneID.entry(look)
      let g = Daylit.ground(look, e.surface)
      for (name, bg) in [("pitch", g.pitch), ("stripe", g.stripe)] {
        let r = SkinPaint.contrast(SkinPaint(g.line), SkinPaint(bg))
        #expect(r >= 3, "\(look) line on \(name): \(r)")
      }
    }
  }

  /// The tournament's neighbours are drawn from their data alone: other pieces, another
  /// picture.
  @Test func theNeighboursAreData() throws {
    let app = try Self.match("tournament")
    #expect(try app.watchWide(size: Self.side, safe: ScreenInsets()))
    func draw(_ list: [NeighbourPitch]) -> [UInt8] {
      Self.pixels(Self.picture(Self.side) { ctx in
        let p = Painter(ctx: ctx, projection: app.scene.projection(Self.side, app.shownCamera))
        p.neighbours(list)
      })
    }
    let fixed = Tournament.neighbours
    var moved = fixed
    moved[0] = NeighbourPitch(dx: fixed[0].dx, dy: fixed[0].dy, pieces: Array(fixed[0].pieces.prefix(6)), score: (1, 1))
    #expect(draw(fixed) != draw(moved))
    #expect(draw(fixed) == draw(fixed))
  }
}
