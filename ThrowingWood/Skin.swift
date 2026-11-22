import KubbRenderer
import Observation
import SwiftUI
import UIKit

/// The scene's skin on the screen now (SceneSkin): every plate, card, slider and
/// HUD reads its colours here, so a scene skins the controls the way it lights
/// the pitch. GameView sets it from `GameModel.shownScene`; SwiftUI views that
/// read it are drawn again when it changes.
@MainActor @Observable final class SkinStore {
  static let shared = SkinStore()
  private(set) var skin = SceneSkin.day
  func use(_ id: String) {
    let next = SceneSkin.of(id)
    if next != skin { skin = next }
  }
}

@MainActor var skin: SceneSkin { SkinStore.shared.skin }

extension Color {
  init(_ p: SkinPaint) { self.init(.sRGB, red: p.r, green: p.g, blue: p.b, opacity: p.a) }
}
extension UIColor {
  convenience init(_ p: SkinPaint) { self.init(red: p.r, green: p.g, blue: p.b, alpha: p.a) }
}

/// The dimming behind a raised card (the skin's `dim`): ink at half strength, or in Black &
/// White the Playdate's 50% checker in black, every pixel black or clear, never grey.
struct SkinDim: View {
  /// The checker's tile: two by two points, black on the diagonal, clear off it.
  private static let tile: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { c in
    UIColor.black.setFill()
    c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    c.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
  }
  var body: some View {
    if skin.mono {
      Rectangle().fill(ImagePaint(image: Image(uiImage: Self.tile).interpolation(.none)))
    } else {
      Color(skin.dim)
    }
  }
}
