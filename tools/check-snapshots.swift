// Compare actual app screenshots in tiles at one sample per screen point.
import CoreGraphics
import Foundation
import ImageIO

enum SnapshotError: Error {
  case image(String)
  case size(String)
  case tile(String, Int, Int, Double)
}

func pixels(_ url: URL) throws -> (Int, Int, [UInt8]) {
  // the review iPads are @2x, the phones @3x
  let scale = url.lastPathComponent.hasPrefix("ipad-") ? 2 : 3
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { throw SnapshotError.image(url.lastPathComponent) }
  let w = image.width / scale
  let h = image.height / scale
  var data = [UInt8](repeating: 0, count: w * h * 4)
  try data.withUnsafeMutableBytes { bytes in
    guard
      let ctx = CGContext(
        data: bytes.baseAddress, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw SnapshotError.image(url.lastPathComponent) }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  return (w, h, data)
}
let args = CommandLine.arguments
for name in args.dropFirst(3) {
  let (w, h, a) = try pixels(URL(fileURLWithPath: args[1]).appending(path: name))
  let (W, H, b) = try pixels(URL(fileURLWithPath: args[2]).appending(path: name))
  guard W == w && H == h else { throw SnapshotError.size(name) }
  for y in stride(from: 0, to: h, by: 24) {
    for x in stride(from: 0, to: w, by: 24) {
      let height = min(24, h - y)
      let width = min(24, w - x)
      var error = 0
      var channels = 0
      for j in y..<(y + height) {
        for i in x..<(x + width) {
          // The simulator fades the home indicator and composites the Pro Max
          // camera cutout independently of the app. Ignore only their bounds.
          let center = abs(i - w / 2)
          if center <= 84 && j >= h - 18 { continue }
          if w == 440 && center <= 67 && (9...54).contains(j) { continue }
          channels += 3
          let p = 4 * (j * w + i)
          for c in 0..<3 { error += abs(Int(a[p + c]) - Int(b[p + c])) }
        }
      }
      let mean = Double(error) / Double(max(channels, 1))
      guard mean < 4 else { throw SnapshotError.tile(name, x, y, mean) }
    }
  }
}
print("\(args.count-3) app snapshots matched")
