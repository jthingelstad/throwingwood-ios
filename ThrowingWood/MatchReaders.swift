import KubbRenderer
import SwiftUI

/// What VoiceOver reads of the pitch's drawn controls, in the build list's order: after
/// the header, the prompt and the distance ("Wind back, 8 metres"), then the meter; after
/// the tray, the minimap as one image with a spoken summary (`MapReader`). The meter and
/// the minimap are drawn by BoardView (Core Graphics); these are invisible elements on
/// their frames, so the order is the screen's and nothing drawn is left unread.
struct MeterReader: View {
  let model: GameModel, pitch: PitchSession, need: MatchNeed, playing: Bool
  @Environment(\.screenGeometry) private var screen

  var body: some View {
    let shown = !playing && need.kind == "throw" && pitch.handoff == nil && !pitch.wideOn && need.winner == nil
    ZStack(alignment: .topLeading) {
      Color.clear
      if shown {
        let meter = model.meter.layout(
          bounds: CGRect(origin: .zero, size: screen.size),
          safe: UIEdgeInsets(top: screen.safe.top, left: screen.safe.left, bottom: screen.safe.bottom, right: screen.safe.right))
        let watching = !pitch.canAim
        let linear = meter.linear != nil
        let prompt = watching ? MeterWords.watch : (linear ? linearWords(pitch.dial.prompt) : pitch.dial.prompt)
        let frames = Self.frames(meter)
        if let words = MeterWords.spokenPrompt(prompt, metres: watching ? nil : pitch.distance) {
          element(frames.prompt)
            .accessibilityLabel(words)
            .accessibilitySortPriority(2)
        }
        element(frames.meter)
          .accessibilityLabel(MeterWords.spokenMeter(linear: linear, watching: watching))
          .accessibilitySortPriority(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityElement(children: .contain)
  }

  private func element(_ f: CGRect) -> some View {
    Color.clear.frame(width: max(1, f.width), height: max(1, f.height))
      .offset(x: f.minX, y: f.minY)
      .accessibilityElement()
      .accessibilityAddTraits(.isStaticText)
  }

  /// The prompt's and the meter's frames, as BoardView draws them.
  static func frames(_ meter: MeterLayout) -> (prompt: CGRect, meter: CGRect) {
    switch meter {
    case .clock(let c):
      let p = CGRect(x: c.center.x - 90, y: c.center.y - c.radius - 38, width: 180, height: 36)
      let m = CGRect(x: c.center.x - c.radius, y: c.center.y - c.radius, width: 2 * c.radius, height: 2 * c.radius)
      return (p, m)
    case .linear(let l):
      return (l.tab, l.cover)
    }
  }
}

/// The minimap as one image with a spoken summary (PitchScene.mapSummary), on its frame.
struct MapReader: View {
  let model: GameModel, pitch: PitchSession, need: MatchNeed
  @Environment(\.screenGeometry) private var screen

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear
      if need.kind == "throw", pitch.handoff == nil, !pitch.wideOn, need.winner == nil,
        let f = BoardView.minimapFrame(model: model, size: screen.size, safe: screen.safe)
      {
        Color.clear.frame(width: f.width, height: f.height)
          .offset(x: f.minX, y: f.minY)
          .accessibilityElement()
          .accessibilityAddTraits(.isImage)
          .accessibilityLabel(
            MeterWords.mapSummary(standing: need.standing, teams: need.teams, metres: pitch.canAim ? pitch.distance : nil))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityElement(children: .contain)
  }
}
