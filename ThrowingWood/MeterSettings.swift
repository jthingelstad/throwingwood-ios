import KubbRenderer
import Observation
import SwiftUI

/// The throw's meter, this device's choice: the clock (the default, never
/// retired) or the linear meter, and the edge the linear meter sits at.
@MainActor @Observable final class MeterChoice {
  var kind: MeterKind {
    didSet { UserDefaults.standard.set(kind.rawValue, forKey: "pitch.meter") }
  }
  var side: MeterSide {
    didSet { UserDefaults.standard.set(side.rawValue, forKey: "pitch.meterSide") }
  }
  init() {
    let d = UserDefaults.standard
    kind = d.string(forKey: "pitch.meter").flatMap(MeterKind.init(rawValue:)) ?? .clock
    side = d.string(forKey: "pitch.meterSide").flatMap(MeterSide.init(rawValue:)) ?? .right
  }

  /// The meter a screen of `size` with `safe` insets shows: the linear one only
  /// where it has its room.
  func layout(bounds: CGRect, safe: UIEdgeInsets) -> MeterLayout {
    MeterLayout.make(
      kind: kind, side: side, bounds: bounds, safeTop: safe.top, safeBottom: safe.bottom,
      safeLeft: safe.left, safeRight: safe.right)
  }
}

/// Meter and Side in a menu (practice) or on a card (the match menus).
struct MeterSettings: View {
  @Bindable var meter: MeterChoice
  var card = false
  var body: some View {
    if card {
      VStack(alignment: .leading, spacing: 6) {
        Picker("Meter", selection: $meter.kind) {
          Text("Clock").tag(MeterKind.clock)
          Text("Linear").tag(MeterKind.linear)
        }.pickerStyle(.segmented).accessibilityLabel("Meter")
      }
    } else {
      Picker("Meter", selection: $meter.kind) {
        Text("Clock").tag(MeterKind.clock)
        Text("Linear").tag(MeterKind.linear)
      }.pickerStyle(.menu)
    }
  }
}

/// The room the linear meter takes at the screen's edge, for the plan's buttons.
struct MeterRoom: Equatable {
  var edge: Edge.Set = .trailing
  var width: CGFloat = 0
}

private struct MeterRoomKey: EnvironmentKey {
  static let defaultValue = MeterRoom()
}

extension EnvironmentValues {
  var meterRoom: MeterRoom {
    get { self[MeterRoomKey.self] }
    set { self[MeterRoomKey.self] = newValue }
  }
}
