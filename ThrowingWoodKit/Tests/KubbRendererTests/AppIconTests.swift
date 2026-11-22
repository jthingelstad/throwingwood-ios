import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import KubbRenderer

/// The app's icons (AppIconArt): one per scene this build draws, each an icon set in the
/// asset catalogue written by `make-app-icons`, the primary with its dark and tinted looks.
struct AppIconTests {
  private var catalogue: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../ThrowingWood/Assets.xcassets").standardized
  }

  /// Every scene the app draws has its icon, and no icon is for a scene it does not:
  /// the day and `SceneID.drawn`, in the order of `SceneID.shownNames`.
  @Test func oneIconPerSceneThatExists() {
    let scenes = SceneID.shownNames.map(\.id).filter { $0 == "day" || SceneID.drawn.contains($0) }
    #expect(AppIconArt.icons.map(\.scene) == scenes)
    #expect(AppIconArt.icons.first?.scene == "day")
    #expect(AppIconArt.icons.first?.asset == AppIconArt.primary)
    #expect(Set(AppIconArt.icons.map(\.asset)).count == AppIconArt.icons.count)
    #expect(
      AppIconArt.icons.map(AppIconArt.name)
        == ["Park", "Beach", "Camping", "Techno", "Minnesota", "Tournament", "Black & White"])
    #expect(AppIconArt.spokenName(AppIconArt.icons[0]) == "Park icon")
    #expect(AppIconArt.spokenName(AppIconArt.icons[6]) == "Black & White icon")
  }

  /// The name given to `setAlternateIconName` is the icon's set (nil for the primary),
  /// and the name iOS reports back finds the same icon; an unknown one is the primary.
  @Test func alternateNamesMapToTheirAssets() {
    #expect(AppIconArt.alternateName(AppIconArt.icons[0]) == nil)
    for icon in AppIconArt.icons {
      #expect(AppIconArt.icon(alternateName: AppIconArt.alternateName(icon)) == icon)
    }
    #expect(
      AppIconArt.icons.dropFirst().map(AppIconArt.alternateName)
        == [
          "AppIcon-Beach", "AppIcon-Camping", "AppIcon-Techno", "AppIcon-Minnesota", "AppIcon-Tournament",
          "AppIcon-BlackWhite",
        ])
    #expect(AppIconArt.icon(alternateName: nil).scene == "day")
    #expect(AppIconArt.icon(alternateName: "AppIcon-Gone").scene == "day")
    #expect(AppIconArt.icon(alternateName: "AppIcon").scene == "day")
  }

  /// The catalogue holds exactly the table's icon sets, each a single 1024 image (the
  /// primary also dark and tinted), opaque, and the tinted one in greys.
  @Test func theCatalogueMatchesTheTable() throws {
    let sets = try FileManager.default.contentsOfDirectory(atPath: catalogue.path)
      .filter { $0.hasSuffix(".appiconset") }.sorted()
    #expect(sets == AppIconArt.icons.map { "\($0.asset).appiconset" }.sorted())
    for icon in AppIconArt.icons {
      let set = catalogue.appending(path: "\(icon.asset).appiconset")
      let data = try Data(contentsOf: set.appending(path: "Contents.json"))
      let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      let images = try #require(json["images"] as? [[String: Any]])
      let looks = images.map { ($0["appearances"] as? [[String: String]])?.first?["value"] ?? "any" }
      #expect(looks == (icon.asset == AppIconArt.primary ? ["any", "dark", "tinted"] : ["any"]), "\(icon.asset)")
      for (image, look) in zip(images, looks) {
        #expect(image["size"] as? String == "1024x1024")
        #expect(image["idiom"] as? String == "universal")
        let file = try #require(image["filename"] as? String)
        let png = try #require(load(set.appending(path: file)), "\(file)")
        #expect(png.width == 1024 && png.height == 1024, "\(file)")
        let alpha = png.alphaInfo
        #expect(alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst, "\(file) is opaque")
        if look == "tinted" { #expect(png.colorSpace?.model == .monochrome, "\(file) is grey") }
      }
    }
  }

  /// The committed icons are what the generator draws today: a change to the king or
  /// to AppIconArt without `scripts/make-app-icons.sh` fails here. Compared small, so a
  /// different Mac's antialiasing does not count.
  @Test func theCommittedIconsAreFresh() throws {
    for icon in AppIconArt.icons {
      let set = catalogue.appending(path: "\(icon.asset).appiconset")
      let file = set.appending(path: "\(icon.asset).png")
      let committed = try #require(load(file))
      let drawn = try #require(AppIconArt.image(icon, pixels: 256))
      let a = try #require(thumbnail(committed)), b = try #require(thumbnail(drawn))
      let diff = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
      #expect(diff < 4, "\(icon.asset) differs from a fresh drawing by \(diff)")
    }
  }

  /// The art: the crown in the frame's upper part against its scene's sky, the king's
  /// body across the middle, opaque at any size.
  @Test func theKingFillsTheFrame() throws {
    let day = try #require(AppIconArt.image(AppIconArt.icons[0], pixels: 128))
    let px = try #require(thumbnail(day, side: 128))
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let i = (y * 128 + x) * 4
      return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
    // the day's sky above the crown's tips
    let sky = rgb(64, 6)
    #expect(abs(sky.0 - 0xd8) < 12 && abs(sky.1 - 0xec) < 12 && abs(sky.2 - 0xf2) < 12)
    // the king's wood under them, on the centre line
    let wood = rgb(40, 70)
    #expect(wood.0 > 200 && wood.1 > 170 && wood.2 > 120 && wood.2 < 200, "\(wood)")
    #expect(AppIconArt.image(AppIconArt.icons[1], pixels: 64)?.alphaInfo == .noneSkipLast)
  }

  private func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// RGBA bytes of `image` drawn at `side` square.
  private func thumbnail(_ image: CGImage, side: Int = 32) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let ctx = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    return ok ? bytes : nil
  }
}
