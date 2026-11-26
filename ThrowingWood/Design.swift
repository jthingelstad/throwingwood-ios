import KubbRenderer
import SwiftUI

// The Throwing Wood 1.0 system on the iPhone and iPad (kubb-sources design: the build
// list's "Shared by every client" and "iPhone and iPad", design/system/tokens.json).
// Ink outlines and hard ink shadows on flat paper; Londrina Solid Black for titles
// (sentence case), buttons, prompts and flags (capitals), never a body sentence; Inter
// for everything else; nothing under 14 pt. Every colour is the scene's skin
// (SceneSkin: the day's are the system's tokens), so a scene skins these as before.

/// The system's shapes (tokens.json: line, radius, shadow, touch).
enum TW {
  /// The ink outline of every card and control; a chip's.
  static let line: CGFloat = 3
  static let chipLine: CGFloat = 2
  /// Round corners (the owner, 2026-11-21): 6 on controls, 8 on cards.
  static let controlRadius: CGFloat = 6
  static let cardRadius: CGFloat = 8
  /// The hard shadow: 3 on controls, 5 on cards; a chip has none (it cannot be pressed).
  static let controlShadow: CGFloat = 3
  static let cardShadow: CGFloat = 5
  /// Every pressable thing on a phone; never under 44.
  static let touch: CGFloat = 48
  /// The card's padding (space-5) and the gap between its rows (space-3).
  static let cardPadding: CGFloat = 20
  static let rowGap: CGFloat = 12
  /// Every card's top edge under the safe top, upright (the build list's item 7).
  static let cardTop: CGFloat = 64
  /// pt from the screen's sides to a card on a phone held upright.
  static let cardSide: CGFloat = 16
  /// How far a card's scrolling rows fade at the cut while more rows are below.
  static let moreBelowFade: CGFloat = 36
}

@MainActor extension Color {
  /// The insides of things (the header plate, chips, instrument faces).
  static var woodBaton: Color { Color(skin.baton) }
  /// A segmented bar's parts not chosen.
  static var woodField: Color { Color(skin.field) }
  static var woodMuted: Color { Color(skin.muted) }
}

// MARK: - Type

/// Inter (bundled, its OFL beside it in Fonts), scaled with Dynamic Type from `size` at
/// the default text size.
func bodyFont(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
  .custom("Inter", size: size, relativeTo: style).weight(weight)
}

/// Londrina Solid Black, scaled with Dynamic Type.
func displayFont(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
  .custom("LondrinaSolid-Black", size: size, relativeTo: style)
}

extension View {
  /// A row label or kicker: Inter bold 14, capitals, 0.06 em tracking.
  func labelStyle() -> some View {
    font(bodyFont(14, .bold, relativeTo: .subheadline)).tracking(14 * 0.06).textCase(.uppercase)
  }
  /// A card's title: Londrina at 34, sentence case.
  func cardTitle(_ size: CGFloat = 34) -> some View {
    font(displayFont(size, relativeTo: .largeTitle)).foregroundStyle(Color.woodInk)
      .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
  }
  /// Helper text: Inter 14 in the muted colour.
  func helperText() -> some View {
    font(bodyFont(14, relativeTo: .footnote)).foregroundStyle(Color.woodMuted)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - The three buttons

/// The quiet button: underlined display capitals with a full touch target, for leaving
/// (HOME, RESIGN, NOT NOW, JUST WATCH).
struct QuietButton: View {
  let title: String
  let action: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }
  var body: some View {
    Button(action: action) {
      Text(title).font(displayFont(20, relativeTo: .headline)).underline(true, color: .woodInk)
        .foregroundStyle(Color.woodInk).lineLimit(1).minimumScaleFactor(0.7)
        .padding(.horizontal, 8).frame(minWidth: TW.touch, minHeight: TW.touch)
        .contentShape(Rectangle())
    }
    .buttonStyle(QuietPress())
  }
  private struct QuietPress: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
    }
  }
}

// MARK: - The segmented bar

/// One joined ink bar for two to four choices, the chosen part ink with paper type
/// (the build list's item 1): every two to four way choice on the iPhone (Settings, the
/// solo card, the lobby, the menu's Raising, the score sheet's positions). VoiceOver
/// reads the bar by its label and each part as "Clock, selected, 1 of 2"
/// (`SegmentWords`). `full`: the parts share the width given (a row whose control has
/// dropped under its label).
struct Segmented<Value: Hashable>: View {
  let label: String
  let choices: [(value: Value, text: String)]
  @Binding var value: Value
  var full = false
  @Environment(\.isEnabled) private var enabled
  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
        let on = c.value == value
        Button {
          if !on { value = c.value }
        } label: {
          Text(c.text).font(bodyFont(15, .bold, relativeTo: .subheadline))
            .lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(on ? Color.woodPaper : Color.woodInk)
            .padding(.horizontal, 12)
            .frame(minWidth: 52, maxWidth: full ? .infinity : nil, minHeight: TW.touch)
            .background(on ? Color.woodInk : Color.woodField)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(c.text)
        .accessibilityValue(SegmentWords.value(index: i, count: choices.count, selected: on))
        .accessibilityIdentifier("seg-\(label)-\(i)")
      }
    }
    // each part is the whole 48 pt tall (its touch); the bar's 3 pt ink line is drawn
    // over their outer edges, the 2 pt rules between them are the ink showing through
    .padding(.horizontal, TW.line - 1)
    .background(Color.woodInk)
    .clipShape(RoundedRectangle(cornerRadius: TW.controlRadius))
    .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
    .fixedSize(horizontal: !full, vertical: false)
    .opacity(enabled ? 1 : 0.55)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }
}

extension Segmented where Value == Bool {
  /// On and Off, as Sound and Haptics are.
  init(onOff label: String, value: Binding<Bool>, full: Bool = false) {
    self.init(label: label, choices: [(true, "On"), (false, "Off")], value: value, full: full)
  }
}

// MARK: - A card's row

/// A row: the label at the left in 14 pt capitals, its control at the right, 48 tall.
/// From the largest three text sizes, or where the two do not fit side by side, the
/// control drops under its label at full width (`stacked` tells the control so).
struct FormRow<Control: View>: View {
  let label: String
  @ViewBuilder let control: (_ stacked: Bool) -> Control
  @Environment(\.dynamicTypeSize) private var type
  init(_ label: String, @ViewBuilder control: @escaping (_ stacked: Bool) -> Control) {
    self.label = label
    self.control = control
  }
  var body: some View {
    if type >= .accessibility3 {
      stacked
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          title
          Spacer(minLength: 8)
          control(false)
        }.frame(minHeight: TW.touch)
        stacked
      }
    }
  }
  private var title: some View {
    Text(label).labelStyle().foregroundStyle(Color.woodInk).accessibilityHidden(true)
  }
  private var stacked: some View {
    VStack(alignment: .leading, spacing: 6) {
      title
      control(true).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A thin ink rule between a card's groups of rows.
struct Rule: View {
  var body: some View { Rectangle().fill(Color.woodInk).frame(height: 2).accessibilityHidden(true) }
}

// MARK: - The card

/// Every card (the build list's item 7): one top edge (64 pt under the safe top upright),
/// one dim over the pitch (ink at 50% in the day), the card's face (paper, a 3 pt ink
/// line, radius 8, a 5 pt shadow, 20 pt in). Its rows scroll where it does not fit (a
/// phone on its side, the largest text sizes) and its button row stays pinned in view
/// under them (but where that would leave the rows almost no room: the keyboard up on
/// a phone on its side). Upright on a phone it is the screen's width less 16 a side; elsewhere
/// (on its side, an iPad) it keeps `width`, centred.
struct CardScreen<Rows: View, Buttons: View>: View {
  var width: CGFloat = 400
  /// The card takes the height it is given (the score sheet's notation box).
  var fill = false
  /// No dim (a card over a card, or a screen with no pitch to dim).
  var dim = true
  @ViewBuilder let rows: () -> Rows
  @ViewBuilder let buttons: () -> Buttons
  @Environment(\.screenGeometry) private var screen
  /// The height the card's screen gives it (less where the keyboard is up) and its
  /// button row's own: where the rows would keep less than `FitHeightRule.rowsRoom`
  /// (a phone on its side with the keyboard up), the button row scrolls under them.
  @State private var room: CGFloat = .infinity
  @State private var buttonsHeight: CGFloat = 0
  var body: some View {
    let upright = !screen.wide
    let phone = UIDevice.current.userInterfaceIdiom == .phone
    let top = upright ? TW.cardTop : WideLayout.edge
    let pinned =
      fill
      || FitHeightRule.pinsButtons(
        room: Double(room - top - TW.cardSide - 2 * TW.cardPadding), buttons: Double(buttonsHeight))
    ZStack(alignment: .top) {
      if dim { SkinDim().ignoresSafeArea().accessibilityHidden(true) }
      VStack(alignment: .leading, spacing: 14) {
        if fill {
          rows().frame(maxHeight: .infinity, alignment: .top)
        } else {
          // one copy of the rows, always in the scroll view, as tall as they are where
          // they fit (FitHeight): never two copies to pick between, which swapped when
          // the keyboard took the room and dropped the focused field with its keyboard
          // (Send feedback, build 181 to 1.0.0)
          FitHeight {
            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                rows().fixedSize(horizontal: false, vertical: true)
                  .environment(\.cardShort, !pinned)
                if !pinned { buttonRow(upright: upright) }
              }
            }
            .scrollBounceBehavior(.basedOnSize).defaultScrollAnchor(Self.anchor)
            // no fade where the rows are short: it would fall on the line being typed
            .modifier(MoreBelow(fades: pinned))
          }
          // the rows are offered all the height the button row leaves (a VStack
          // would offer them a share), so a card that fits is shown whole
          .layoutPriority(1)
        }
        if pinned { buttonRow(upright: upright) }
      }
      .padding(TW.cardPadding)
      .frame(maxWidth: upright && phone ? .infinity : width, alignment: .leading)
      .modifier(CardFace())
      .padding(.horizontal, TW.cardSide)
      .padding(.top, top)
      .padding(.bottom, TW.cardSide)
      .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
  }

  /// The button row keeps its whole height, pinned under the rows; on its side a phone
  /// is about 390 pt tall, so there its words stop growing at the first accessibility
  /// size and the rows keep room to scroll.
  private func buttonRow(upright: Bool) -> some View {
    buttons().fixedSize(horizontal: false, vertical: true)
      .dynamicTypeSize(upright ? .xSmall ... .accessibility5 : .xSmall ... .accessibility1)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { buttonsHeight = $0 }
  }
}

extension EnvironmentValues {
  /// The card's rows have little room (a phone on its side with the keyboard up): a
  /// text field keeps to fewer lines, so the line being typed stays in view.
  @Entry var cardShort = false
}

/// Its one view as tall as it would be (a scroll view: its rows' height), and no taller
/// than it is offered: a card's rows shown whole where they fit and scrolling where they
/// do not, with one identity either way (`FitHeightRule`), so a focused text field keeps
/// its focus when the keyboard takes the room.
struct FitHeight: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let view = subviews.first else { return .zero }
    let ideal = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(
      width: proposal.width ?? ideal.width,
      height: CGFloat(FitHeightRule.height(ideal: Double(ideal.height), offered: proposal.height.map { Double($0) })))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}

extension CardScreen {
  /// Where a card's scrolling rows open: the top, or the foot for a review picture of
  /// a card's last rows (`REVIEW_CARD_FOOT`, the simulator only).
  static var anchor: UnitPoint {
    #if targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["REVIEW_CARD_FOOT"] != nil { return .bottom }
    #endif
    return .top
  }
}

extension CardScreen where Buttons == EmptyView {
  init(width: CGFloat = 400, fill: Bool = false, dim: Bool = true, @ViewBuilder rows: @escaping () -> Rows) {
    self.init(width: width, fill: fill, dim: dim, rows: rows, buttons: { EmptyView() })
  }
}

extension View {
  /// A card not redrawn by the 1.0 design keeps its rows and buttons and takes the
  /// shared shell: the top edge, the dim, the face, scrolling where it does not fit.
  func cardScreen(width: CGFloat = 400) -> some View {
    CardScreen(width: width) { self }
  }
}

/// Rows that scroll say so: the indicator flashes when they open, and while rows are
/// still below the cut the last few points fade into the paper, so a cut row (a phone
/// on its side shows a card's first rows only) reads as more to come, not as the end.
struct MoreBelow: ViewModifier {
  var fades = true
  @State private var below = false
  func body(content: Content) -> some View {
    content
      .scrollIndicatorsFlash(onAppear: true)
      .onScrollGeometryChange(for: Bool.self) { g in
        g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1
      } action: { _, more in below = more }
      .mask {
        VStack(spacing: 0) {
          Color.black
          LinearGradient(colors: [.black, below && fades ? .black.opacity(0.15) : .black],
                         startPoint: .top, endPoint: .bottom)
            .frame(height: TW.moreBelowFade)
        }
      }
  }
}

/// Where a card's foot line (the version) goes: under the button row as drawn, or at
/// the end of the scrolling rows where room is short (a phone on its side, the
/// accessibility text sizes), so the pinned button row stays small enough to show.
struct FootInRows {
  static func at(_ type: DynamicTypeSize, wide: Bool) -> Bool { wide || type.isAccessibilitySize }
}

/// A card's face: paper, the ink line, radius 8, the 5 pt hard shadow.
struct CardFace: ViewModifier {
  func body(content: Content) -> some View {
    content.foregroundStyle(Color.woodInk)
      .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.cardRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.cardRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
      .background(
        RoundedRectangle(cornerRadius: TW.cardRadius).fill(Color.woodDrop)
          .offset(x: TW.cardShadow, y: TW.cardShadow))
  }
}

/// A card's button row: the quiet buttons at the left, then the plain, the go last
/// (the system: go is last in its row). Where they do not fit side by side, they stack,
/// go at the foot and still at the right.
struct ButtonRow<Leading: View, Trailing: View>: View {
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let trailing: () -> Trailing
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        leading()
        Spacer(minLength: 0)
        trailing()
      }
      // one under the other where they do not fit side by side: the go still at the
      // right, last
      VStack(alignment: .leading, spacing: 10) {
        leading()
        HStack {
          Spacer(minLength: 0)
          trailing()
        }
      }
    }
  }
}

// MARK: - A chip

/// A chip: a 2 pt ink line, radius 6, no shadow (it cannot be pressed).
struct Chip: ViewModifier {
  var fill: Color = .woodBaton
  var ink: Color = .woodInk
  func body(content: Content) -> some View {
    content.font(bodyFont(14, .bold, relativeTo: .subheadline)).foregroundStyle(ink)
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(fill, in: RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.chipLine))
  }
}
