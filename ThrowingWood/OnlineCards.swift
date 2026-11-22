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
        name = "Birch"
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
    VStack(alignment: .leading, spacing: 12) {
      switch model.screen {
      case .onlineEntry:
        Text("Play online").font(displayFont(42))
        Button("START A PITCH") { model.enter(.fresh(), create: true) }.buttonStyle(
          WoodButton(accent: true))
        Button("JOIN A PITCH") {
          model.joinInput = ""
          model.screen = .join
        }.buttonStyle(WoodButton())
        OpenGamesSection(model: model)
      case .join:
        Text("Join a pitch").font(displayFont(42))
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
      Button("HOME", action: model.home).font(.headline).padding(.vertical, 5)
    }.frame(maxWidth: 400, alignment: .leading).modifier(Plate()).padding(16)
      // centred when it fits; a lobby on a phone on its side scrolls from its title
      .frame(maxWidth: .infinity, maxHeight: .infinity).modifier(FitOrScroll())
  }
  @ViewBuilder private func connection(_ stage: OnlinePitch.Stage) -> some View {
    switch stage {
    case .notFound:
      Text("Pitch not found").font(displayFont(38))
      Text("Check the link or code and try again.")
    case .full:
      Text("This pitch is full").font(displayFont(38))
      Text("This pitch has as many people on it as it takes, every one of them connected. Try again when someone leaves.")
    case .unreachable:
      Text("Cannot reach the server").font(displayFont(38))
      Text("Check your connection. The pitch will rejoin when it can.")
    case .replaced:
      Text("Open somewhere else").font(displayFont(38))
      Text("Your place has been opened on another connection.")
    case .noGame:
      // an observer's join made the pitch: it has left at once (the web's words, but
      // for where the open games are listed here)
      if let online = model.online { Text("PITCH \(online.link.code)").font(.caption.bold()).tracking(1.5) }
      Text("No game here").font(displayFont(38))
      Text("Nobody is playing on this pitch. Open games are listed on the Play online screen.")
      if let online = model.online {
        Button("JOIN THIS PITCH") { model.enter(online.link.observing(false), create: false) }
          .buttonStyle(WoodButton(accent: true))
      }
    case .reconnecting:
      Text("Reconnecting").font(displayFont(38))
      Text("Rejoining your place on the pitch…")
    default:
      Text("Connecting").font(displayFont(38))
      Text("Joining the pitch…")
    }
  }
}

struct LobbyCard: View {
  let model: GameModel, online: OnlinePitch
  @State private var copied = false
  var body: some View {
    Text("Pitch lobby").font(displayFont(38))
    Text(online.link.url.absoluteString).font(.footnote.monospaced()).textSelection(.enabled)
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
          Text("Team \(side)").font(displayFont(25))
          Spacer()
          Text("\(players.count) / \(online.teamMax)").font(.caption)
          if !players.contains(where: \.you) {
            Button("JOIN \(side)") {
              profile()
              model.runOnline { try await online.team(side) }
            }
            .disabled(players.count >= online.teamMax)
          }
        }
        if players.isEmpty {
          Text(
            online.members.contains { $0.side != nil }
              ? "The computer plays this side." : "Nobody yet."
          ).font(.subheadline)
        }
        ForEach(players) { row($0) }
      }
    }
    let watching = online.members.filter { $0.side == nil }
    HStack {
      Text("Watching").font(.headline)
      Spacer()
      if online.members.contains(where: { $0.you && $0.side != nil }) {
        Button("SIT OUT") { model.runOnline { try await online.team(nil) } }
      }
    }
    ForEach(watching) { row($0) }
    Divider()
    HStack {
      Text("Who can join")
      Spacer()
      if online.isHost {
        Picker(
          "Access",
          selection: Binding(
            get: { online.isOpen },
            set: { on in model.runOnline { try await online.access(open: on) } })
        ) {
          Text("Invite only").tag(false)
          Text("Open").tag(true)
        }.labelsHidden()
      } else {
        Text(online.isOpen ? "Open" : "Invite only")
      }
    }
    ForEach(online.optionRows) { option in
      // a scene this build does not draw shows as the day it is drawn as, and is
      // kept in the room until the host picks another
      let value = option.id == "scene" ? SceneID.shown(online.options["scene"]) : online.options[option.id] ?? ""
      HStack {
        Text(option.label)
        Spacer()
        if online.isHost {
          Picker(
            option.label,
            selection: Binding(
              get: { value },
              set: { v in model.runOnline { try await online.option(option.id, v) } })
          ) {
            ForEach(option.choices, id: \.self) { c in Text(c[1]).tag(c[0]) }
          }.labelsHidden()
        } else {
          Text(option.choices.first { $0[0] == value }?.last ?? "")
        }
      }.font(.subheadline)
    }
    if let line = online.engineLine, line != online.note { Text(line).font(.callout.bold()) }
    if !online.note.isEmpty { Text(online.note).font(.callout.bold()) }
    if online.isHost {
      Button("START") {
        profile()
        model.runOnline {
          let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
          let date = JS.object([
            ("year", .int(c.year!)), ("month", .int(c.month!)), ("day", .int(c.day!)),
            ("hour", .int(c.hour!)), ("min", .int(c.minute!)),
          ])
          try await online.start(seed: Int.random(in: 0..<2_147_483_648), at: date.json)
        }
      }.buttonStyle(WoodButton(accent: true)).disabled(!online.canStart)
    } else {
      Text("Waiting for \(online.members.first(where: \.host)?.name ?? "the host") to start.").font(
        .subheadline)
    }
  }
  private func row(_ m: PitchMember) -> some View {
    HStack(spacing: 6) {
      Image(systemName: m.connected ? "circle.fill" : "circle").font(.caption2)
        .accessibilityLabel(m.connected ? "Connected" : "Away")
      Text(m.name)
      if m.you { Text("YOU").font(.caption.bold()) }
      if m.host { Text("HOST").font(.caption.bold()) }
      if !m.connected { Text("Away").font(.caption) }
    }
  }
  /// The device's name (Settings) and its kept level, as the room knows them: the
  /// level is still sent for a match on a carried engine before 0.13 (ThrowLevel).
  private func profile() {
    model.commitName()  // a name still in its field goes first
    model.perform { try online.profile(name: model.name, level: model.throwLevel) }
  }
}

struct VersionNotice: View {
  let version: OnlinePitch.VersionCard, watch: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(version == .newer ? "A newer version" : "An older version").font(displayFont(36))
      Text(
        version == .newer
          ? "This pitch is playing on a newer version of Throwing Wood. Update the app to join."
          : "This pitch is playing on an older version of Throwing Wood. Ask the host to reload.")
      Button("WATCH", action: watch).buttonStyle(WoodButton(accent: true))
    }.frame(maxWidth: 340).modifier(Plate()).padding(20)
  }
}

struct OnlineMenu: View {
  let model: GameModel, online: OnlinePitch
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pitch menu").font(displayFont(36))
      // this match's own (the menu's Raising); the device's are in Settings
      RaisingSetting(model: model).frame(maxWidth: 300)
      SettingsButton(model: model)
      Button("SCORE SHEET", action: model.showSheet)
      ReportButton(model: model)
      Button("BACK TO MATCH") { model.screen = .match }
      Button("HOME", action: model.home)
      VersionFooter(label: online.board.versionLabel)
    }.buttonStyle(WoodButton()).modifier(Plate()).padding(18)
      .frame(maxWidth: .infinity, maxHeight: .infinity).modifier(FitOrScroll())
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
    Text("PITCH \(online.link.code)").font(.caption.bold()).tracking(1.5)
    Text("Watching").font(displayFont(38))
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
