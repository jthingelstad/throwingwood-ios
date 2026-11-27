import KubbRenderer
import SwiftUI
import UIKit

// Home (the owner, 2026-11-27: "The first screen for the iOS app needs to pull people in
// more ... this screen lacks the finesse and polish of the rest of the app."): a real
// match plays behind it (HomeMatch, the computer against the computer in the Park scene),
// and the controls sit on their own grounds over it, never as words on the grass. The
// title is a plate across the top like a match's header, with SETTINGS inside it as MENU
// is inside the header; the three ways to play are one card at the foot, go last; the
// version is that card's foot line. docs/RENDER.md "Home".

/// Home: the masthead at the top and the play card at the foot, the match between them.
/// Upright the card is two plain buttons over the go button; on a wide screen (a phone on
/// its side, an iPad window that is not tall) its three buttons are one row, go last.
/// Where the text is too large for that, the card stacks, and the screen scrolls.
struct HomeCard: View {
  let model: GameModel
  @Environment(\.screenGeometry) private var screen
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    let wide = screen.wide
    ViewThatFits(in: .vertical) {
      layout(wide: wide)
      ScrollView {
        layout(wide: wide, scrolls: true)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .accessibilityElement(children: .contain)
  }

  /// The width the masthead and the card keep: the screen's less its margins upright on
  /// a phone; on a wide screen or an iPad, at most `HomeLayout.width`.
  private func layout(wide: Bool, scrolls: Bool = false) -> some View {
    let phone = UIDevice.current.userInterfaceIdiom == .phone
    let width: CGFloat? = wide ? HomeLayout.wideWidth : (phone ? nil : HomeLayout.width)
    return VStack(spacing: 0) {
      HomeMasthead(model: model, wide: wide)
        .frame(maxWidth: wide ? HomeLayout.mastheadWide : width)
        .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
      Spacer(minLength: HomeLayout.gap)
      HomePlay(model: model, wide: wide && !type.isAccessibilitySize)
        .frame(maxWidth: width)
        .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, HomeLayout.side)
    .padding(.top, wide ? WideLayout.edge : HomeLayout.top)
    .padding(.bottom, HomeLayout.bottom)
    .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : .infinity)
  }
}

/// Home's numbers, in one place.
enum HomeLayout {
  /// pt from the screen's sides (the match header's 14; the cards' 16).
  static let side: CGFloat = 14
  /// pt under the safe top upright (on a wide screen `WideLayout.edge`, as the header).
  static let top: CGFloat = 8
  /// pt over the safe bottom.
  static let bottom: CGFloat = 10
  /// The least room between the masthead and the card (where the screen is short).
  static let gap: CGFloat = 16
  /// The masthead and the card on an iPad held upright.
  static let width: CGFloat = 520
  /// The card on a wide screen (its one row) and the masthead there (the header's width).
  static let wideWidth: CGFloat = 600
  static let mastheadWide: CGFloat = 400
}

/// The masthead: KUBB over THROWING WOOD on the header's plate, and SETTINGS inside it at
/// the right, as MENU is inside a match's header (the 1.0 design): a quiet way to the
/// device's settings, off the way to play.
struct HomeMasthead: View {
  let model: GameModel
  let wide: Bool
  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: wide ? -3 : -5) {
        Text("KUBB").font(displayFont(wide ? 38 : 50, relativeTo: .largeTitle))
        Text("THROWING WOOD").font(displayFont(wide ? 17 : 21, relativeTo: .title3))
      }
      .foregroundStyle(Color.woodInk)
      .lineLimit(1).minimumScaleFactor(0.6)
      .padding(.vertical, wide ? 2 : 4)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Kubb: Throwing Wood")
      .accessibilityAddTraits(.isHeader)
      .accessibilitySortPriority(4)
      Spacer(minLength: 4)
      HomeSettingsButton(action: model.openSettings)
        .accessibilitySortPriority(0.5)
    }
    .padding(.leading, 10)
    .modifier(Plate(fill: .woodBaton, inset: 6))
  }
}

/// SETTINGS inside the masthead: the header's own button (MENU's: paper, a 2 pt ink line,
/// display capitals at 17), with the gear before the word; the gear alone where the word
/// would not fit (the largest text sizes). 48 pt tall, read "Settings".
struct HomeSettingsButton: View {
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          gear
          Text("SETTINGS").font(displayFont(17, relativeTo: .headline)).lineLimit(1).fixedSize()
        }
        gear
      }
      .foregroundStyle(Color.woodInk)
      .padding(.horizontal, 12).frame(minWidth: TW.touch, minHeight: TW.touch)
      .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: 2))
      .contentShape(Rectangle())
    }
    .buttonStyle(HeaderPress())
    .accessibilityLabel("Settings")
    .accessibilityHint("Your name, sound, haptics, the meter and the app icon")
  }
  private var gear: some View {
    Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .bold)).accessibilityHidden(true)
  }
  private struct HeaderPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
  }
}

/// The three ways to play on one card at the foot (the 1.0 system: paper, a 3 pt ink
/// line, radius 8, the 5 pt hard shadow): PLAY ONLINE and PRACTICE plain, PLAY THE
/// COMPUTER the screen's one go button, last (upright the row under the other two; wide,
/// the row's right end). The version (`VersionLabel`) is its foot line. VoiceOver reads
/// the title, the go button, PLAY ONLINE, PRACTICE, Settings, then the version (the
/// priorities are all in HomeCard's one container).
struct HomePlay: View {
  let model: GameModel
  let wide: Bool
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    VStack(spacing: 12) {
      if wide {
        // the two plain buttons as wide as their words, the go button the rest
        HStack(spacing: 12) {
          online.fixedSize(horizontal: true, vertical: false)
          practice.fixedSize(horizontal: true, vertical: false)
          computer
        }
      } else if type.isAccessibilitySize {
        VStack(spacing: 12) {
          online
          practice
          computer
        }
      } else {
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            online
            practice
          }
          computer
        }
      }
      if let label = model.pitch?.versionLabel {
        Text("Throwing Wood \(label.text)")
          .font(bodyFont(14, relativeTo: .footnote)).foregroundStyle(Color.woodMuted)
          .lineLimit(1).minimumScaleFactor(0.8)
          .accessibilitySortPriority(-1)
      }
    }
    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    .modifier(CardFace())
  }

  private var computer: some View {
    Button(action: model.solo) {
      Text("PLAY THE COMPUTER").frame(maxWidth: .infinity)
    }
    .buttonStyle(WoodButton(accent: true))
    .accessibilitySortPriority(3)
  }
  private var online: some View {
    Button {
      model.screen = .onlineEntry
    } label: {
      Text("PLAY ONLINE").frame(maxWidth: .infinity)
    }
    .buttonStyle(WoodButton(side: 10))
    .accessibilitySortPriority(2)
  }
  private var practice: some View {
    Button(action: model.openPractice) {
      Text("PRACTICE").frame(maxWidth: .infinity)
    }
    .buttonStyle(WoodButton(side: 10))
    .accessibilitySortPriority(1)
  }
}

// MARK: - The match behind it

/// The home match drawn behind home (HomeMatch): its own view and display link, so the
/// pitch board under it is left alone. Nothing until the first throw has come (the still
/// pitch under it shows), and nothing for VoiceOver or touch.
struct HomeBackdrop: UIViewRepresentable {
  let match: HomeMatch
  func makeUIView(context: Context) -> HomeBackdropView { HomeBackdropView(match: match) }
  func updateUIView(_ view: HomeBackdropView, context: Context) {}
  static func dismantleUIView(_ view: HomeBackdropView, coordinator: ()) { view.stop() }
}

@MainActor final class HomeBackdropView: UIView {
  let match: HomeMatch
  private var link: CADisplayLink?
  private var previous: CFTimeInterval?
  #if targetEnvironment(simulator)
    /// The review picture: one moment of a match of a fixed seed, held still.
    private let review = ProcessInfo.processInfo.environment["MATCH_REVIEW"] == "home"
    private var posed = false
    /// HOME_TIMING: the main thread's cost of the home match, logged every 600 frames.
    private var timing = ProcessInfo.processInfo.environment["HOME_TIMING"] != nil ? HomeTiming() : nil
  #endif

  init(match: HomeMatch) {
    self.match = match
    super.init(frame: .zero)
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
  }
  required init?(coder: NSCoder) { nil }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if let window {
      // the board's backing: at most 2x, scaled up on a 3x screen
      contentScaleFactor = min(window.traitCollection.displayScale, 2)
      start()
    } else {
      stop()
    }
  }

  private func start() {
    guard link == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
    // the match reads well at 60 a second; a ProMotion screen's 120 would only cost battery
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    self.link = link
  }
  func stop() {
    link?.invalidate()
    link = nil
    previous = nil
  }

  @objc private func frame(_ link: CADisplayLink) {
    let now = link.targetTimestamp
    let dt = previous.map { now - $0 } ?? (now - link.timestamp)
    previous = now
    #if targetEnvironment(simulator)
      if review {
        poseForReview()
        return
      }
    #endif
    #if targetEnvironment(simulator)
      let t0 = CACurrentMediaTime()
      defer { timing?.tick(CACurrentMediaTime() - t0, dt: dt) }
    #endif
    if match.tick(dt) { setNeedsDisplay() }
  }

  #if targetEnvironment(simulator)
    /// Once the screen has its size and has turned: the match played headless to its
    /// moment (HOME_THROW, the throw shown, and HOME_AT, how far through its flight), drawn
    /// once, and the review tool told.
    private func poseForReview() {
      guard !posed, !bounds.isEmpty, ReviewOrientation.settled(bounds.size), match.state == .on else { return }
      posed = true
      let env = ProcessInfo.processInfo.environment
      let n = Int(env["HOME_THROW"] ?? "") ?? HomeReview.throwShown
      let at = Double(env["HOME_AT"] ?? "") ?? HomeReview.at
      match.play(toThrow: n, at: at)
      setNeedsDisplay()
      link?.isPaused = true
      DispatchQueue.main.async {
        try? Data("home".utf8).write(to: URL.temporaryDirectory.appending(path: "review-ready"), options: .atomic)
      }
    }
  #endif

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    #if targetEnvironment(simulator)
      let t0 = CACurrentMediaTime()
      defer { timing?.draw(CACurrentMediaTime() - t0) }
    #endif
    match.draw(in: ctx, size: bounds.size)
  }
}

#if targetEnvironment(simulator)
  /// The home match's main-thread cost on the simulator (HOME_TIMING): each frame's tick
  /// and draw in ms, and frames longer than 1.5 of the display's.
  struct HomeTiming {
    private var ticks: [Double] = [], draws: [Double] = [], late = 0
    mutating func tick(_ s: Double, dt: Double) {
      ticks.append(s * 1000)
      if dt > 1.5 / 60 { late += 1 }
      guard ticks.count >= 600 else { return }
      func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
      func p95(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[Int(Double(a.count - 1) * 0.95)] }
      print(String(format: "home timing: tick %.3f ms (p95 %.3f), draw %.2f ms (p95 %.2f) over %d draws, %d late frames of 600",
        mean(ticks), p95(ticks), mean(draws), p95(draws), draws.count, late))
      ticks = []
      draws = []
      late = 0
    }
    mutating func draw(_ s: Double) { draws.append(s * 1000) }
  }
#endif

/// The review pictures' home match: its seed and the moment shown.
enum HomeReview {
  static let seed = 7
  static let throwShown = 3
  static let at = 0.15
}
