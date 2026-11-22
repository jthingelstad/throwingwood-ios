import KubbRenderer
import KubbPitch
import SwiftUI

extension GameModel {
  func runOnline(_ body: @escaping @MainActor () async throws -> Void) {
    let owner = online
    Task {
      do { try await body() } catch {
        if online === owner { self.error = "The pitch did not take that. Try again." }
      }
    }
  }
  #if targetEnvironment(simulator)
    func beginReview(_ mode: String) {
      switch mode {
      case "entry", "opengames": screen = .onlineEntry
      case "join": screen = .join
      default:
        let env = ProcessInfo.processInfo.environment
        guard let link = PitchLink(env["PITCH_CODE"] ?? "") else {
          screen = .invalidLink
          return
        }
        name = "Brave Birch"
        // an observer: watching a match, between matches, or on an empty pitch
        let observe = ["observe", "observemoved", "watchcard", "noGame"].contains(mode)
        enter(link.observing(observe), create: mode == "host" || mode == "share")
      }
    }
  #endif
}

struct OnlineCards: View {
  @Bindable var model: GameModel
  var body: some View {
    CardScreen(width: 400) {
     VStack(alignment: .leading, spacing: 12) {
      switch model.screen {
      case .onlineEntry:
        Text("Play online").cardTitle()
        Button("START A PITCH") { model.enter(.fresh(), create: true) }.buttonStyle(
          WoodButton(accent: true))
        Button("JOIN A PITCH") {
          model.joinInput = ""
          model.screen = .join
        }.buttonStyle(WoodButton())
        OpenGamesSection(model: model)
      case .join:
        Text("Join a pitch").cardTitle()
        TextField("Pitch link or code", text: $model.joinInput)
          .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
          .autocorrectionDisabled().submitLabel(.go).onSubmit { model.join(model.joinInput) }
        Button("JOIN") { model.join(model.joinInput) }.buttonStyle(WoodButton(accent: true))
          .disabled(model.joinInput.isEmpty)
      case .invalidLink: connection(.notFound)
      default:
        if let online = model.online {
          if online.stage == .lobby && online.observing {
            WatchCard(model: model, online: online)
          } else if online.stage == .lobby {
            LobbyCard(model: model, online: online)
          } else {
            connection(online.stage)
          }
        }
      }
     }
    } buttons: {
      // HOME quiet at the left; the lobby's START, go, at the right for the host
      ButtonRow {
        QuietButton("HOME", action: model.home)
      } trailing: {
        if model.screen == .pitch, let online = model.online, online.stage == .lobby, !online.observing,
          online.isHost
        {
          LobbyStart(model: model, online: online)
        }
      }
    }
  }
  @ViewBuilder private func connection(_ stage: OnlinePitch.Stage) -> some View {
    switch stage {
    case .notFound:
      Text("Pitch not found").cardTitle()
      Text("Check the link or code and try again.")
    case .full:
      Text("This pitch is full").cardTitle()
      Text("This pitch has as many people on it as it takes, every one of them connected. Try again when someone leaves.")
    case .unreachable:
      Text("Cannot reach the server").cardTitle()
      Text("Check your connection. The pitch will rejoin when it can.")
    case .replaced:
      Text("Open somewhere else").cardTitle()
      Text("Your place has been opened on another connection.")
    case .noGame:
      // an observer's join made the pitch: it has left at once (the web's words, but
      // for where the open games are listed here)
      if let online = model.online { Text("PITCH \(online.link.code)").labelStyle() }
      Text("No game here").cardTitle()
      Text("Nobody is playing on this pitch. Open games are listed on the Play online screen.")
      if let online = model.online {
        Button("JOIN THIS PITCH") { model.enter(online.link.observing(false), create: false) }
          .buttonStyle(WoodButton(accent: true))
      }
    case .namesRefused:
      // a match holding a name the game did not make (a forged start): not shown
      if let online = model.online { Text("PITCH \(online.link.code)").labelStyle() }
      Text(NameWords.badMatchTitle).cardTitle()
      Text(NameWords.badMatch).fixedSize(horizontal: false, vertical: true)
    case .reconnecting:
      Text("Reconnecting").cardTitle()
      Text("Rejoining your place on the pitch…")
    default:
      Text("Connecting").cardTitle()
      Text("Joining the pitch…")
    }
  }
}

/// The lobby (the 1.0 design: the one-line name row; every two to four way option a
/// segmented bar, five or more a plain button that opens its list). START is the host's,
/// go, in the card's pinned button row (`LobbyStart`).
struct LobbyCard: View {
  let model: GameModel, online: OnlinePitch
  @State private var copied = false
  var body: some View {
    Text("Pitch lobby").cardTitle()
    Text(online.link.url.absoluteString).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
    HStack {
      ShareLink(item: online.link.url) { Label("SHARE", systemImage: "square.and.arrow.up") }
      Button(copied ? "COPIED" : "COPY") {
        UIPasteboard.general.string = online.link.url.absoluteString
        copied = true
      }
    }.buttonStyle(WoodButton())
    // the name is the device's (Settings): the pitch hears a change at once
    PlayerLine(model: model)
    ForEach(["A", "B"], id: \.self) { side in
      let players = online.members.filter { $0.side == side }
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text("Team \(side)").font(displayFont(25, relativeTo: .title2))
          Spacer()
          Text("\(players.count) / \(online.teamMax)").font(bodyFont(14, .bold, relativeTo: .subheadline))
          if !players.contains(where: \.you) {
            Button("JOIN \(side)") {
              profile()
              model.runOnline { try await online.team(side) }
            }
            .buttonStyle(WoodButton())
            .disabled(players.count >= online.teamMax)
          }
        }
        if players.count > 1 {
          // a side of several plays under a team name, the host's to pick (a side of one
          // plays under its player's name)
          VStack(alignment: .leading, spacing: 2) {
            Text(NameWords.playsAs).labelStyle()
            if let row = online.teamRow(side) {
              NameRowView(row: row, size: 22)
            } else {
              Text(online.teamNames[side] ?? "Team \(side)").font(displayFont(22, relativeTo: .title3))
            }
          }
        }
        if players.isEmpty {
          Text(
            online.members.contains { $0.side != nil }
              ? "The computer plays this side." : "Nobody yet."
          ).font(bodyFont(15))
        }
        ForEach(players) { row($0) }
      }
    }
    let watching = online.members.filter { $0.side == nil }
    HStack {
      Text("Watching").labelStyle()
      Spacer()
      if online.members.contains(where: { $0.you && $0.side != nil }) {
        Button("SIT OUT") { model.runOnline { try await online.team(nil) } }.buttonStyle(WoodButton())
      }
    }
    ForEach(watching) { row($0) }
    Rule()
    FormRow("Who can join") { full in
      if online.isHost {
        Segmented(
          label: "Who can join", choices: [(false, "Invite only"), (true, "Open")],
          value: Binding(
            get: { online.isOpen },
            set: { on in model.runOnline { try await online.access(open: on) } }),
          full: full)
      } else {
        Text(online.isOpen ? "Open" : "Invite only").font(bodyFont(15, .bold))
      }
    }
    ForEach(online.optionRows) { option in
      // a scene this build does not draw shows as the day it is drawn as, and is
      // kept in the room until the host picks another
      let value = option.id == "scene" ? SceneID.shown(online.options["scene"]) : online.options[option.id] ?? ""
      let pick = Binding(get: { value }, set: { v in model.runOnline { try await online.option(option.id, v) } })
      if option.id == "scene", online.isHost {
        // the host's Scene: the seven picture tiles, as on the solo card (the web's lobby)
        Text(option.label).labelStyle().accessibilityHidden(true)
        SceneTiles(scenery: online.board.scene.scenery, row: option, value: pick)
      } else {
      FormRow(option.label) { full in
        if !online.isHost {
          Text(option.choices.first { $0[0] == value }?.last ?? "").font(bodyFont(15, .bold))
        } else if option.choices.count <= 4 {
          Segmented(label: option.label, choices: option.choices.map { ($0[0], $0[1]) }, value: pick, full: full)
        } else {
          ChoiceList(label: option.label, choices: option.choices.map { ($0[0], $0[1]) }, value: pick)
        }
      }
      }
    }
    if let line = online.engineLine, line != online.note { Text(line).font(bodyFont(16, .bold)) }
    if !online.note.isEmpty { Text(online.note).font(bodyFont(16, .bold)) }
    if !online.isHost {
      Text("Waiting for \(online.members.first(where: \.host)?.name ?? "the host") to start.").font(bodyFont(15))
    }
  }
  private func row(_ m: PitchMember) -> some View {
    HStack(spacing: 6) {
      Image(systemName: m.connected ? "circle.fill" : "circle").font(.caption2)
        .accessibilityLabel(m.connected ? "Connected" : "Away")
      Text(m.name).font(bodyFont(16, .semibold))
      if m.you { Text("YOU").modifier(Chip(fill: .woodInk, ink: .woodPaper)) }
      if m.host { Text("HOST").modifier(Chip()) }
      if !m.connected { Text("Away").font(bodyFont(14)) }
    }
  }
  /// The device's name (Settings), as the room knows it.
  private func profile() {
    model.perform { try online.profile(name: model.name) }
  }
}

/// The host's START, go, in the lobby card's pinned button row.
struct LobbyStart: View {
  let model: GameModel, online: OnlinePitch
  var body: some View {
    Button {
      model.perform { try online.profile(name: model.name) }
      model.runOnline {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
        let date = JS.object([
          ("year", .int(c.year!)), ("month", .int(c.month!)), ("day", .int(c.day!)),
          ("hour", .int(c.hour!)), ("min", .int(c.minute!)),
        ])
        try await online.start(seed: Int.random(in: 0..<2_147_483_648), at: date.json)
      }
    } label: {
      Text("START").frame(minWidth: 110)
    }
    .buttonStyle(WoodButton(accent: true)).disabled(!online.canStart)
  }
}

/// Five or more choices (the system's "Picker": the lobby's Kubbs): a plain button
/// showing the value, which opens the list on a card; the chosen row inverted.
struct ChoiceList: View {
  let label: String
  let choices: [(value: String, text: String)]
  @Binding var value: String
  @State private var open = false
  var body: some View {
    Button {
      open = true
    } label: {
      HStack(spacing: 6) {
        Text(choices.first { $0.value == value }?.text ?? value)
        Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
      }
    }
    .buttonStyle(WoodButton())
    .accessibilityLabel(label)
    .accessibilityValue(choices.first { $0.value == value }?.text ?? value)
    .sheet(isPresented: $open) {
      VStack(alignment: .leading, spacing: 8) {
        Text(label).cardTitle(28)
        ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
          let on = c.value == value
          Button {
            value = c.value
            open = false
          } label: {
            Text(c.text).font(bodyFont(17, .bold)).foregroundStyle(on ? Color.woodPaper : Color.woodInk)
              .frame(maxWidth: .infinity, minHeight: TW.touch, alignment: .leading).padding(.horizontal, 14)
              .background(on ? Color.woodInk : Color.woodField, in: RoundedRectangle(cornerRadius: TW.controlRadius))
              .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.chipLine))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(c.text)
          .accessibilityValue(SegmentWords.value(index: i, count: choices.count, selected: on))
        }
      }
      .padding(TW.cardPadding)
      .frame(maxHeight: .infinity, alignment: .top)
      .presentationDetents([.medium, .large])
      .presentationBackground(Color.woodPaper)
    }
  }
}

struct VersionNotice: View {
  let version: OnlinePitch.VersionCard, watch: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(VersionWords.cardTitle(newer: version == .newer)).cardTitle()
      Text(VersionWords.cardText(newer: version == .newer)).fixedSize(horizontal: false, vertical: true)
      Button("WATCH", action: watch).buttonStyle(WoodButton(accent: true))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }.frame(maxWidth: 340).padding(TW.cardPadding).modifier(CardFace()).padding(20)
  }
}

/// The pitch menu (the 1.0 design, as the match menu): the two by two grid of plain
/// buttons, this match's Raising, BACK TO THE MATCH as go and HOME quiet (no RESIGN
/// online), the version at the foot.
struct OnlineMenu: View {
  let model: GameModel, online: OnlinePitch
  @Environment(\.dynamicTypeSize) private var type
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    let footInRows = FootInRows.at(type, wide: screen.wide)
    CardScreen(width: 400) {
      VStack(alignment: .leading, spacing: TW.rowGap) {
        Text("Pitch menu").cardTitle()
        MenuGrid(model: model)
        // this match's own (the menu's Raising); the device's are in Settings
        RaisingSetting(model: model)
        if footInRows { VersionFooter(label: online.board.versionLabel) }
      }
    } buttons: {
      VStack(alignment: .leading, spacing: 8) {
        Button { model.screen = .match } label: { Text("BACK TO THE MATCH").frame(maxWidth: .infinity) }
          .buttonStyle(WoodButton(accent: true))
        QuietButton("HOME", action: model.home)
        if !footInRows { VersionFooter(label: online.board.versionLabel) }
      }
    }
  }
}

/// The card an observer sees between matches, in place of the lobby (the web's
/// src/ui/watching.js, its words): who is on each team, who is watching, and the ways
/// on. No name, no team buttons, no options, no START: it watches. WATCH THE LAST MATCH
/// is the web's alone (the app has no replay viewer).
struct WatchCard: View {
  let model: GameModel, online: OnlinePitch
  var body: some View {
    let players = online.members.filter { $0.side != nil }
    let host = online.members.first(where: \.host)
    Text("PITCH \(online.link.code)").labelStyle()
    Text("Watching").cardTitle()
    Text(
      players.isEmpty
        ? "Nobody has picked a side yet."
        : host.map { "Waiting for \($0.name) to start the match." } ?? "Waiting for the host to start the match."
    ).font(.subheadline)
    ForEach(["A", "B"], id: \.self) { side in
      let names = online.members.filter { $0.side == side }.map(\.name)
      (Text("Team \(side)  ").font(.headline) + Text(names.isEmpty ? "nobody yet" : names.joined(separator: ", ")))
    }
    let watching = online.members.filter { $0.side == nil }
    (Text("Watching  ").font(.headline)
      + Text(watching.map { $0.name + ($0.you ? " (you)" : "") }.joined(separator: ", ")))
    if !online.note.isEmpty { Text(online.note).font(.callout.bold()) }
    Button("JOIN THIS PITCH") { model.enter(online.link.observing(false), create: false) }
      .buttonStyle(WoodButton(accent: true))
  }
}

/// The Open games list where the online entry is (the web's public/js/open-games.js):
/// one look at the pitch server's `/open` every 30 s while the screen shows and the app is in
/// front, JOIN and WATCH on each row. Never a name.
struct OpenGamesSection: View {
  let model: GameModel
  @Environment(\.scenePhase) private var phase
  @State private var games: [OpenGame] = []
  @State private var now = 0
  @State private var status: String? = OpenGames.looking
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider().padding(.vertical, 4)
      Text(OpenGames.title).font(displayFont(28))
      Text(OpenGames.intro).font(.subheadline)
      if let status { Text(status).font(.subheadline.bold()) }
      ForEach(games) { g in
        VStack(alignment: .leading, spacing: 6) {
          Text(OpenGames.line(g, now: now)).font(.subheadline)
          HStack {
            Button("JOIN") { open(g, observe: false) }.buttonStyle(WoodButton(accent: true))
            Button("WATCH") { open(g, observe: true) }.buttonStyle(WoodButton())
          }
        }
        .accessibilityElement(children: .contain)
        .padding(.bottom, 8)
      }
    }
    .task(id: phase) {
      guard phase == .active else { return }
      while !Task.isCancelled {
        await look()
        do { try await Task.sleep(for: OpenGames.every) } catch { return }
      }
    }
  }
  private func look() async {
    do {
      let out = try await PitchAPI.openGames(server: PitchConfiguration.server, appVersion: GameModel.version)
      (now, games) = (out.now, out.games)
      status = games.isEmpty ? OpenGames.empty : nil
    } catch {
      games = []
      status = OpenGames.failed
    }
  }
  private func open(_ g: OpenGame, observe: Bool) {
    guard let link = PitchLink(g.pitch) else { return }
    model.join(link.observing(observe))
  }
}
