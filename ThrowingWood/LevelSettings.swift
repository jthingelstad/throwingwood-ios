import KubbRenderer
import SwiftUI

/// The player's own throw level, Beginner, Club or Pro: a device setting, set
/// here only (Jamie, 2026-11-20: "Yes this is a device/user setting... not a
/// per game setting."). Settings and the menus show it beside Sound and the
/// meter; a set-up screen shows `LevelLine` instead and never asks.
struct LevelSetting: View {
  @Bindable var model: GameModel
  var card = true
  private var choices: [[String]] {
    model.offline?.options.levels.map { [$0, $0.capitalized] } ?? []
  }
  var body: some View {
    if card {
      VStack(alignment: .leading, spacing: 6) {
        MenuRow("Your level") { picker.pickerStyle(.segmented) }
        // the engine takes the thrower's level for each throw (ThrowLevel.swift)
        if model.screen == .menu {
          Text("A change applies from your next throw.").font(.caption)
        }
      }
    } else {
      picker.pickerStyle(.menu)
    }
  }
  private var picker: some View {
    Picker("Your level", selection: $model.throwLevel) {
      ForEach(choices, id: \.self) { c in Text(c[1]).tag(c[0]) }
    }.accessibilityLabel("Your level")
  }
}

/// A set-up screen's level: what it is and the way to Settings, no picker.
struct LevelLine: View {
  let model: GameModel
  var body: some View {
    HStack(spacing: 4) {
      Text(ThrowLevel.line(model.throwLevel))
      Button(action: model.openSettings) { Text("Change in Settings").underline() }
        .accessibilityHint("Your level is set in Settings")
    }.font(.subheadline)
  }
}

/// Settings: the device's own choices, reached from a set-up screen's level line.
struct SettingsCard: View {
  @Bindable var model: GameModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Settings").font(displayFont(37))
      LevelSetting(model: model)
      FeedbackSettings(feedback: model.feedback, card: true)
      MeterSettings(meter: model.meter, card: true)
      Button("BACK") { model.screen = model.settingsReturn }
        .buttonStyle(WoodButton(accent: true))
    }.frame(maxWidth: 360, alignment: .leading).modifier(Plate(inset: 20)).padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity).modifier(FitOrScroll())
  }
}
