import KubbRenderer
import SwiftUI
import UIKit

/// The feedback card's picture of the pitch from above (the web's src/ui/paint.js; the
/// owner, 2026-11-26: "show an image of the pitch and allow the user to paint over the
/// area where the issue occurred instead of selecting individual pieces"): the pieces the
/// report captured (the last throw's rest when there is one, else the pitch now) at their
/// real places and sizes, a standing piece solid with an ink ring and one lying down pale
/// with a thin line. The player paints over it with a finger, a translucent brush, with
/// UNDO and CLEAR. A finger on the picture paints and never scrolls the card; a drag
/// outside it scrolls the card as ever. The geometry is `ReportPicture` (KubbRenderer).
///
/// VoiceOver: the picture is one image with a description, and its paint is not offered
/// (the answers above it are the way to say what happened); UNDO and CLEAR are buttons.
struct PaintPicture: View {
  let pieces: [ReportPiece]
  @Binding var paint: ReportPaint
  var disabled = false

  @Environment(\.reportViewport) private var viewport
  @State private var width: CGFloat = 0
  @State private var live = false
  @State private var full = false

  static let hint = "If it helps, paint where it happened on the pitch."
  static let fullWords = "That is as much paint as one report can carry."
  static let description =
    "The pitch from above, as it stood. Paint on it with a finger to show where it happened."

  private var bounds: ReportPicture.Bounds { ReportPicture.bounds(pieces) }

  private var fit: ReportPicture.Fit? {
    // the frame's ink line is 3 pt each side of the picture
    let w = width - 2 * TW.line
    guard w > 0 else { return nil }
    let maxH = max(ReportPicture.minHeight, (viewport.height > 0 ? viewport.height : 600) * ReportPicture.maxHeightShare)
    return ReportPicture.Fit(bounds: bounds, width: w, maxHeight: maxH)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(Self.hint).font(bodyFont(14, relativeTo: .footnote))
      Color.clear.frame(height: 0).frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      if let fit {
        picture(fit)
          .frame(width: fit.size.width, height: fit.size.height)
          .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.woodInk, lineWidth: TW.line).padding(-TW.line))
          .padding(TW.line)
          .frame(maxWidth: .infinity)
          .onAppear { if paint.strokes.isEmpty { paint.brush = fit.brush } }
      }
      HStack(spacing: 10) {
        Button("UNDO") {
          if !paint.strokes.isEmpty { paint.strokes.removeLast() }
          live = false
          changed()
        }
        .disabled(disabled || paint.strokes.isEmpty)
        .accessibilityHint("Takes back the last stroke of paint.")
        Button("CLEAR") {
          paint.strokes = []
          live = false
          changed()
        }
        .disabled(disabled || paint.strokes.isEmpty)
        .accessibilityHint("Takes all the paint off the picture.")
        if full {
          Text(Self.fullWords).font(bodyFont(14, relativeTo: .footnote))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
      .buttonStyle(WoodButton())
    }
  }

  private func picture(_ fit: ReportPicture.Fit) -> some View {
    Canvas { ctx, _ in draw(ctx, fit) }
      .overlay {
        PaintTouches(
          enabled: !disabled,
          began: { p in begin(fit.metres(p)) },
          moved: { p in move(fit.metres(p)) },
          ended: { end() })
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Self.description)
      .accessibilityValue(
        paint.strokes.isEmpty ? "Nothing painted" : "\(paint.strokes.count) stroke\(paint.strokes.count == 1 ? "" : "s") painted"
      )
      .accessibilityAddTraits(.isImage)
  }

  // MARK: painting

  private func begin(_ m: CGPoint) {
    guard !live else { return }
    guard paint.hasRoom(newStroke: true) else { return say() }
    paint.strokes.append([m])
    live = true
    changed()
  }

  private func move(_ m: CGPoint) {
    guard live, var last = paint.strokes.last, let prev = last.last else { return }
    if hypot(m.x - prev.x, m.y - prev.y) < paint.brush * ReportPicture.step { return }
    guard paint.hasRoom(newStroke: false) else { return say() }
    last.append(m)
    paint.strokes[paint.strokes.count - 1] = last
  }

  private func end() {
    guard live else { return }
    live = false
    changed()
  }

  private func say() {
    if !full { UIAccessibility.post(notification: .announcement, argument: Self.fullWords) }
    full = true
  }

  private func changed() {
    if paint.hasRoom(newStroke: true) { full = false }
  }

  // MARK: drawing

  private static let rough = Color(hex: 0x3f7a2a), grass = Color(hex: 0x5fa43c)
  private static let ink = Color(hex: 0x16130f), wood = Color(hex: 0xc8955a), king = Color(hex: 0xf4ecd8)
  private static let teamA = Color(hex: 0xf2b705), teamB = Color(hex: 0x8e44ad)
  /// laid at 0.45 over the grass: a clear mauve, not mud
  private static let paintColour = Color(hex: 0xe83cc8)

  private func draw(_ ctx: GraphicsContext, _ f: ReportPicture.Fit) {
    let full = CGRect(origin: .zero, size: f.size)
    ctx.fill(Path(full), with: .color(Self.rough))
    func poly(_ pts: [CGPoint]) -> Path {
      var p = Path()
      p.addLines(pts.map(f.point))
      p.closeSubpath()
      return p
    }
    // the pitch, 5 by 8, its centre line and its stakes
    let pitch = poly([CGPoint(x: -2.5, y: 0), CGPoint(x: 2.5, y: 0), CGPoint(x: 2.5, y: 8), CGPoint(x: -2.5, y: 8)])
    ctx.fill(pitch, with: .color(Self.grass))
    let line = Color.white.opacity(0.9)
    ctx.stroke(pitch, with: .color(line), lineWidth: 1.5)
    var centre = Path()
    centre.move(to: f.point(CGPoint(x: -2.5, y: 4)))
    centre.addLine(to: f.point(CGPoint(x: 2.5, y: 4)))
    ctx.stroke(centre, with: .color(line), lineWidth: 1.5)
    for x in [-2.5, 2.5] {
      for y in [0.0, 4, 8] {
        let c = f.point(CGPoint(x: x, y: y))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(.white))
      }
    }
    // "your baseline" and "far baseline", so the picture reads the right way round
    let gap = 12 / Double(f.scale)
    func label(_ text: String, _ m: CGPoint) {
      var c = ctx
      let at = f.point(m)
      c.translateBy(x: at.x, y: at.y)
      if !f.upright { c.rotate(by: .degrees(-90)) }
      c.draw(
        Text(text).font(bodyFont(14, .bold)).foregroundStyle(Color.white.opacity(0.85)), at: .zero,
        anchor: .center)
    }
    if bounds.y0 < -gap { label("YOUR BASELINE", CGPoint(x: 0, y: -gap)) }
    if bounds.y1 > 8 + gap { label("FAR BASELINE", CGPoint(x: 0, y: 8 + gap)) }
    // the pieces: standing solid with an ink ring, lying pale with a thin line
    for p in pieces where p.kind != "stake" {
      let (real, lying) = ReportPicture.footprint(p)
      let k = ReportPicture.grow(p, scale: f.scale)
      let shape = poly(real.map { CGPoint(x: p.x + ($0.x - p.x) * k, y: p.y + ($0.y - p.y) * k) })
      let fill =
        p.kind == "baton" ? Self.wood : p.kind == "king" ? Self.king : p.team == "B" ? Self.teamB : p.team == "A" ? Self.teamA : Self.wood
      ctx.fill(shape, with: .color(fill.opacity(lying ? 0.55 : 1)))
      ctx.stroke(shape, with: .color(Self.ink), lineWidth: lying ? 1 : 1.5)
      if !lying && p.kind == "king" {
        let c = f.point(CGPoint(x: p.x, y: p.y))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(Self.ink))
      }
    }
    // the paint: drawn whole on a layer of its own, so a stroke over a stroke is not darker
    guard !paint.strokes.isEmpty else { return }
    var layer = ctx
    layer.opacity = 0.45
    let r = CGFloat(paint.brush) * f.scale
    layer.drawLayer { lc in
      for s in paint.strokes {
        let pts = s.map(f.point)
        if pts.count == 1 {
          lc.fill(
            Path(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r)),
            with: .color(Self.paintColour))
          continue
        }
        var path = Path()
        path.addLines(pts)
        lc.stroke(
          path, with: .color(Self.paintColour), style: StrokeStyle(lineWidth: 2 * r, lineCap: .round, lineJoin: .round))
      }
    }
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
  }
}

/// The picture's finger: one touch at a time, in the picture's points. It refuses every
/// pan of the views round it while a finger starts on it (as UISlider does), so painting
/// never scrolls the card, and a drag that starts outside it scrolls as ever.
private struct PaintTouches: UIViewRepresentable {
  let enabled: Bool
  let began: (CGPoint) -> Void
  let moved: (CGPoint) -> Void
  let ended: () -> Void

  func makeUIView(context: Context) -> Pad {
    let v = Pad()
    v.backgroundColor = .clear
    v.isMultipleTouchEnabled = false
    return v
  }

  func updateUIView(_ v: Pad, context: Context) {
    v.isUserInteractionEnabled = enabled
    v.began = began
    v.moved = moved
    v.ended = ended
  }

  final class Pad: UIView {
    var began: (CGPoint) -> Void = { _ in }
    var moved: (CGPoint) -> Void = { _ in }
    var ended: () -> Void = {}
    private weak var finger: UITouch?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
      // a scroll view's pan (or any pan) round the picture: never from a finger on it
      g.view === self || !(g is UIPanGestureRecognizer)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard finger == nil, let t = touches.first else { return }
      finger = t
      began(t.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let f = finger, touches.contains(f) else { return }
      for t in event?.coalescedTouches(for: f) ?? [f] { moved(t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let f = finger, touches.contains(f) else { return }
      moved(f.location(in: self))
      finger = nil
      ended()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let f = finger, touches.contains(f) else { return }
      finger = nil
      ended()
    }
  }
}
