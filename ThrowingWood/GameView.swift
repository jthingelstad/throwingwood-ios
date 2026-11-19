import AVFAudio
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
    Face(configuration: configuration, accent: accent)
  }
  /// A style cannot read the environment itself, and a button that will not act
  /// must not look as if it will (the web's .btn:disabled).
  private struct Face: View {
    let configuration: Configuration
    let accent: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
      configuration.label.font(.custom("LondrinaSolid-Black", size: 21, relativeTo: .headline))
        .frame(minHeight: 26).padding(.horizontal, 6)
        .modifier(Plate(fill: accent ? .woodGold : .woodPaper, inset: 8))
        .offset(y: configuration.isPressed && enabled ? 2 : 0)
        .opacity(enabled ? 1 : 0.55)
    }
  }
}

/// A card that fits the screen is shown whole; one that does not (a phone on its
/// side is about 390 pt tall) scrolls.
struct FitOrScroll: ViewModifier {
  func body(content: Content) -> some View {
    ViewThatFits(in: .vertical) {
      content
      ScrollView { content }.scrollBounceBehavior(.basedOnSize).defaultScrollAnchor(.top)
    }
  }
}

func displayFont(_ size: CGFloat) -> Font { .custom("LondrinaSolid-Black", size: size) }

struct GameView: View {
  @State private var model = GameModel()
  @Environment(\.scenePhase) private var phase
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        if let pitch = model.pitch {
          let live = model.screen == .practice || model.screen == .match
          PitchBoard(
            pitch: pitch, model: model, active: live && phase == .active && model.error == nil,
            revision: model.revision + model.onlineRevision, screen: model.screen,
            meter: model.meter.kind, side: model.meter.side
          )
          .id(ObjectIdentifier(pitch)).ignoresSafeArea().allowsHitTesting(live)
          if let version = model.online?.versionCard {
            VersionNotice(version: version) { model.online?.watch() }
          } else {
            switch model.screen {
            case .home: HomeCard(model: model)
            case .options: MatchOptionsCard(model: model)
            case .practice: practice(wide: WideLayout.isWide(screen(geometry).size))
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
              if let report = model.report {
                ReportCard(model: model, report: report, kind: reviewReportKind)
              }
            case .sheet:
              if let sheet = model.sheet {
                SheetCard(sheet: sheet) { model.screen = model.sheetReturn }
              }
            }
          }
        }
      }
      .environment(\.reportViewport, geometry.size)
      .environment(\.meterRoom, meterRoom(geometry))
      .environment(\.screenGeometry, screen(geometry))
    }
    #if targetEnvironment(simulator)
      .modifier(OnlineReview(model: model))
    #endif
    .onOpenURL { model.join($0.absoluteString) }
    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { model.join(url.absoluteString) }
    }
    .onChange(of: phase, initial: true) { _, phase in
      model.feedback.setActive(phase == .active)
      if phase == .background { model.online?.background() }
      if phase == .active { model.online?.connect() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange).receive(on: RunLoop.main)) { _ in
      model.feedback.prepare()
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { note in
      if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.ended.rawValue {
        model.feedback.prepare()
      }
    }
    .onDisappear {
      model.feedback.setActive(false)
      model.online?.close()
    }
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

  /// The feedback card's kind in the simulator's "report" and "feedback" reviews (else the
  /// card's default).
  private var reviewReportKind: ReportCard.Kind? {
    #if targetEnvironment(simulator)
      switch ProcessInfo.processInfo.environment["ONLINE_REVIEW"] {
      case "report": .throw  // the review's match has no last throw yet
      case "feedback": .feedback
      default: nil
      }
    #else
      nil
    #endif
  }

  private func screen(_ g: GeometryProxy) -> ScreenGeometry {
    let i = g.safeAreaInsets
    return ScreenGeometry(
      size: CGSize(width: g.size.width + i.leading + i.trailing, height: g.size.height + i.top + i.bottom),
      safe: ScreenInsets(top: i.top, left: i.leading, bottom: i.bottom, right: i.trailing))
  }

  /// The room the linear meter takes, in the safe area's coordinates: the
  /// plan's buttons keep out of it.
  private func meterRoom(_ g: GeometryProxy) -> MeterRoom {
    let i = g.safeAreaInsets
    let full = CGRect(x: 0, y: 0, width: g.size.width + i.leading + i.trailing, height: g.size.height + i.top + i.bottom)
    let safe = UIEdgeInsets(top: i.top, left: i.leading, bottom: i.bottom, right: i.trailing)
    guard let m = model.meter.layout(bounds: full, safe: safe).linear else { return MeterRoom() }
    // the screens pad their rows 12 from the safe area's edge; leave 8 more
    if m.side == .right {
      return MeterRoom(edge: .trailing, width: max(0, full.width - i.trailing - m.left - 12 + 8))
    }
    return MeterRoom(edge: .leading, width: max(0, m.right + m.shadow - i.leading - 12 + 8))
  }

  /// On a phone on its side there is no status bar: the header keeps the rail's
  /// distance from the top.
  private func practice(wide: Bool) -> some View {
    VStack(spacing: 10) {
      HStack {
        Button(action: model.home) { Image(systemName: "house.fill").frame(width: 36, height: 36) }
          .accessibilityLabel("Home")
        Text("Practice pitch").font(displayFont(28))
        Spacer()
        Menu {
          // each row says what it sets and shows its value (the web's menu)
          Picker(
            "Surface",
            selection: Binding(
              get: { model.surface },
              set: { s in model.perform { try model.pitch?.surface(s) } })
          ) {
            ForEach(Surface.allCases, id: \.self) { s in Text(s.rawValue.capitalized).tag(s) }
          }
          .pickerStyle(.menu).disabled(model.playing)
          ReportButton(model: model)
          FeedbackSettings(feedback: model.feedback)
          MeterSettings(meter: model.meter)
        } label: {
          Label("Menu", systemImage: "line.3.horizontal")
        }
      }.modifier(Plate(inset: 8))
      if let result = model.result { Verdict(result: result) }
      Spacer()
    }.padding(.horizontal, 14).padding(.top, wide ? WideLayout.edge : 0)
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
  let meter: MeterKind, side: MeterSide
  func makeUIView(context: Context) -> BoardView { BoardView(pitch: pitch, model: model) }
  func updateUIView(_ view: BoardView, context: Context) {
    view.setActive(active)
    view.wake()
    view.setNeedsDisplay()
  }
  static func dismantleUIView(_ view: BoardView, coordinator: ()) { view.stop() }
}
