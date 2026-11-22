import KubbRenderer
import SwiftUI

/// The name row (`NameRowModel`; the web's src/ui/name-row.js): the name and SHUFFLE,
/// then each word's picker and its KEEP, in that order for VoiceOver too. Native
/// controls: a menu picker per word listing every word the slot can take. Each word and
/// the name fit the widest name the engine can make (`NameFitTests`); at the largest
/// text sizes the words go under each other.
struct NameRowView: View {
  @Bindable var row: NameRowModel
  /// At the accessibility text sizes the name goes over SHUFFLE and each picker over
  /// its KEEP, so no word is broken.
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if type.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) { name; shuffle }
        VStack(alignment: .leading, spacing: 8) { words }
      } else {
        HStack(spacing: 8) {
          name
          Spacer(minLength: 4)
          shuffle
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { words }
          VStack(alignment: .leading, spacing: 6) { words }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(row.label)
    .onChange(of: row.announcement) { _, said in
      if let said { AccessibilityNotification.Announcement(said).post() }
    }
  }

  private var name: some View {
    Text(row.text).font(.headline).fixedSize(horizontal: false, vertical: true)
  }

  private var shuffle: some View {
    Button("SHUFFLE") { row.shuffle() }.buttonStyle(WoodButton())
      .lineLimit(1).minimumScaleFactor(0.5)
      .accessibilityLabel(row.shuffleLabel)
  }

  @ViewBuilder private var words: some View {
    if let prefix = row.prefix { Text(prefix).font(.body.weight(.semibold)) }
    ForEach(Array(row.parts.words.enumerated()), id: \.offset) { slot, word in
      // a menu of every word the slot can take, the word shown ticked; VoiceOver reads
      // "Your name, first word" and the word as its value
      let picker = Menu {
        Picker(row.pickerLabel(slot), selection: Binding(get: { word }, set: { row.pick(slot, $0) })) {
          ForEach(row.choices(slot), id: \.self) { Text($0).tag($0) }
        }
      } label: {
        HStack(spacing: 4) {
          Text(word)
          Image(systemName: "chevron.up.chevron.down").font(.caption)
        }
      }
      .accessibilityLabel(row.pickerLabel(slot))
      .accessibilityValue(word)
      let keep = Button(row.lockTitle(slot)) { row.toggleLock(slot) }
        .font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.5)
        .buttonStyle(.bordered)
        .accessibilityLabel(row.lockLabel(slot))
        .accessibilityAddTraits(row.locks[slot] ? .isSelected : [])
      if type.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) { picker; keep }
      } else {
        HStack(spacing: 4) { picker.fixedSize(); keep }
      }
    }
  }
}

/// The You row of a set-up screen (the solo card, the lobby): the device's name in a
/// name row, picked right here (the web's youRow). A change is the device's name, kept
/// and, on a pitch, told to the room. There is no level for the player to set: from
/// engine 0.13 every person throws on one meter and a level is the computer's alone.
struct PlayerLine: View {
  let model: GameModel
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("You").font(.subheadline.weight(.semibold))
      if let row = model.nameRow { NameRowView(row: row) }
    }
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
      if let row = model.nameRow {
        VStack(alignment: .leading, spacing: 4) {
          Text("Your name").font(.subheadline.weight(.semibold))
          NameRowView(row: row)
        }
      }
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
