import KubbRenderer
import SwiftUI
import UniformTypeIdentifiers

struct HomeCard: View {
  let model: GameModel
  var body: some View {
    VStack {
      VStack(spacing: -5) {
        Text("KUBB").font(displayFont(82))
        Text("THROWING WOOD").font(displayFont(30))
      }.padding(.horizontal, 20).modifier(Plate())
      Spacer()
      VStack(spacing: 12) {
        Button {
          model.solo()
        } label: {
          Text("PLAY THE COMPUTER").frame(maxWidth: .infinity)
        }
        .buttonStyle(WoodButton(accent: true))
        Button {
          model.screen = .practice
        } label: {
          Text("PRACTICE").frame(maxWidth: .infinity)
        }
        .buttonStyle(WoodButton())
      }.frame(maxWidth: 280)
    }.padding(.top, 22).padding(.bottom, 44)
  }
}

struct MatchOptionsCard: View {
  @Bindable var model: GameModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("Play the computer").font(displayFont(37))
        TextField("Your name", text: $model.name)
          .textFieldStyle(.roundedBorder).accessibilityLabel("Your name")
          .onChange(of: model.name) { _, value in
            model.name = String(value.prefix(model.pitch?.options.nameLimit ?? value.count))
          }
        ForEach(model.pitch?.options.rows ?? []) { row in
          HStack {
            Text(row.label).font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
              ForEach(row.choices, id: \.self) { choice in
                Button {
                  model.selections[row.id] = choice[0]
                } label: {
                  if model.selections[row.id] == choice[0] {
                    Label(choice[1], systemImage: "checkmark")
                  } else {
                    Text(choice[1])
                  }
                }
              }
            } label: {
              let value = row.choices.first { $0[0] == model.selections[row.id] }?.last ?? ""
              HStack {
                Text(value)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
              }
              .frame(minWidth: 100, minHeight: 32, alignment: .trailing)
            }.accessibilityLabel(row.label)
          }
          Divider()
        }
        HStack {
          Button("HOME", action: model.home).buttonStyle(WoodButton())
          Spacer()
          Button("START", action: model.start).buttonStyle(WoodButton(accent: true))
        }
      }.modifier(Plate(inset: 20)).padding(18)
    }.scrollBounceBehavior(.basedOnSize).defaultScrollAnchor(.center)
  }
}

private struct NotationFile: FileDocument {
  static let readableContentTypes = [UTType.plainText]
  let text: String
  init(_ text: String) { self.text = text }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents,
      let contents = String(data: data, encoding: .utf8)
    else { throw CocoaError(.fileReadCorruptFile) }
    text = contents
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

struct SheetCard: View {
  let sheet: ScoreSheet, done: () -> Void
  @State private var positions = false
  @State private var copied = false
  @State private var exporting = false
  @State private var exportError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Score sheet").font(displayFont(38))
      Text("Planet Kubb Notation").font(.subheadline.weight(.semibold))
      ScrollView([.vertical, .horizontal]) {
        Text(verbatim: positions ? sheet.text : sheet.shown.joined(separator: "\n"))
          .font(.system(size: 13, design: .monospaced))
          .fixedSize(horizontal: true, vertical: true).textSelection(.enabled).padding(10)
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white).border(Color.woodInk)
      Toggle("Show positions", isOn: $positions)
      HStack {
        Button(copied ? "COPIED" : "COPY") {
          UIPasteboard.general.string = sheet.text
          copied = true
        }.buttonStyle(WoodButton())
        Spacer()
        Button("SAVE") { exporting = true }.buttonStyle(WoodButton())
        Button("BACK", action: done).buttonStyle(WoodButton(accent: true))
      }
    }.modifier(Plate()).padding(16)
      .fileExporter(
        isPresented: $exporting, document: NotationFile(sheet.text),
        contentType: .plainText, defaultFilename: sheet.name
      ) { result in
        if case .failure(let error) = result { exportError = error.localizedDescription }
      }
      .alert(
        "Save failed",
        isPresented: Binding(
          get: { exportError != nil },
          set: { if !$0 { exportError = nil } })
      ) {
        Button("Close") {}
      } message: {
        Text(exportError ?? "")
      }
  }
}

struct MatchMenu: View {
  let model: GameModel, pitch: PitchSession
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Match menu").font(displayFont(36))
      if let row = pitch.options.rows.first(where: { $0.id == "level" }) {
        Picker(
          "Throw level",
          selection: Binding(
            get: { model.selections["level"] ?? "" },
            set: model.changeLevel)
        ) {
          ForEach(row.choices, id: \.self) { c in Text(c[1]).tag(c[0]) }
        }.pickerStyle(.segmented)
      }
      Text(
        "Drag the circle to aim. Wind back on the left of the dial, flick through six and lift on the right."
      )
      .font(.subheadline)
      Button("SCORE SHEET", action: model.showSheet).buttonStyle(WoodButton())
      HStack {
        Button("HOME", action: model.home)
        Spacer()
        Button(pitch.need?.resignPending == nil ? "RESIGN" : "RESIGNING…") {
          model.perform {
            try pitch.resign()
            model.screen = .match
          }
        }.disabled(pitch.need?.resignPending != nil)
      }.buttonStyle(WoodButton())
      Button("BACK TO MATCH") { model.screen = .match }.buttonStyle(WoodButton(accent: true))
    }.frame(maxWidth: 330, alignment: .leading).modifier(Plate(inset: 20)).padding(20)
  }
}

struct MatchScreen: View {
  let model: GameModel, pitch: PitchSession, revision: Int, playing: Bool
  var body: some View {
    if let n = pitch.need {
      ZStack {
        VStack(spacing: 8) {
          HStack {
            VStack(alignment: .leading, spacing: 1) {
              Text(n.cpu == true ? "WATCH  ·  TURN \(n.turn ?? 1)" : "TURN \(n.turn ?? 1)")
                .font(.caption2.bold()).tracking(1.4)
              Text(n.setup?.thrower?.name ?? n.team ?? "Match").font(displayFont(27)).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing) {
              if let s = n.setup {
                let left = s.of - s.n + (playing ? 0 : 1)
                Text(
                  s.projectile == "baton"
                    ? "\(left) \(left == 1 ? "baton" : "batons") left" : "Kubb \(s.n) of \(s.of)"
                )
                .font(.subheadline.bold())
              }
              if let counts = n.standing {
                Text("You \(counts["A"] ?? 0)  ·  CPU \(counts["B"] ?? 0)")
                  .font(.caption).accessibilityLabel(
                    "Kubbs standing, you \(counts["A"] ?? 0), computer \(counts["B"] ?? 0)")
              }
            }
            Button {
              model.screen = .menu
            } label: {
              Image(systemName: "ellipsis.circle").font(.title2).frame(width: 35, height: 38)
            }.accessibilityLabel("Match menu")
          }.modifier(Plate(inset: 9))
          if model.slow {
            Text("SLOW MOTION").font(.caption.bold()).modifier(Plate(inset: 5))
          } else if let wind = pitch.windText, n.kind == "throw" {
            Text(wind).font(.caption.bold()).modifier(Plate(inset: 5))
          }
          if let result = model.result, n.kind == "throw" { Verdict(result: result) }
          Spacer()
          if n.kind == "raise" || n.kind == "punish" {
            placement(n)
          } else if !playing && pitch.canAim {
            plans
          } else if playing {
            HStack {
              Spacer()
              tool("SKIP", label: "Skip playback") { try pitch.skipPlayback() }
            }
          }
        }.padding(.horizontal, 12)
        if let c = pitch.handoff {
          modal { handoff(c) }
        } else if let w = n.winner {
          modal { winner(n, w) }
        }
      }
    }
  }

  private var plans: some View {
    VStack(spacing: 4) {
      HStack {
        VStack(spacing: 6) {
          tool("ARC ▲", label: "Increase arc") { try pitch.adjustPlan(arc: true, step: 1) }
          tool("\(pitch.arcDegrees ?? 0)° ▼", label: "Decrease arc") {
            try pitch.adjustPlan(arc: true, step: -1)
          }
        }
        Spacer()
        VStack(spacing: 6) {
          let word = pitch.need?.setup?.projectile == "kubb" ? "SPIN" : "TILT"
          tool("◂ \(word)", label: "\(word) left") { try pitch.adjustPlan(arc: false, step: -1) }
          tool("\(pitch.sideStep ?? 0) ▸", label: "\(word) right") {
            try pitch.adjustPlan(arc: false, step: 1)
          }
        }
      }.padding(.bottom, 40)
      HStack {
        tool("PLAN VIEW", label: "Toggle plan view", on: pitch.plan) { try pitch.togglePlan() }
        Spacer()
        tool("WALK", label: "Walk by dragging on the pitch", on: pitch.walking) {
          try pitch.toggleWalk()
        }
      }
    }
  }

  private func tool(
    _ text: String, label: String, on: Bool = false, _ action: @escaping () throws -> Void
  ) -> some View {
    Button {
      model.perform(action)
    } label: {
      Text(text).font(displayFont(16)).frame(minWidth: 43, minHeight: 31)
        .modifier(Plate(fill: on ? .woodGold : .woodPaper, inset: 4))
    }.accessibilityLabel(label)
  }

  private func placement(_ n: MatchNeed) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(n.kind == "raise" ? "Raise" : "Punishment kubb") \(n.n ?? 1) of \(n.of ?? 1)")
        .font(displayFont(28))
      if n.kind == "raise" {
        Text("Tap the end to stand it on.").font(.subheadline)
        HStack {
          ForEach(n.ends ?? [], id: \.which) { e in
            Button("END \(e.which)") { model.perform { try pitch.raise(end: e.which) } }
              .disabled(e.ok != true).opacity(e.ok == true ? 1 : 0.45).accessibilityHint(
                e.why ?? "")
          }
          Button("AUTO") { model.perform { try pitch.raise() } }
        }.buttonStyle(WoodButton())
      } else {
        Text(pitch.placement?.label ?? "Drag or tap a spot clear of the circles.").font(
          .subheadline)
        Button("PLACE IT") { model.perform { try pitch.placePunishment() } }
          .buttonStyle(WoodButton(accent: true)).disabled(pitch.placement?.ok != true)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).modifier(Plate())
  }

  private func modal<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ZStack {
      Color.black.opacity(0.26).ignoresSafeArea()
      content().frame(maxWidth: 330).modifier(Plate(inset: 20)).padding(22)
    }
  }

  private func handoff(_ c: MatchNeed.Handoff) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("TURN \(c.turn)").font(.caption.bold()).tracking(1.5)
      Text(c.toName).font(displayFont(44))
      if let took = c.took, let from = c.fromName {
        Text("\(from) took \(took.field) field and \(took.base) base kubbs.")
      }
      Text(
        c.kubbs > 0
          ? "Throw \(c.kubbs) kubbs in, then \(c.batons) batons." : "Throw \(c.batons) batons.")
      HStack {
        Text(c.baseText.joined(separator: "\n")).font(.caption.bold())
        Spacer()
        Canvas { ctx, size in
          ctx.withCGContext { cg in
            pitch.scene.scenery.drawMap(
              in: cg, rect: CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
          }
        }.frame(width: 62, height: 98)
      }
      Button("THROW") { model.perform { pitch.dismissHandoff() } }.buttonStyle(
        WoodButton(accent: true))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func winner(_ n: MatchNeed, _ w: MatchNeed.Winner) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(n.short ?? "GAME").font(.caption.bold()).tracking(1.2)
      Text("\(w.winnerName) wins").font(displayFont(40))
      if let how = n.how { Text(how) }
      Text("\(w.turns) turns  ·  \(w.hits ?? 0) of \(w.thrown ?? 0) batons hit").font(
        .subheadline.bold())
      if let minutes = w.minutes {
        Text(minutes == 0 ? "Under a minute" : "\(minutes) min").font(.caption)
      }
      HStack {
        Button("REMATCH") { model.screen = .options }.buttonStyle(WoodButton(accent: true))
        Button("SCORE SHEET", action: model.showSheet).buttonStyle(WoodButton())
      }
      Button("HOME", action: model.home).font(.caption.bold()).padding(.vertical, 8)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
