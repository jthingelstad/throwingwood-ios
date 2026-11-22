import KubbRenderer
import SwiftUI

/// The set-up tray (TrayLayout.swift, the 1.0 design's aim layout): ARC, TILT (SPIN for
/// a kubb) and STAND as three closed plates of one size, each a wood band with its value
/// over a small picture of its setting. A tap opens that one plate large (the other two
/// stay plates); ARC open shows the side view until it closes. The open plate's band, a
/// tap on its closed plate, or a tap outside closes it. Upright an open plate grows
/// upward in the column; on a wide screen it stands beside the column (or over it, in a
/// window too narrow), `WideLayout.Plan.open`.
///
/// VoiceOver reads the tray after the meter: Arc, Tilt, Stand with their values, each
/// adjustable a step at a time as the open sliders are, and a double tap opens it.
struct TrayView: View {
  let model: GameModel, pitch: PitchSession, revision: Int
  /// The tray on this screen (TrayFrames), in whole-screen points.
  let tray: TrayFrames
  var wide: Bool { tray.wide }

  var body: some View {
    let frames = tray.plates(open: pitch.openPlate)
    let open = pitch.openPlate.flatMap { frames[$0] }
    ZStack(alignment: .topLeading) {
      Color.clear
      ForEach(TrayPlate.allCases, id: \.self) { p in
        if p != pitch.openPlate, let f = frames[p] {
          closed(p, selected: false)
            .frame(width: f.width, height: f.height)
            .offset(x: f.minX, y: f.minY)
            .accessibilitySortPriority(Double(3 - (TrayPlate.allCases.firstIndex(of: p) ?? 0)))
        }
      }
      if let p = pitch.openPlate, let f = open {
        opened(p, f)
          // VoiceOver cannot tap outside: the open plate closes from its own actions
          .accessibilityAction(named: "Close") { tap(nil) }
          .frame(width: f.width, height: f.height, alignment: .bottom)
          .offset(x: f.minX, y: f.minY)
          .accessibilitySortPriority(4)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Throw set-up")
  }

  private func tap(_ p: TrayPlate?) { model.perform { try pitch.tapPlate(p) } }

  // MARK: Closed

  private func closed(_ p: TrayPlate, selected: Bool) -> some View {
    let size = Tray.plate(wide: wide)
    return Button {
      tap(p)
    } label: {
      VStack(spacing: 0) {
        Text(title(p)).font(displayFont(17, relativeTo: .headline)).lineLimit(1).minimumScaleFactor(0.4)
          .foregroundStyle(selected ? Color.woodPaper : Color.woodInk)
          .padding(.top, TW.line).padding(.horizontal, 4)
          .frame(maxWidth: .infinity, minHeight: Tray.band + TW.line)
          .background(selected ? Color.woodInk : Color.woodHeader)
        Rectangle().fill(Color.woodInk).frame(height: TW.line)
        Canvas { ctx, s in picture(p, ctx, s) }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: size.width, height: size.height)
      .background(Color.woodBaton)
      .clipShape(RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
      .background(
        RoundedRectangle(cornerRadius: TW.controlRadius).fill(Color.woodDrop)
          .offset(x: TW.controlShadow, y: TW.controlShadow))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityShowsLargeContentViewer {
      Text(title(p))
    }
    .accessibilityLabel(spokenName(p))
    .accessibilityValue(spokenValue(p))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(selected ? "Closes it." : "Opens it large. Swipe up or down to adjust.")
    .accessibilityAdjustableAction { direction in
      let s = direction == .increment ? 1 : (direction == .decrement ? -1 : 0)
      guard s != 0 else { return }
      model.perform {
        switch p {
        case .arc: try pitch.stepPlan(.arc, by: s)
        case .tilt: try pitch.stepPlan(.side, by: s)
        case .stand: try pitch.standStep(dx: Double(s) * StandPad.keyStep, dy: 0)
        }
      }
    }
  }

  private func title(_ p: TrayPlate) -> String {
    switch p {
    case .arc: PlanScale.arcLabel(loft: pitch.arcDegrees)
    case .tilt: PlanScale.sideLabel(pitch.sideStep ?? 0, kubb: pitch.throwsKubb)
    case .stand: "STAND"
    }
  }
  private func spokenName(_ p: TrayPlate) -> String {
    switch p {
    case .arc: "Arc"
    case .tilt: pitch.throwsKubb ? "Spin" : "Tilt"
    case .stand: "Stand"
    }
  }
  private func spokenValue(_ p: TrayPlate) -> String {
    switch p {
    case .arc: "\(pitch.arcDegrees ?? 0) degrees"
    case .tilt: PlanScale.sideValueText(pitch.sideStep ?? 0, kubb: pitch.throwsKubb)
    case .stand: pitch.standValueText
    }
  }

  /// The plate's small picture of its setting (the design's: a dashed arc as high as the
  /// loft, the baton leaning by the tilt or a kubb turning by the spin, the throwing line
  /// with the thrower's ring where they stand).
  private func picture(_ p: TrayPlate, _ ctx: GraphicsContext, _ s: CGSize) {
    let ink = Color.woodInk
    let w = s.width, h = s.height
    switch p {
    case .arc:
      let loft = Double(pitch.arcDegrees ?? 30)
      let k = min(1, max(0.2, loft / 45))
      var path = Path()
      let y0 = h - 5
      path.move(to: CGPoint(x: 8, y: y0))
      path.addQuadCurve(to: CGPoint(x: w - 8, y: y0), control: CGPoint(x: w / 2, y: y0 - (h * 2 - 8) * k))
      ctx.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 4]))
    case .tilt:
      let value = pitch.sideStep ?? 0
      if pitch.throwsKubb {
        // a kubb end on, an arrow round it the way it spins
        let r = CGRect(x: w / 2 - 6, y: h / 2 - 9, width: 12, height: 18)
        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Color(skin.knob)))
        ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(ink), lineWidth: 2.5)
        if abs(value) > 0.001 {
          let right = value > 0
          var a = Path()
          let c = CGPoint(x: w / 2, y: h / 2)
          a.addArc(center: c, radius: 15, startAngle: .degrees(right ? 200 : -20), endAngle: .degrees(right ? 330 : -150), clockwise: !right)
          ctx.stroke(a, with: .color(ink), lineWidth: 2)
          let tip = CGPoint(x: c.x + (right ? 13 : -13), y: c.y - 7.5)
          var head = Path()
          head.move(to: CGPoint(x: tip.x + (right ? 4 : -4), y: tip.y + 1))
          head.addLine(to: CGPoint(x: tip.x - (right ? 3 : -3), y: tip.y - 3))
          head.addLine(to: CGPoint(x: tip.x - (right ? 1 : -1), y: tip.y + 5))
          head.closeSubpath()
          ctx.fill(head, with: .color(ink))
        }
      } else {
        for x in [w * 0.17, w * 0.83] {
          var l = Path()
          l.move(to: CGPoint(x: x - 5, y: h / 2))
          l.addLine(to: CGPoint(x: x + 5, y: h / 2))
          ctx.stroke(l, with: .color(ink), lineWidth: 2)
        }
        var c = ctx
        c.translateBy(x: w / 2, y: h / 2)
        c.rotate(by: .degrees(value))
        let r = CGRect(x: -4, y: -h / 2 + 4, width: 8, height: h - 8)
        c.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color(skin.knob)))
        c.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(ink), lineWidth: 2.5)
      }
    case .stand:
      let span = pitch.standSpan
      let f = span.fraction(x: pitch.standPoint.x, y: pitch.standPoint.y)
      let y = h * 0.62
      var line = Path()
      line.move(to: CGPoint(x: 6, y: y))
      line.addLine(to: CGPoint(x: w - 6, y: y))
      ctx.stroke(line, with: .color(ink), lineWidth: 3)
      let x = 10 + (w - 20) * min(1, max(0, f.fx))
      let ring = Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
      ctx.fill(ring, with: .color(Color(skin.standRing)))
      ctx.stroke(ring, with: .color(ink), lineWidth: 3)
    }
  }

  // MARK: Open

  @ViewBuilder private func opened(_ p: TrayPlate, _ f: CGRect) -> some View {
    let body = Tray.body(f.height)
    let enabled = pitch.canAim
    let close = { tap(nil) }
    switch p {
    case .arc:
      ArcSlider(
        place: pitch.arcPlace, loft: pitch.arcDegrees,
        held: pitch.held == .arc ? pitch.heldFraction : nil, marks: pitch.arcMarks(run:),
        enabled: enabled,
        slide: { fr, phase in model.perform { pitch.slide(.arc, to: fr, phase: phase) } },
        step: { s in model.perform { try pitch.stepPlan(.arc, by: s) } },
        width: f.width, height: body, close: close)
    case .tilt:
      SideSlider(
        value: pitch.sideStep ?? 0, place: pitch.sidePlace, kubb: pitch.throwsKubb,
        held: pitch.held == .side ? pitch.heldFraction : nil, marks: pitch.sideMarks(run:),
        enabled: enabled,
        slide: { fr, phase in model.perform { pitch.slide(.side, to: fr, phase: phase) } },
        step: { s in model.perform { try pitch.stepPlan(.side, by: s) } },
        width: f.width, height: body, close: close)
    case .stand:
      StandPlate(
        span: pitch.standSpan, thrower: pitch.standPoint, held: pitch.standHeld, enabled: enabled,
        valueText: pitch.standValueText,
        stand: { fx, fy, phase in model.perform { pitch.stand(fx: fx, fy: fy, phase: phase) } },
        step: { dx, dy in model.perform { try pitch.standStep(dx: dx, dy: dy) } },
        width: f.width, height: body, close: close)
    }
  }
}

extension TrayView {
  /// The tray on this screen, in whole-screen points (TrayLayout.swift, WideLayout.plan).
  @MainActor static func frames(
    size: CGSize, safe: ScreenInsets, meter: MeterLayout, side: MeterSide, online: Bool, headerBottom: CGFloat?
  ) -> TrayFrames {
    if WideLayout.isWide(size) {
      return WideLayout.plan(
        meter: meter, size: size, safe: safe, side: side, trayWidth: online ? WideLayout.trayWidth : 0
      ).tray
    }
    return Tray.uprightFrames(size: size, safe: safe, meter: meter, side: side, headerBottom: headerBottom)
  }
}
