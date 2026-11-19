import SwiftUI
import UIKit

/// An iPad window's controls (close, minimise, full screen) sit in its top
/// leading corner, and an app built for iPadOS 26 is given no safe area for
/// them: the turn rail would be under them. The safe area adapted to the
/// window's corners (`UIView.LayoutRegion.safeArea(cornerAdaptation: .vertical)`)
/// is the room clear of them; its extra at the top becomes the root view
/// controller's additional safe area, so the SwiftUI cards and the board's
/// UIKit HUD read one safe area. Full screen and every iPhone have no such
/// corner, so nothing moves there.
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
      guard let root = window?.rootViewController, let view = root.view else { return }
      let added = root.additionalSafeAreaInsets.top
      // the window's own safe area, without what was added here
      let own = view.safeAreaInsets.top - added
      let clear = view.edgeInsets(for: .safeArea(cornerAdaptation: .vertical)).top
      let want = max(0, (clear - own).rounded())
      if abs(want - added) > 0.5 { root.additionalSafeAreaInsets.top = want }
    }
  }
}
