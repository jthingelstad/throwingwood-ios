import KubbRenderer
import SwiftUI

/// The name row (`NameRowModel`; the 1.0 design's "The name row"): the name and
/// SHUFFLE on one line, on the solo card, the lobby (the You row and a side's team name)
/// and the share card. No word is held: SHUFFLE rolls a whole new name. Stepping word by word is
/// in Settings alone (`NameSteppers`). The name fits the widest the engine can make
/// (`NameFitTests`); from the largest three text sizes SHUFFLE goes under the name, so no
/// word is broken.
struct NameRowView: View {
  @Bindable var row: NameRowModel
  /// The name's size at the default text size (the design: 30 in Settings, 26 on the
  /// solo card, 24 in the lobby).
  var size: CGFloat = 26
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    Group {
      if type >= .accessibility3 {
        VStack(alignment: .leading, spacing: 8) { name; shuffle }
      } else {
        HStack(spacing: 10) {
          name
          Spacer(minLength: 4)
          shuffle
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
    Text(row.text).font(displayFont(size, relativeTo: .title2)).foregroundStyle(Color.woodInk)
      .lineLimit(type >= .accessibility3 ? nil : 1).minimumScaleFactor(0.6)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var shuffle: some View {
    Button("SHUFFLE") { row.shuffle() }.buttonStyle(WoodButton())
      .lineLimit(1).fixedSize()
      .accessibilityLabel(row.shuffleLabel)
  }
}

/// Settings' word steppers (the design: "Open: only in Settings"): for each word,
/// previous, the word, next, as one joined bar (the engine's `names.step`, the Playdate's
/// crank made a control). VoiceOver reads each word as "Your name, first word" with the
/// word as its value, adjustable, and its buttons "Previous first word", "Next first
/// word". Two side by side; under each other where they do not fit.
struct NameSteppers: View {
  @Bindable var row: NameRowModel
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    let slots = Array(row.parts.words.indices)
    Group {
      if type >= .accessibility3 || slots.count != 2 {
        VStack(spacing: 10) { ForEach(slots, id: \.self) { stepper($0) } }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { ForEach(slots, id: \.self) { stepper($0) } }
          VStack(spacing: 10) { ForEach(slots, id: \.self) { stepper($0) } }
        }
      }
    }
  }

  private func stepper(_ slot: Int) -> some View {
    HStack(spacing: 2) {
      arrow(slot, -1)
      Text(row.parts.words[slot]).font(bodyFont(15, .bold, relativeTo: .subheadline))
        .foregroundStyle(Color.woodPaper).lineLimit(1).minimumScaleFactor(0.6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: TW.touch)
        .background(Color.woodInk)
        .accessibilityLabel(row.wordLabel(slot))
        .accessibilityValue(row.parts.words[slot])
        .accessibilityAdjustableAction { direction in
          row.step(slot, direction == .increment ? 1 : -1)
        }
      arrow(slot, 1)
    }
    .padding(.horizontal, TW.line - 1)
    .background(Color.woodInk)
    .clipShape(RoundedRectangle(cornerRadius: TW.controlRadius))
    .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(row.groupLabel(slot))
  }

  private func arrow(_ slot: Int, _ dir: Int) -> some View {
    Button {
      row.step(slot, dir)
    } label: {
      Image(systemName: dir < 0 ? "chevron.left" : "chevron.right")
        .font(.system(size: 17, weight: .bold)).foregroundStyle(Color.woodInk)
        .frame(width: TW.touch, height: TW.touch)
        .background(Color.woodField)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(row.stepLabel(slot, dir))
  }
}

/// The You row of a set-up screen (the solo card, the lobby): the device's name in a
/// name row, picked right here (the web's youRow). A change is the device's name, kept
/// and, on a pitch, told to the room. There is no level for the player to set: from
/// engine 0.13 every person throws on one meter and a level is the computer's alone.
struct PlayerLine: View {
  let model: GameModel
  var size: CGFloat = 26
  var body: some View {
    if let row = model.nameRow { NameRowView(row: row, size: size) }
  }
}

/// Settings: the device's own choices in one place (the owner's scopes: name,
/// sound, haptics, meter and its side), reached from home, a set-up screen's line, the
/// match and pitch menus and the practice menu. Nothing about one game is here: those
/// are the game's options (the solo options, the practice menu, the lobby). The 1.0
/// design: the name with SHUFFLE and two word steppers, Sound, Haptics, Meter, Meter
/// side, one muted line, the version at the foot and DONE, go, at the bottom right.
struct SettingsCard: View {
  @Bindable var model: GameModel
  @Environment(\.dynamicTypeSize) private var type
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    let footInRows = FootInRows.at(type, wide: screen.wide)
    CardScreen(width: 400) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Settings").cardTitle()
        // the web's one muted line (its src/ui/settings.js)
        Text("Kept on this device. The match options are on each match's card.").helperText()
        if let row = model.nameRow {
          Text("Your name").labelStyle().accessibilityHidden(true)
          NameRowView(row: row, size: 30)
          NameSteppers(row: row)
        }
        Rule().padding(.top, 4)
        FeedbackSettings(feedback: model.feedback)
        Rule()
        MeterSettings(meter: model.meter)
        if footInRows, let label = model.pitch?.versionLabel { VersionFooter(label: label) }
      }
    } buttons: {
      ButtonRow {
        if !footInRows, let label = model.pitch?.versionLabel { VersionFooter(label: label) }
      } trailing: {
        Button {
          model.screen = model.settingsReturn
        } label: {
          Text("DONE").frame(minWidth: 96)
        }
        .buttonStyle(WoodButton(accent: true))
      }
    }
  }
}

/// The way to Settings from a menu card.
struct SettingsButton: View {
  let model: GameModel
  var body: some View {
    Button(action: model.openSettings) {
      Text("SETTINGS").frame(maxWidth: .infinity)
    }
    .accessibilityHint("Your name, sound, haptics and meter")
  }
}
