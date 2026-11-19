import KubbRenderer
import SwiftUI

// The plan's sliders beside the dial: ARC (vertical, continuous) and TILT for a
// baton or SPIN for a kubb (horizontal, a detent a step). Each is a plate in the
// game's look: a wooden header with the value, and a paper body with the scale
// marks in a lane beside the ink slot the wooden knob runs in. The header and
// the lane sit where the finger is not (above the track, and on ARC's side
// toward the screen's centre), so the value reads while it is dragged. The
// whole body takes the press: a press anywhere jumps the knob there and keeps
// dragging. docs/MATCH.md "The plan".

extension Color {
  static let woodHeader = Color(red: 0.93, green: 0.85, blue: 0.68)
  static let woodKnob = Color(red: 0.95, green: 0.89, blue: 0.75)
  static let woodGrain = Color(red: 0.62, green: 0.42, blue: 0.22)
}

private struct SliderPlate<Body: View>: View {
  let title: String
  let width, height: CGFloat
  @ViewBuilder let content: () -> Body
  var body: some View {
    VStack(spacing: 0) {
      Text(title).font(displayFont(17)).lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 28).background(Color.woodHeader)
      Rectangle().fill(Color.woodInk).frame(height: 2)
      content().frame(width: width, height: height)
    }
    .frame(width: width).foregroundStyle(Color.woodInk)
    .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: 5))
    .clipShape(RoundedRectangle(cornerRadius: 5))
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.woodInk, lineWidth: 2))
    .background(RoundedRectangle(cornerRadius: 5).fill(Color.woodInk).offset(x: 3, y: 4))
  }
}

/// The wooden knob: the dial's knob, end grain and all.
private func knob(_ ctx: GraphicsContext, at p: CGPoint, radius r: CGFloat) {
  func disk(_ radius: CGFloat, _ color: Color, dx: CGFloat = 0, dy: CGFloat = 0) {
    ctx.fill(
      Path(ellipseIn: CGRect(x: p.x - radius + dx, y: p.y - radius + dy, width: radius * 2, height: radius * 2)),
      with: .color(color))
  }
  disk(r, .woodInk, dx: 2, dy: 3)
  disk(r, .woodInk)
  disk(r - 2.5, .woodKnob)
  ctx.stroke(
    Path(ellipseIn: CGRect(x: p.x - r * 0.55, y: p.y - r * 0.55, width: r * 1.1, height: r * 1.1)),
    with: .color(.woodGrain), lineWidth: 1.6)
  disk(r * 0.2, .woodInk)
}

struct ArcSlider: View {
  let release: Double?, loft: Int?, held: Double?
  let enabled: Bool
  let slide: (Double, SlidePhase) -> Void
  let step: (Int) -> Void
  @State private var dragging = false
  private let width: CGFloat = 84, height: CGFloat = 124, inset: CGFloat = 18
  var body: some View {
    SliderPlate(title: PlanScale.arcLabel(loft: loft), width: width, height: height) {
      Canvas { ctx, size in
        let run = size.height - inset * 2
        let slotX: CGFloat = 26
        func y(_ f: Double) -> CGFloat { inset + run * (1 - f) }
        ctx.fill(
          Path(roundedRect: CGRect(x: slotX - 3, y: inset - 4, width: 6, height: run + 8), cornerRadius: 3),
          with: .color(.woodInk))
        for m in PlanScale.arcMarks {
          var line = Path()
          line.move(to: CGPoint(x: 50, y: y(m.f)))
          line.addLine(to: CGPoint(x: m.long ? 74 : 64, y: y(m.f)))
          ctx.stroke(line, with: .color(.woodInk), lineWidth: m.long ? 3 : 2)
        }
        let f = held ?? PlanScale.arcFraction(release)
        var index = Path()
        index.move(to: CGPoint(x: 40, y: y(f)))
        index.addLine(to: CGPoint(x: 47, y: y(f) - 5))
        index.addLine(to: CGPoint(x: 47, y: y(f) + 5))
        index.closeSubpath()
        ctx.fill(index, with: .color(.woodInk))
        knob(ctx, at: CGPoint(x: slotX, y: y(f)), radius: 15)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { v in
            slide(1 - (v.location.y - inset) / (height - inset * 2), dragging ? .move : .down)
            dragging = true
          }
          .onEnded { v in
            dragging = false
            slide(1 - (v.location.y - inset) / (height - inset * 2), .up)
          })
    }
    .opacity(enabled ? 1 : 0.5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Arc")
    .accessibilityValue("Arc \(loft ?? 0) degrees")
    .accessibilityHint("A higher arc drops in steeper, a lower one skids in.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: step(1)
      case .decrement: step(-1)
      @unknown default: break
      }
    }
  }
}

struct SideSlider: View {
  let value: Int, kubb: Bool, held: Double?
  let enabled: Bool
  let slide: (Double, SlidePhase) -> Void
  let step: (Int) -> Void
  @State private var dragging = false
  private let width: CGFloat = 96, height: CGFloat = 64, inset: CGFloat = 16
  var body: some View {
    SliderPlate(title: PlanScale.sideLabel(value, kubb: kubb), width: width, height: height) {
      Canvas { ctx, size in
        let run = size.width - inset * 2
        func x(_ f: Double) -> CGFloat { inset + run * f }
        let slotY: CGFloat = 42
        ctx.fill(
          Path(roundedRect: CGRect(x: inset - 4, y: slotY - 3, width: run + 8, height: 6), cornerRadius: 3),
          with: .color(.woodInk))
        for m in PlanScale.sideMarks(kubb: kubb) {
          var line = Path()
          line.move(to: CGPoint(x: x(m.f), y: 24))
          line.addLine(to: CGPoint(x: x(m.f), y: m.long ? 8 : 15))
          ctx.stroke(line, with: .color(.woodInk), lineWidth: m.long ? 3 : 1.6)
        }
        let f = held ?? PlanScale.sideFraction(PlanScale.steps(of: value, kubb: kubb), kubb: kubb)
        knob(ctx, at: CGPoint(x: x(f), y: slotY), radius: 14)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { v in
            slide((v.location.x - inset) / (width - inset * 2), dragging ? .move : .down)
            dragging = true
          }
          .onEnded { v in
            dragging = false
            slide((v.location.x - inset) / (width - inset * 2), .up)
          })
    }
    .animation(.easeOut(duration: 0.12), value: held == nil)
    .opacity(enabled ? 1 : 0.5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kubb ? "Spin" : "Tilt")
    .accessibilityValue(PlanScale.sideValueText(value, kubb: kubb))
    .accessibilityHint(
      kubb
        ? "Spin keeps a drilled kubb steady in the air."
        : "Tilt leans the baton to steer it through a group.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: step(1)
      case .decrement: step(-1)
      @unknown default: break
      }
    }
  }
}

/// What a held slider does to the throw, in the HUD's plaque. Narrow enough to
/// sit between the pitch map's two places (14 pt in from either edge, at most
/// 74 pt wide: BoardView), so it never covers the map in either view.
struct SliderCaption: View {
  let text: String
  var body: some View {
    Text(text).font(displayFont(15)).multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 180).modifier(Plate(inset: 7)).allowsHitTesting(false)
  }
}
