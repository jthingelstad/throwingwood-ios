import AVFAudio
import KubbRenderer
import SwiftUI

// The plates' colours: the scene's skin (Skin.swift), the day's as they always were.
@MainActor extension Color {
  static var woodInk: Color { Color(skin.ink) }
  static var woodPaper: Color { Color(skin.paper) }
  static var woodGold: Color { Color(skin.accent) }
  /// Type on the accent (a pressed choice, a gold button).
  static var woodOnGold: Color { Color(skin.onAccent) }
  /// A plate's hard shadow.
  static var woodDrop: Color { Color(skin.drop) }
}

/// A control's plate (the 1.0 system's control shape): a 3 pt ink line, radius 6 and a
/// 3 pt hard ink shadow. `fill` nil: the paper; `accent`: go, its type the skin's
/// on-accent.
struct Plate: ViewModifier {
  var fill: Color? = nil
  var accent = false
  var inset: CGFloat = 16
  func body(content: Content) -> some View {
    content.foregroundStyle(accent ? Color.woodOnGold : Color.woodInk).padding(inset)
      .background(fill ?? (accent ? .woodGold : .woodPaper), in: RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
      .background(
        RoundedRectangle(cornerRadius: TW.controlRadius).fill(Color.woodDrop)
          .offset(x: TW.controlShadow, y: TW.controlShadow))
  }
}

/// The plain button (paper) and, `accent`, the go button (marigold in the day, one per
/// screen, last in its row): display capitals at 20, 48 pt tall.
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
      configuration.label.font(.custom("LondrinaSolid-Black", size: 20, relativeTo: .headline))
        .frame(minHeight: TW.touch - 8).padding(.horizontal, 14)
        .modifier(Plate(accent: accent, inset: 4))
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
            meter: model.meter.kind, side: model.meter.side, look: model.shownScene,
            headerBottom: model.headerBottom
          )
          .id(ObjectIdentifier(pitch)).ignoresSafeArea().allowsHitTesting(live)
          if let version = model.online?.versionCard {
            VersionNotice(version: version) { model.online?.watch() }
          } else {
            switch model.screen {
            case .home: HomeCard(model: model)
            case .options: MatchOptionsCard(model: model)
            case .settings: SettingsCard(model: model)
            case .howTo: HowToCard(model: model)
            case .practiceMenu: PracticeMenu(model: model)
            case .practice: practice(wide: WideLayout.isWide(screen(geometry).size), room: meterRoom(geometry))
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
            case .reel:
              if let reel = model.reel { ReelCard(model: model, reel: reel) }
            case .share:
              if let share = model.share { ShareCard(model: model, share: share) }
            case .sealed:
              if let sealed = model.sealed { SealedCard(model: model, pitch: sealed) }
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
    // clear of an iPad window's controls (WindowControls.swift)
    .background(WindowControlsRoom().ignoresSafeArea())
    #if targetEnvironment(simulator)
      .modifier(OnlineReview(model: model))
      .modifier(ShareReview(model: model))
    #endif
    // a verdict is announced once when it comes, the off words first
    .onChange(of: model.result) { _, r in
      guard let r, UIAccessibility.isVoiceOverRunning else { return }
      AccessibilityNotification.Announcement(VerdictWords.spoken(flag: r.flag, words: r.words, rest: r.restText)).post()
    }
    .onOpenURL { model.join($0.absoluteString) }
    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { model.join(url.absoluteString) }
    }
    .onChange(of: phase, initial: true) { _, phase in
      model.feedback.setActive(phase == .active)
      if phase == .background {
        model.online?.background()
        model.reel?.hide()  // no asking in the background
      }
      if phase == .active {
        model.online?.connect()
        model.online?.pitch.retryNow()  // the web's visibilitychange: retry or ping at once
        if model.screen == .reel { model.reel?.show() }  // asks once and goes on
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NetworkPath.online).receive(on: RunLoop.main)) { _ in
      model.online?.pitch.retryNow()
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
    // a scene skins the system's controls too: its menus and pickers go dark
    .preferredColorScheme(SkinStore.shared.skin.isDay ? .light : .dark)
    .tint(SkinStore.shared.skin.isDay ? nil : Color(SkinStore.shared.skin.accent))
    .onChange(of: model.shownScene, initial: true) { _, id in SkinStore.shared.use(id) }
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
    // one sentence (a kept match made on an engine this build no longer carries)
    .alert(
      model.notice ?? "",
      isPresented: Binding(
        get: { model.notice != nil && model.error == nil },
        set: { if !$0 { model.notice = nil } })
    ) {
      Button("OK") { model.notice = nil }
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
  private func practice(wide: Bool, room: MeterRoom) -> some View {
    VStack(spacing: 10) {
      HStack {
        Button(action: model.home) { Image(systemName: "house.fill").frame(width: TW.touch, height: TW.touch) }
          .accessibilityLabel("Home")
        Text("Practice pitch").font(displayFont(28))
        Spacer()
        // the practice's own menu, a card (PracticeMenu): its rows are segmented bars
        Button {
          model.screen = .practiceMenu
        } label: {
          Text(HeaderWords.menu).font(displayFont(17, relativeTo: .headline)).foregroundStyle(Color.woodInk)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 12).frame(minHeight: TW.touch)
            .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(HeaderWords.menuLabel)
      }.modifier(Plate(inset: 8))
      // on its side the linear meter has its edge's whole height: the header stops short of it
      .padding(room.edge, wide ? room.width : 0)
      if let result = model.result { Verdict(result: result) }
      Spacer()
    }.padding(.horizontal, 14).padding(.top, wide ? WideLayout.edge : 0)
  }
}

/// The verdict after a throw (the 1.0 design, "Verdict: the reason leads"): the
/// engine's flag, then each off word first, inverted, 18 pt, with an arrow for its
/// direction (VerdictWords.arrow: down for SHORT and LOW, up for LONG and HIGH, left and
/// right for PULLED, a wavy line for SHAKY, a clock hand for SLOW), then the on-target
/// words as small chips after it, then the rest. Told by inversion and arrow, never by
/// colour alone. VoiceOver reads it as one element, the off words first; it is
/// announced once when it comes (GameView).
struct Verdict: View {
  let result: ThrowResult
  /// How much of it shows where the room is short (MatchScreen.wide fits the
  /// caption stack to `WideLayout.captionRoom`): all of it, the flag and the
  /// words, or the flag alone (the words where there is no flag).
  enum Cut { case full, short, flag }
  var cut = Cut.full
  /// The flag beside the words and the rest, for a wide, short room.
  var row = false
  var body: some View {
    Group {
      if row {
        HStack(spacing: 8) {
          flag
          VStack(alignment: .leading, spacing: 6) { words; rest }
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          flag
          if cut != .flag || result.flag == nil { words }
          if cut == .full { rest }
        }
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 8)
    .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.controlRadius))
    .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
    .background(
      RoundedRectangle(cornerRadius: TW.controlRadius).fill(Color.woodDrop)
        .offset(x: TW.controlShadow, y: TW.controlShadow))
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(VerdictWords.spoken(flag: result.flag, words: result.words, rest: result.restText))
  }
  // the caption strip online beside a linear meter on its side is as narrow
  // as 112.6 pt (the SE): a long flag (HELICOPTER) shrinks, never truncates
  @ViewBuilder private var flag: some View {
    if let flag = result.flag {
      Text(flag).font(displayFont(29, relativeTo: .title)).foregroundStyle(Color.woodInk)
        .lineLimit(1).minimumScaleFactor(0.6)
    }
  }
  private var words: some View {
    FlowRow(spacing: 6) {
      ForEach(Array(result.words.enumerated()), id: \.offset) { _, word in
        if word.offTarget {
          HStack(spacing: 6) {
            if let a = VerdictWords.arrow(word.text) { VerdictArrow(arrow: a).frame(width: 14, height: 14) }
            Text(word.text).font(bodyFont(18, .black, relativeTo: .body)).tracking(18 * 0.04)
              .lineLimit(1).minimumScaleFactor(0.7)
          }
          .foregroundStyle(Color.woodPaper)
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(Color.woodInk, in: RoundedRectangle(cornerRadius: TW.controlRadius))
        } else {
          Text(word.text).modifier(Chip())
        }
      }
    }
  }
  @ViewBuilder private var rest: some View {
    if let rest = result.restText, !rest.isEmpty {
      Text(rest).font(bodyFont(14, relativeTo: .footnote)).foregroundStyle(Color.woodInk)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// An off word's arrow, drawn in the chip's type colour.
struct VerdictArrow: View {
  let arrow: VerdictWords.Arrow
  var body: some View {
    Canvas { ctx, s in
      let w = s.width, h = s.height
      var p = Path()
      func chevron(_ tip: CGPoint, _ a: CGPoint, _ b: CGPoint) {
        p.move(to: a)
        p.addLine(to: tip)
        p.addLine(to: b)
      }
      switch arrow {
      case .down:
        p.move(to: CGPoint(x: w / 2, y: 1)); p.addLine(to: CGPoint(x: w / 2, y: h - 2))
        chevron(CGPoint(x: w / 2, y: h - 1), CGPoint(x: 2, y: h * 0.5), CGPoint(x: w - 2, y: h * 0.5))
      case .up:
        p.move(to: CGPoint(x: w / 2, y: h - 1)); p.addLine(to: CGPoint(x: w / 2, y: 2))
        chevron(CGPoint(x: w / 2, y: 1), CGPoint(x: 2, y: h * 0.5), CGPoint(x: w - 2, y: h * 0.5))
      case .left:
        p.move(to: CGPoint(x: w - 1, y: h / 2)); p.addLine(to: CGPoint(x: 2, y: h / 2))
        chevron(CGPoint(x: 1, y: h / 2), CGPoint(x: w * 0.5, y: 2), CGPoint(x: w * 0.5, y: h - 2))
      case .right:
        p.move(to: CGPoint(x: 1, y: h / 2)); p.addLine(to: CGPoint(x: w - 2, y: h / 2))
        chevron(CGPoint(x: w - 1, y: h / 2), CGPoint(x: w * 0.5, y: 2), CGPoint(x: w * 0.5, y: h - 2))
      case .wavy:
        p.move(to: CGPoint(x: 0, y: h / 2))
        p.addCurve(to: CGPoint(x: w / 2, y: h / 2), control1: CGPoint(x: w * 0.15, y: 1), control2: CGPoint(x: w * 0.35, y: 1))
        p.addCurve(to: CGPoint(x: w, y: h / 2), control1: CGPoint(x: w * 0.65, y: h - 1), control2: CGPoint(x: w * 0.85, y: h - 1))
      case .clock:
        p.addEllipse(in: CGRect(x: 1.25, y: 1.25, width: w - 2.5, height: h - 2.5))
        p.move(to: CGPoint(x: w / 2, y: h / 2)); p.addLine(to: CGPoint(x: w / 2, y: 3.5))
        p.move(to: CGPoint(x: w / 2, y: h / 2)); p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.62))
      }
      ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
    .accessibilityHidden(true)
  }
}

/// Views in a row, wrapping onto the next line where the width runs out.
struct FlowRow: Layout {
  var spacing: CGFloat = 6
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
    for s in subviews {
      let d = s.sizeThatFits(.init(width: width, height: nil))
      if x > 0 && x + d.width > width {
        y += line + spacing
        x = 0
        line = 0
      }
      x += d.width + spacing
      line = max(line, d.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(widest, width), height: y + line)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for s in subviews {
      let d = s.sizeThatFits(.init(width: bounds.width, height: nil))
      if x > bounds.minX && x + d.width > bounds.maxX {
        y += line + spacing
        x = bounds.minX
        line = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: .init(width: min(d.width, bounds.width), height: d.height))
      x += d.width + spacing
      line = max(line, d.height)
    }
  }
}

private struct PitchBoard: UIViewRepresentable {
  let pitch: PitchSession, model: GameModel, active: Bool, revision: Int, screen: GameModel.Screen
  let meter: MeterKind, side: MeterSide
  /// The scene on the screen: a change draws the pitch again.
  let look: String
  /// The header's foot (upright): the minimap hangs under it, so a change draws again.
  let headerBottom: CGFloat?
  func makeUIView(context: Context) -> BoardView { BoardView(pitch: pitch, model: model) }
  func updateUIView(_ view: BoardView, context: Context) {
    // in a match the drawn controls are read through MatchScreen's readers, in order
    view.isAccessibilityElement = screen != .match
    view.accessibilityLabel = screen == .match ? nil : BoardView.practiceWords
    view.setActive(active)
    view.wake()
    view.setNeedsDisplay()
  }
  static func dismantleUIView(_ view: BoardView, coordinator: ()) { view.stop() }
}
