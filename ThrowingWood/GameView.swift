import KubbRenderer
import SwiftUI

extension Color {
  static let woodInk = Color(red: 23 / 255, green: 20 / 255, blue: 15 / 255)
  static let woodPaper = Color(red: 251 / 255, green: 246 / 255, blue: 234 / 255)
  static let woodGold = Color(red: 0.96, green: 0.73, blue: 0.13)
}

struct Plate: ViewModifier {
  var fill = Color.woodPaper
  var inset: CGFloat = 16
  func body(content: Content) -> some View {
    content.foregroundStyle(Color.woodInk).padding(inset)
      .background(fill, in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.woodInk, lineWidth: 2))
      .background(RoundedRectangle(cornerRadius: 5).fill(Color.woodInk).offset(x: 3, y: 4))
  }
}

struct WoodButton: ButtonStyle {
  var accent = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.custom("LondrinaSolid-Black", size: 21, relativeTo: .headline))
      .frame(minHeight: 26).padding(.horizontal, 6)
      .modifier(Plate(fill: accent ? .woodGold : .woodPaper, inset: 8))
      .offset(y: configuration.isPressed ? 2 : 0)
  }
}

func displayFont(_ size: CGFloat) -> Font { .custom("LondrinaSolid-Black", size: size) }

struct GameView: View {
  @State private var model = GameModel()
  @Environment(\.scenePhase) private var phase
  var body: some View {
    ZStack {
      if let pitch = model.pitch {
        let live = model.screen == .practice || model.screen == .match
        PitchBoard(
          pitch: pitch, model: model, active: live && phase == .active && model.error == nil,
          revision: model.revision + model.onlineRevision, screen: model.screen
        )
        .id(ObjectIdentifier(pitch)).ignoresSafeArea().allowsHitTesting(live)
        if let version = model.online?.versionCard {
          VersionNotice(version: version) { model.online?.watch() }
        } else {
          switch model.screen {
          case .home: HomeCard(model: model)
          case .options: MatchOptionsCard(model: model)
          case .practice: practice
          case .match:
            MatchScreen(
              model: model, pitch: pitch, revision: model.revision, playing: model.playing)
          case .menu:
            if let online = model.online {
              OnlineMenu(model: model, online: online)
            } else {
              MatchMenu(model: model, pitch: pitch)
            }
          case .onlineEntry, .join, .pitch, .invalidLink: OnlineCards(model: model)
          case .report:
            if let online = model.online, let report = model.report {
              ReportCard(model: model, online: online, report: report)
            }
          case .sheet:
            if let sheet = model.sheet {
              SheetCard(sheet: sheet) { model.screen = model.sheetReturn }
            }
          }
        }
      }
    }
    #if targetEnvironment(simulator)
      .modifier(OnlineReview(model: model))
    #endif
    .onChange(of: phase) { _, phase in
      if phase == .background { model.online?.background() }
      if phase == .active { model.online?.connect() }
    }
    .onDisappear { model.online?.close() }
    .preferredColorScheme(.light)
    .alert(
      "Pitch unavailable",
      isPresented: Binding(
        get: { model.error != nil },
        set: { if !$0 { model.error = nil } })
    ) {
      Button("Close") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }

  private var practice: some View {
    VStack(spacing: 10) {
      HStack {
        Button(action: model.home) { Image(systemName: "house.fill").frame(width: 36, height: 36) }
          .accessibilityLabel("Home")
        Text("Practice pitch").font(displayFont(28))
        Spacer()
        Menu {
          ForEach(Surface.allCases, id: \.self) { s in
            Button {
              model.perform { try model.pitch?.surface(s) }
            } label: {
              if s == model.surface {
                Label(s.rawValue.capitalized, systemImage: "checkmark")
              } else {
                Text(s.rawValue.capitalized)
              }
            }
          }
        } label: {
          Label(model.surface.rawValue.capitalized, systemImage: "chevron.up.chevron.down")
        }
        .disabled(model.playing)
      }.modifier(Plate(inset: 8))
      if let result = model.result { Verdict(result: result) }
      Spacer()
    }.padding(.horizontal, 14)
  }
}

struct Verdict: View {
  let result: ThrowResult
  var body: some View {
    VStack(spacing: 3) {
      if let flag = result.flag { Text(flag).font(displayFont(29)) }
      HStack(spacing: 4) {
        ForEach(Array(result.words.enumerated()), id: \.offset) { _, word in
          Text(word.text).font(.caption2.bold()).padding(3)
            .foregroundStyle(word.offTarget ? Color.woodPaper : Color.woodInk)
            .background(word.offTarget ? Color.woodInk : Color.clear)
        }
      }
      if let rest = result.restText, !rest.isEmpty { Text(rest).font(.caption) }
    }.modifier(Plate(inset: 7)).allowsHitTesting(false)
  }
}

private struct PitchBoard: UIViewRepresentable {
  let pitch: PitchSession, model: GameModel, active: Bool, revision: Int, screen: GameModel.Screen
  func makeUIView(context: Context) -> BoardView { BoardView(pitch: pitch, model: model) }
  func updateUIView(_ view: BoardView, context: Context) {
    view.setActive(active)
    view.wake()
    view.setNeedsDisplay()
  }
  static func dismantleUIView(_ view: BoardView, coordinator: ()) { view.stop() }
}
