import CoreGraphics
import Foundation

/// Soft light for the scenes (the web's src/render/glow.js): a round glow
/// sprite per colour, drawn once and stamped, so a frame full of stardust or
/// halos costs no gradients.
enum Glow {
  private static let size = 64
  nonisolated(unsafe) private static var sprites: [Int: CGImage] = [:]
  private static let lock = NSLock()

  /// A disc that falls off to nothing at its rim; `core`: a white-hot centre.
  static func sprite(_ rgb: Int, core: Bool) -> CGImage? {
    let key = rgb << 1 | (core ? 1 : 0)
    lock.lock()
    defer { lock.unlock() }
    if let s = sprites[key] { return s }
    guard
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let gradient = CGGradient(
        colorsSpace: space,
        colors: [
          core ? color(0xffffff) : color(rgb), color(rgb, 0.85), color(rgb, 0.22), color(rgb, 0),
        ] as CFArray, locations: [0, core ? 0.18 : 0.25, 0.55, 1])
    else { return nil }
    let c = CGPoint(x: Double(size) / 2, y: Double(size) / 2)
    ctx.drawRadialGradient(
      gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: Double(size) / 2,
      options: [])
    let image = ctx.makeImage()
    sprites[key] = image
    return image
  }

  /// A glow of radius rx by ry (points) at (x, y), alpha a, in the context's
  /// current blend mode.
  static func draw(
    _ ctx: CGContext, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double, _ rgb: Int,
    _ a: Double, core: Bool = false
  ) {
    guard a > 0.003, rx > 0, ry > 0, let s = sprite(rgb, core: core) else { return }
    ctx.setAlpha(a)
    ctx.draw(s, in: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
    ctx.setAlpha(1)
  }
}
