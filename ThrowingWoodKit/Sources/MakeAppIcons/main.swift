// Writes the app's icons into its asset catalogue from the game's own king drawing
// (KubbRenderer's AppIconArt): one icon set per entry of `AppIconArt.icons`, each a
// single 1024 px PNG, the primary with its dark and tinted appearances.
//
//   swift run --package-path ThrowingWoodKit make-app-icons [<Assets.xcassets>]
//
// (scripts/make-app-icons.sh). With no path it writes ThrowingWood/Assets.xcassets
// beside the package. Icon sets it does not make are left alone.
import CoreGraphics
import Foundation
import ImageIO
import KubbRenderer
import UniformTypeIdentifiers

let here = URL(fileURLWithPath: #filePath)
let catalogue =
  CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
  ?? here.deletingLastPathComponent().appending(path: "../../../ThrowingWood/Assets.xcassets").standardized

func png(_ image: CGImage, _ url: URL) throws {
  guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    throw CocoaError(.fileWriteUnknown)
  }
  CGImageDestinationAddImage(out, image, nil)
  guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
}

func json(_ value: Any) throws -> Data {
  var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  data.append(0x0a)
  return data
}

for icon in AppIconArt.icons {
  let set = catalogue.appending(path: "\(icon.asset).appiconset")
  try? FileManager.default.removeItem(at: set)
  try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
  let variants: [AppIconArt.Variant] = icon.asset == AppIconArt.primary ? AppIconArt.Variant.allCases : [.any]
  var images: [[String: Any]] = []
  for variant in variants {
    let file = variant == .any ? "\(icon.asset).png" : "\(icon.asset)-\(variant.rawValue).png"
    guard let image = AppIconArt.image(icon, variant: variant) else {
      FileHandle.standardError.write(Data("could not draw \(icon.asset) \(variant)\n".utf8))
      exit(1)
    }
    try png(image, set.appending(path: file))
    var entry: [String: Any] = ["filename": file, "idiom": "universal", "platform": "ios", "size": "1024x1024"]
    if variant != .any {
      entry["appearances"] = [["appearance": "luminosity", "value": variant.rawValue]]
    }
    images.append(entry)
  }
  try json(["images": images, "info": ["author": "make-app-icons", "version": 1]])
    .write(to: set.appending(path: "Contents.json"))
  print("\(icon.asset): \(AppIconArt.name(icon)), \(variants.map(\.rawValue).joined(separator: ", "))")
}
