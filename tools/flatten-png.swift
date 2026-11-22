// Rewrites each PNG with no alpha channel, as App Store Connect asks of screenshots
// ("Images can't include alpha channels or transparencies"): drawn onto opaque white.
//
//   swift tools/flatten-png.swift <file.png>...
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

for path in CommandLine.arguments.dropFirst() {
  let url = URL(fileURLWithPath: path)
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
  else { fatalError("cannot read \(path)") }
  let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
  guard let ctx = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { fatalError("cannot draw \(path)") }
  let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.fill(rect)
  ctx.draw(image, in: rect)
  guard let flat = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("cannot write \(path)") }
  CGImageDestinationAddImage(dest, flat, nil)
  guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(path)") }
}
