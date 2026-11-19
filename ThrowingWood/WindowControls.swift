import SwiftUI
import UIKit

/// An iPad window's controls (close, minimise, full screen) sit in its top
/// leading corner, and an app built for iPadOS 26 is given no safe area for
/// them: the turn rail would be under them. The safe area adapted to the
/// window's corners (`UIView.LayoutRegion.safeArea(cornerAdaptation: .vertical)`)
/// is the room clear of them; its extra at the top becomes the root view
/// controller's additional safe area, so the SwiftUI cards and the board's
/// UIKit HUD read one safe area. Only an iPad window smaller than the screen
/// has them: full screen and every iPhone add nothing (there the corner-adapted
/// safe area is the display's own rounded corners, which the layout already keeps).
struct WindowControlsRoom: UIViewRepresentable {
  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ view: Probe, context: Context) {}

  final class Probe: UIView {
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
      super.layoutSubviews()
      update()
    }
    override func safeAreaInsetsDidChange() {
      super.safeAreaInsetsDidChange()
      update()
    }
    private func update() {
      guard let window, let root = window.rootViewController, let view = root.view else { return }
      let added = root.additionalSafeAreaInsets.top
      var want: CGFloat = 0
      // only an iPad's window short of the screen has the controls: elsewhere the
      // corner-adapted safe area is the display's own rounded corners
      let screen = window.windowScene?.screen.bounds.size ?? window.bounds.size
      let windowed =
        traitCollection.userInterfaceIdiom == .pad
        && (window.bounds.width < screen.width - 0.5 || window.bounds.height < screen.height - 0.5)
      if windowed {
        // the window's own safe area, without what was added here
        let own = view.safeAreaInsets.top - added
        let clear = view.edgeInsets(for: .safeArea(cornerAdaptation: .vertical)).top
        want = max(0, (clear - own).rounded())
      }
      if abs(want - added) > 0.5 { root.additionalSafeAreaInsets.top = want }
    }
  }
}
