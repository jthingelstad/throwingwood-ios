import KubbPitch
import KubbRenderer
import SwiftUI

// HOLLER on a shared pitch: the button, its panel of preset phrases and emoji, and the
// hollers that arrive. The lists are `Holler` (KubbPitch), the web's docs/MULTIPLAYER.md
// "What the iPhone app mirrors"; nothing else is ever sent or drawn.

/// Where the hollers come from and go: the pitch (OnlinePitch), or the simulator
/// review's stand-in.
@MainActor protocol HollerSource: AnyObject {
  var shouts: [ShownHoller] { get }
  var observing: Bool { get }
  func shout(_ piece: Holler.Piece)
}

extension OnlinePitch: HollerSource {}

/// HOLLER: one tap opens the panel, a second closes it. An observer has none (the web's
/// docs/OBSERVER.md): it watches.
struct HollerButton: View {
  let model: GameModel
  /// On a wide screen it keeps to SHOUT's old frame (`WideLayout.shoutSize`), which the
  /// captions are laid out round: the longer word takes less room each side, and
  /// shrinks a little where that is not enough.
  var wide = false
  var body: some View {
    Button(HollerWords.button) {
      model.hollerOpen.toggle()
    }
    .buttonStyle(WoodButton(accent: false, side: wide ? 9 : 14))
    .frame(maxWidth: wide ? WideLayout.shoutSize.width : nil, alignment: .trailing)
    .accessibilityLabel(HollerWords.buttonLabel)
    .accessibilityHint(model.hollerOpen ? "" : HollerWords.buttonHint)
    .accessibilityAddTraits(model.hollerOpen ? .isSelected : [])
    .accessibilityIdentifier("holler")
  }
}

enum HollerWords {
  static let button = "HOLLER"
  static let buttonLabel = "Holler"
  static let buttonHint = "Opens phrases and emoji to send to everyone on the pitch."
  static let emoji = "Emoji"
}

/// The panel: the four groups on a segmented bar, the chosen group's six phrases, and
/// the twelve emoji under a rule on the baton colour, so the two kinds are told apart at
/// a glance. One tap on any of them sends it and closes the panel. It is laid out for
/// the room it is given (`HollerLayout`), clear of the meter and the tray, and scrolls
/// inside itself where that room is short.
struct HollerPanel: View {
  let model: GameModel
  let source: any HollerSource
  let room: CGSize
  @State private var group = Holler.groups[0].id

  var body: some View {
    let cols = HollerLayout.columns(width: room.width)
    VStack(spacing: 10) {
      Segmented(
        label: "Holler group", choices: Holler.groups.map { ($0.id, $0.name) }, value: $group, full: true)
      let phrases = Holler.groups.first { $0.id == group }?.phrases ?? []
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols.phrases), spacing: 8
      ) {
        ForEach(phrases, id: \.self) { w in
          Button {
            send(.phrase(w))
          } label: {
            Text(w).font(displayFont(18, relativeTo: .headline)).foregroundStyle(Color.woodInk)
              .lineLimit(1).minimumScaleFactor(0.6)
              .frame(maxWidth: .infinity, minHeight: TW.touch)
              .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.controlRadius))
              .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: 2))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(w.capitalized)
          .accessibilityHint(groupName + ". Sends it to everyone.")
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(groupName)
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols.emoji), spacing: 6
      ) {
        ForEach(Holler.emoji, id: \.self) { e in
          Button {
            send(.emoji(e))
          } label: {
            Text(e).font(.system(size: 28)).dynamicTypeSize(.large)
              .frame(maxWidth: .infinity, minHeight: TW.touch)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Holler.emojiNames[e] ?? e)
          .accessibilityHint("Emoji. Sends it to everyone.")
        }
      }
      .padding(6)
      .background(Color.woodBaton, in: RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: 2))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(HollerWords.emoji)
    }
    .padding(10)
    .modifier(FitHollerRoom(height: room.height))
    .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.cardRadius))
    .overlay(RoundedRectangle(cornerRadius: TW.cardRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
    .background(
      RoundedRectangle(cornerRadius: TW.cardRadius).fill(Color.woodDrop)
        .offset(x: TW.cardShadow, y: TW.cardShadow))
    .frame(width: room.width)
    // a panel over the pitch: its words stop growing at the first accessibility size
    .dynamicTypeSize(.xSmall ... .accessibility1)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Holler")
    .accessibilityAction(.escape) { model.hollerOpen = false }
  }

  private var groupName: String { Holler.groups.first { $0.id == group }?.name ?? "" }

  private func send(_ piece: Holler.Piece) {
    source.shout(piece)
    model.hollerOpen = false
  }
}

/// The panel's rows, as tall as they are where the room has them, scrolling inside where
/// it does not (a phone on its side).
private struct FitHollerRoom: ViewModifier {
  let height: CGFloat
  func body(content: Content) -> some View {
    CapHeight(max: height - TW.cardShadow) {
      FitHeight {
        ScrollView { content.fixedSize(horizontal: false, vertical: true) }
          .scrollBounceBehavior(.basedOnSize)
      }
    }
  }
}

/// Offers its content at most `max` of height and is as tall as the content.
private struct CapHeight: Layout {
  let max: CGFloat
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let v = subviews.first else { return .zero }
    let h = proposal.height.map { Swift.min($0, max) } ?? max
    return v.sizeThatFits(ProposedViewSize(width: proposal.width, height: h))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

/// The hollers on screen, newest last: the sender's name beside the phrase in display
/// capitals, or beside the emoji drawn clearly larger. VoiceOver reads "Mighty Maple:
/// NICE!".
struct HollerFeed: View {
  let source: any HollerSource
  var alignment: HorizontalAlignment = .trailing
  /// The most height the hollers may take (HollerLayout.feedHeight): the newest that fit.
  var height: CGFloat = .infinity
  /// An emoji's size: twice a phrase's upright, a little less where the room is short.
  var emojiSize: CGFloat = 40
  /// A holler's plate's height at the default text size (measured on the review phones):
  /// an emoji's is taller.
  private func plateHeight(_ s: ShownHoller) -> CGFloat { s.piece.isEmoji ? emojiSize + 18 : 32 }
  var body: some View {
    let all = source.shouts
    let n = HollerLayout.feedCount(heights: all.map(plateHeight), height: height)
    VStack(alignment: alignment, spacing: 6) {
      ForEach(Array(all.suffix(n).enumerated()), id: \.offset) { _, s in
        HStack(alignment: .center, spacing: 8) {
          Text(s.name).font(bodyFont(14, .bold, relativeTo: .footnote)).foregroundStyle(Color.woodInk)
            .lineLimit(1).minimumScaleFactor(0.8)
          if s.piece.isEmoji {
            Text(s.piece.text).font(.system(size: emojiSize)).dynamicTypeSize(.large)
          } else {
            Text(s.piece.text).font(displayFont(20, relativeTo: .headline)).foregroundStyle(Color.woodInk)
              .lineLimit(1).minimumScaleFactor(0.7)
          }
        }
        .modifier(Plate(inset: 5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.spoken)
      }
    }
    .dynamicTypeSize(.xSmall ... .accessibility1)
  }
}

#if targetEnvironment(simulator)
  /// The review pictures' HOLLER with no pitch server (MATCH_REVIEW "holler" opens the
  /// panel, "hollered" shows a phrase and an emoji arrived): a solo match drawn as a
  /// pitch's, only invented names. Sending shows the holler as the pitch would.
  @MainActor @Observable final class ReviewHoller: HollerSource {
    private(set) var shouts: [ShownHoller] = []
    let observing = false
    init(arrived: Bool) {
      if arrived {
        shouts = [
          ShownHoller(name: "Mighty Maple", piece: .phrase("KNOCKERHEAD!")),
          ShownHoller(name: "Brave Birch", piece: .emoji("🔥")),
        ]
      }
    }
    func shout(_ piece: Holler.Piece) {
      shouts.append(ShownHoller(name: "Brave Birch", piece: piece))
      if shouts.count > 4 { shouts.removeFirst() }
    }
  }
#endif
