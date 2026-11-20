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

extension View {
  /// The skin's secondary words: the system's on the day, as before; the
  /// scene's muted colour in a scene (7:1 on its paper).
  func mutedText() -> some View { modifier(MutedText()) }
}
private struct MutedText: ViewModifier {
  func body(content: Content) -> some View {
    if skin.isDay {
      content.foregroundStyle(.secondary)
    } else {
      content.foregroundStyle(Color(skin.muted))
    }
  }
}
