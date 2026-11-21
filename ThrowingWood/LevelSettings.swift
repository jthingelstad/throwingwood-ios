import KubbRenderer
import SwiftUI

/// The player's own throw level, Beginner, Club or Pro: a device setting, set
/// here only (Jamie, 2026-11-20: "Yes this is a device/user setting... not a
/// per game setting."). Settings shows it beside Sound and the meter; a set-up
/// screen shows `LevelLine` instead and never asks.
struct LevelSetting: View {
  @Bindable var model: GameModel
  private var choices: [[String]] {
    model.offline?.options.levels.map { [$0, $0.capitalized] } ?? []
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      MenuRow("Your level") {
        Picker("Your level", selection: $model.throwLevel) {
          ForEach(choices, id: \.self) { c in Text(c[1]).tag(c[0]) }
        }.pickerStyle(.segmented).accessibilityLabel("Your level")
      }
      // the engine takes the thrower's level for each throw (ThrowLevel.swift)
      if [.menu, .match].contains(model.settingsReturn) {
        Text("A change applies from your next throw.").font(.caption)
      }
    }
  }
}

/// A set-up screen's name and level: what they are and the way to Settings, no
/// picker. A device with no name yet is asked for one here, once (`NameField`);
/// after that the name is changed in Settings.
struct LevelLine: View {
  let model: GameModel
  /// Whether this screen asks for the name: decided when it appears, so the field
  /// stays while the first letters go in.
  @State private var asks: Bool?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if asks ?? (PlayerName.shown(model.name) == nil) { NameField(model: model) }
      HStack(spacing: 4) {
        if asks != true, let name = PlayerName.shown(model.name) {
          Text("\(name) · \(ThrowLevel.line(model.throwLevel))")
        } else {
          Text(ThrowLevel.line(model.throwLevel))
        }
        Button(action: model.openSettings) { Text("Change in Settings").underline() }
          .accessibilityHint("Your name and level are set in Settings")
      }.font(.subheadline)
    }.onAppear { if asks == nil { asks = PlayerName.shown(model.name) == nil } }
  }
}

/// The player's name as it is typed, kept on the device when the field is let go or
/// sent (a pitch hears it then, not at each letter).
struct NameField: View {
  let model: GameModel
  @State private var draft = ""
  @FocusState private var editing: Bool
  var body: some View {
    TextField("Your name", text: $draft).textFieldStyle(.roundedBorder).focused($editing)
      .accessibilityLabel("Your name").submitLabel(.done)
      .onAppear { draft = model.name }
      .onChange(of: draft) { _, value in
        let limit = model.offline?.options.nameLimit ?? value.count
        if value.count > limit { draft = String(value.prefix(limit)) }
      }
      .onSubmit(commit)
      .onChange(of: editing) { _, focused in if !focused { commit() } }
      .onDisappear(perform: commit)
  }
  private func commit() {
    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if typed != model.name { model.name = typed }
  }
}

/// Settings: the device's own choices in one place (the owner's scopes: name, level,
/// sound, haptics, meter and its side), reached from home, a set-up screen's line, the
/// match and pitch menus and the practice menu. Nothing about one game is here: those
/// are the game's options (the solo options, the practice menu, the lobby).
struct SettingsCard: View {
  @Bindable var model: GameModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Settings").font(displayFont(37))
      MenuRow("Your name") { NameField(model: model) }
      LevelSetting(model: model)
      FeedbackSettings(feedback: model.feedback)
      MeterSettings(meter: model.meter)
      Button("BACK") { model.screen = model.settingsReturn }
        .buttonStyle(WoodButton(accent: true))
    }.frame(maxWidth: 360, alignment: .leading).modifier(Plate(inset: 20)).padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity).modifier(FitOrScroll())
  }
}

/// The way to Settings from a menu card.
struct SettingsButton: View {
  let model: GameModel
  var body: some View {
    Button("SETTINGS", action: model.openSettings)
      .accessibilityHint("Your name, level, sound, haptics and meter")
  }
}
