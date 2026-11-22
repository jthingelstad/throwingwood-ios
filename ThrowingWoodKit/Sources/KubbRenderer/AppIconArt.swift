import CoreGraphics
import Foundation
import simd

/// The app's icons (the owner, 2026-11-22: "a zoomed in profile of a Kubb King and
/// where you just see the top 1/3rd of the king with the crown framed in the icon.
/// Then we make alternative icons with every scene and its king image as well."):
/// each one is the game's own king, drawn by the pitch renderer in its scene, seen
/// close from the side so the crown fills the frame. `scripts/make-app-icons.sh`
/// writes them into the asset catalogue; the app's Settings offers them. docs/RENDER.md
/// "The app icon".
public enum AppIconArt {
  /// One icon, one scene. `asset` is its icon set in Assets.xcassets (the primary is
  /// `AppIcon`, the target's ASSETCATALOG_COMPILER_APPICON_NAME); `yaw` turns the
  /// king (degrees: 0 shows one face flat, more shows more of its shaded side).
  public struct Icon: Sendable, Equatable {
    public let scene: String
    public let asset: String
    var yaw = 30.0
  }

  /// Every icon, the primary first. A scene's icon is one line here, once the scene
  /// is drawn (`SceneID.drawn`) and named (`SceneID.shownNames`); `AppIconTests` checks
  /// the table against both and against the asset catalogue.
  public static let icons: [Icon] = [
    Icon(scene: "day", asset: primary),
    Icon(scene: "beach", asset: "AppIcon-Beach"),
    Icon(scene: "night", asset: "AppIcon-Camping"),
    Icon(scene: "neon", asset: "AppIcon-Techno"),
    Icon(scene: "minnesota", asset: "AppIcon-Minnesota"),
    Icon(scene: "tournament", asset: "AppIcon-Tournament"),
    Icon(scene: "bw", asset: "AppIcon-BlackWhite"),
  ]

  /// The primary icon's set, the one the store shows.
  public static let primary = "AppIcon"

  /// The scene's name a player sees (Park, Camping, Techno), from `SceneID.shownNames`.
  public static func name(_ icon: Icon) -> String {
    SceneID.shownNames.first { $0.id == icon.scene }?.name ?? icon.scene
  }

  /// What VoiceOver reads for its tile in Settings: "Park icon".
  public static func spokenName(_ icon: Icon) -> String { "\(name(icon)) icon" }

  /// The name `UIApplication.setAlternateIconName` takes: nil for the primary.
  public static func alternateName(_ icon: Icon) -> String? {
    icon.asset == primary ? nil : icon.asset
  }

  /// The icon a name from `UIApplication.alternateIconName` is: the primary for nil
  /// or a name this build no longer has.
  public static func icon(alternateName: String?) -> Icon {
    icons.first { alternateName != nil && $0.asset == alternateName } ?? icons[0]
  }

  /// The primary's appearances (the single-size format's `appearances`): any, dark
  /// and tinted. The alternates have the one look.
  public enum Variant: String, CaseIterable, Sendable {
    case any, dark, tinted
  }

  /// The icon at `pixels` square: opaque, no rounded corners (iOS masks it).
  public static func image(_ icon: Icon, variant: Variant = .any, pixels: Int = 1024) -> CGImage? {
    let gray = variant == .tinted
    guard
      let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    if gray {
      // greys only, on a dark ground (Apple's tinted icon): the dark look in grey, the
      // king the brightest thing, so he takes the tint
      guard let dark = image(icon, variant: .dark, pixels: pixels) else { return nil }
      ctx.draw(dark, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
      return ctx.makeImage()
    }
    draw(icon, variant: variant, in: ctx, pixels: Double(pixels))
    return ctx.makeImage()
  }

  /// The size the icon is laid out at, in points, before it is scaled to its pixels:
  /// the renderer's ink lines are drawn for a screen, so at this size its king's 3.4 pt
  /// outline is 27 px of a 1024 icon and still a line at 60 px on the home screen.
  static let layout = 128.0

  /// The king: upright on the pitch's middle, as the renderer stands him.
  static let king = Piece(id: "king", kind: "king", team: nil, x: 0, y: 4, z: 0.15, qw: 1, qx: 0, qy: 0, qz: 0)

  /// The camera: level with the crown's notches, close and long, so the frame holds the
  /// crown, his band and the line under it (the king's top 0.13 m of 0.30), the tips
  /// about a quarter of the way down against the sky and the horizon behind the notches.
  static func camera(_ icon: Icon) -> Camera {
    let a = icon.yaw * .pi / 180
    let d = 0.53
    let target = V3(king.x, king.y, 0.26)
    let eye = target + V3(sin(a) * d, -cos(a) * d, 0.004)
    return FreeCam.lookAt(
      px: eye.x, py: eye.y, pz: eye.z, tx: target.x, ty: target.y, tz: target.z, f: 1200, cx: 200, cy: 120)
  }

  /// Draws `icon` into a bottom-left-origin context of `pixels` square.
  static func draw(_ icon: Icon, variant: Variant, in ctx: CGContext, pixels: Double) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.translateBy(x: 0, y: pixels)
    ctx.scaleBy(x: pixels / layout, y: -pixels / layout)
    let size = CGSize(width: layout, height: layout)
    // a stake of its own far under the ground keeps the pitch's stakes out of the frame
    let hidden = Piece(id: "stake", kind: "stake", team: nil, x: 0, y: -50, z: -50, qw: 1, qx: 0, qy: 0, qz: 0)
    // the scene's own ground and kubb set (the engine's catalogue): Minnesota's king on
    // snow, the Tournament's in the USA colours, Techno's on the grid
    let entry = SceneID.entry(icon.scene)
    let scene = PitchScene(surface: entry.surface, set: entry.set, items: [king, hidden], look: icon.scene)
    let camera = camera(icon)
    PitchRenderer.draw(in: ctx, size: size, camera: camera, scene: scene)
    guard variant == .dark else { return }
    // the dark look: the same picture with its world taken to dusk and the king drawn
    // again over it, as bright as by day
    ctx.setFillColor(color(0x06101c, 0.8))
    ctx.fill(CGRect(origin: .zero, size: size).insetBy(dx: -2, dy: -2))
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    let p = Painter(ctx: ctx, projection: scene.projection(size, camera))
    p.pieces(scene, paint: .of(SceneID.shown(icon.scene)), before: { _ in })
  }
}
