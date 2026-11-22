import KubbRenderer
import SwiftUI

/// A set-up screen's name and the way to Settings, no picker. A device with no
/// name yet is asked for one here, once (`NameField`); after that the name is
/// changed in Settings. There is no level for the player to set: from engine 0.13
/// every person throws on one meter and a level is the computer's alone (kubb-engine
/// docs/notes/throw.md "The person's meter"), so none is kept or sent.
struct PlayerLine: View {
  let model: GameModel
  /// Whether this screen asks for the name: decided when it appears, so the field
  /// stays while the first letters go in.
  @State private var asks: Bool?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if asks ?? (PlayerName.shown(model.name) == nil) { NameField(model: model) }
      if asks != true, let name = PlayerName.shown(model.name) {
        HStack(spacing: 4) {
          Text(name)
          Button(action: model.openSettings) { Text("Change in Settings").underline() }
            .accessibilityHint("Your name is set in Settings")
        }.font(.subheadline)
      }
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
        model.nameDraft = String(value.prefix(limit))
      }
      .onSubmit(commit)
      .onChange(of: editing) { _, focused in if !focused { commit() } }
      .onDisappear(perform: commit)
  }
  private func commit() {
    model.nameDraft = draft
    model.commitName()
  }
}

/// Settings: the device's own choices in one place (the owner's scopes: name,
/// sound, haptics, meter and its side), reached from home, a set-up screen's line, the
/// match and pitch menus and the practice menu. Nothing about one game is here: those
/// are the game's options (the solo options, the practice menu, the lobby).
struct SettingsCard: View {
  @Bindable var model: GameModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Settings").font(displayFont(37))
      MenuRow("Your name") { NameField(model: model) }
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
      .accessibilityHint("Your name, sound, haptics and meter")
  }
}
