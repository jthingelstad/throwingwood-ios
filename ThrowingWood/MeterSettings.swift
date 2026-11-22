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

/// Meter and Side on the Settings card. Side is always shown, as on the web: on a
/// wide screen it moves the clock too.
struct MeterSettings: View {
  @Bindable var meter: MeterChoice
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      FormRow("Meter") { full in
        Segmented(
          label: "Meter", choices: [(MeterKind.clock, "Clock"), (MeterKind.linear, "Linear")],
          value: $meter.kind, full: full)
      }
      if meter.kind == .linear && !shown(.linear) {
        note("This screen is too short for the linear meter, so the clock is shown.")
      }
      // Jamie, 2026-11-19: "Left and right handed folks may want it on one side or the other"
      FormRow("Meter side") { full in
        Segmented(
          label: "Meter side", choices: [(MeterSide.left, "Left"), (MeterSide.right, "Right")],
          value: $meter.side, full: full)
      }
      // a tall screen's clock is in the middle: the side is the linear meter's there
      if !screen.wide && !shown(.linear) {
        note("On a screen held upright the clock stays in the middle; the side moves the linear meter.")
      }
    }
  }

  /// Whether this screen shows the meter of `kind` (the linear one only where it has its room).
  private func shown(_ kind: MeterKind) -> Bool {
    guard screen.size.width > 0 else { return kind == meter.kind }
    let s = screen.safe
    let m = MeterLayout.make(
      kind: meter.kind, side: meter.side, bounds: CGRect(origin: .zero, size: screen.size),
      safeTop: s.top, safeBottom: s.bottom, safeLeft: s.left, safeRight: s.right)
    return (m.linear != nil) == (kind == .linear)
  }

  private func note(_ words: String) -> some View {
    Text(words).helperText()
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

/// The whole screen (safe area included) and its safe area: a phone on its side
/// lays the match out on `WideLayout`'s frames, which are in these coordinates.
struct ScreenGeometry: Equatable {
  var size = CGSize.zero
  var safe = ScreenInsets()
  var wide: Bool { WideLayout.isWide(size) }
}

private struct ScreenGeometryKey: EnvironmentKey {
  static let defaultValue = ScreenGeometry()
}

extension EnvironmentValues {
  var screenGeometry: ScreenGeometry {
    get { self[ScreenGeometryKey.self] }
    set { self[ScreenGeometryKey.self] = newValue }
  }
}
