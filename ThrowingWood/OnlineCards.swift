import KubbRenderer
import KubbRooms
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
      case "entry": screen = .onlineEntry
      case "join": screen = .join
      default:
        let env = ProcessInfo.processInfo.environment
        guard let link = PitchLink(env["PITCH_CODE"] ?? "") else {
          screen = .invalidLink
          return
        }
        UserDefaults.standard.set("Birch", forKey: "pitch.name")
        enter(link, create: mode == "host" || mode == "share")
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
          if online.stage == .lobby {
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
      Text("Sixteen people are connected. Try again when someone leaves.")
    case .unreachable:
      Text("Cannot reach the server").font(displayFont(38))
      Text("Check your connection. The pitch will rejoin when it can.")
    case .replaced:
      Text("Open somewhere else").font(displayFont(38))
      Text("Your place has been opened on another connection.")
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
  @State private var draft = ""
  @State private var copied = false
  @FocusState private var editing: Bool
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
    HStack {
      TextField("Your name", text: $draft).textFieldStyle(.roundedBorder).focused($editing)
        .onAppear { draft = online.name }.onSubmit { profile(online.level) }
        .onChange(of: editing) { _, focused in if !focused { profile(online.level) } }
      if let levels = online.board.options.rows.first(where: { $0.id == "level" }) {
        Picker("Level", selection: Binding(get: { online.level }, set: { level in profile(level) })) {
          ForEach(levels.choices, id: \.self) { c in Text(c[1]).tag(c[0]) }
        }
      }
    }
    ForEach(["A", "B"], id: \.self) { side in
      let players = online.members.filter { $0.side == side }
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text("Team \(side)").font(displayFont(25))
          Spacer()
          Text("\(players.count) / \(online.teamMax)").font(.caption)
          if !players.contains(where: \.you) {
            Button("JOIN \(side)") {
              profile(online.level)
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
    ForEach(online.board.options.rows.filter { $0.id != "level" }) { option in
      HStack {
        Text(option.label)
        Spacer()
        if online.isHost {
          Picker(
            option.label,
            selection: Binding(
              get: { online.options[option.id] ?? "" },
              set: { v in model.runOnline { try await online.option(option.id, v) } })
          ) {
            ForEach(option.choices, id: \.self) { c in Text(c[1]).tag(c[0]) }
          }.labelsHidden()
        } else {
          Text(option.choices.first { $0[0] == online.options[option.id] }?.last ?? "")
        }
      }.font(.subheadline)
    }
    if let line = online.engineLine, line != online.note { Text(line).font(.callout.bold()) }
    if !online.note.isEmpty { Text(online.note).font(.callout.bold()) }
    if online.isHost {
      Button("START") {
        profile(online.level)
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
  private func profile(_ level: String) {
    model.perform {
      try online.profile(name: draft, level: level)
      draft = online.name
      UserDefaults.standard.set(draft, forKey: "pitch.name")
      UserDefaults.standard.set(level, forKey: "pitch.level")
    }
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
      FeedbackSettings(feedback: model.feedback, card: true).frame(maxWidth: 300)
      RaisingSetting(model: model).frame(maxWidth: 300)
      MeterSettings(meter: model.meter, card: true).frame(maxWidth: 300)
      Button("SCORE SHEET", action: model.showSheet)
      ReportButton(model: model)
      Button("BACK TO MATCH") { model.screen = .match }
      Button("HOME", action: model.home)
    }.buttonStyle(WoodButton()).modifier(Plate()).padding(18)
      .frame(maxWidth: .infinity, maxHeight: .infinity).modifier(FitOrScroll())
  }
}
