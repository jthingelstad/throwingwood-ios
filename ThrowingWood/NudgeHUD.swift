import KubbRenderer
import UIKit

/// The throw's nudge over the meter on the screen (ThrowNudge.swift says when
/// and what): a ghost of the knob making one good throw, and a ghost fingertip
/// showing where the finger goes and when it presses and lets go. A port of the
/// web's src/render/nudge.js, same numbers. Drawing only.
enum NudgePaint {
  static let ghostFill: CGFloat = 0.45  // the ghost knob's paper
  static let ghostLine: CGFloat = 0.85  // its dashed ink rim and arm
  static let dash: [CGFloat] = [5, 4]
  static let finger: CGFloat = 19  // pt: the fingertip's radius (a finger pad, about 10 mm across)
  static let fingerFill: CGFloat = 0.82
  static let lift: CGFloat = 0.7  // the fingertip's rise before it presses, of its radius
  static let shadow: CGFloat = 0.22  // its hard shadow when down, of its radius
  static let zoneGap: CGFloat = 12  // pt between the prompt tab and the fingertip's path
  static let beside: CGFloat = 1.6  // the clock's fingertip: radii out, beside the ring
  static let onKnob: CGFloat = 0.82  // the clock's fingertip on the knob, where the sliders cover the band
}

extension PracticeHUD {
  /// Where the fingertip is for `arm` on this meter.
  /// `besideFree`: nothing covers the band beside the clock's ring. In a match
  /// the plan's sliders sit there, so the fingertip presses the knob instead.
  static func nudgeFinger(
    _ meter: MeterLayout, arm: Double, swing: NudgeSwing, size: CGSize, safeLeft: CGFloat,
    safeRight: CGFloat, besideFree: Bool = true
  ) -> CGPoint {
    switch meter {
    case .clock(let c):
      return c.point(arm: arm, radius: c.radius * (besideFree ? NudgePaint.beside : NudgePaint.onKnob))
    case .linear(let g):
      let z = nudgePath(g, swing: swing, size: size, safeLeft: safeLeft, safeRight: safeRight)
      return CGPoint(x: z.x, y: z.y0 + (g.y(arm: clampArm(arm)) - g.yHome))
    }
  }

  /// The fingertip's path on the linear meter: in the throw zone, in the middle of
  /// what the meter leaves (where a thumb strokes), clear of the prompt tab at the
  /// knob's home, starting low enough that the whole draw back fits on the screen.
  static func nudgePath(
    _ g: LinearMeter, swing: NudgeSwing, size: CGSize, safeLeft: CGFloat, safeRight: CGFloat
  ) -> (x: CGFloat, y0: CGFloat) {
    let R = NudgePaint.finger
    let right = g.side == .right
    let plateW = g.promptHeight * 5
    let tab =
      right
      ? g.left - g.frame * 2 - plateW - NudgePaint.zoneGap - R
      : g.right + g.shadow + g.frame * 2 + plateW + NudgePaint.zoneGap + R
    var x =
      right
      ? (safeLeft + 8 + g.box.minX - 6) / 2 : (g.box.maxX + 6 + size.width - safeRight - 8) / 2
    x = right ? min(x, tab) : max(x, tab)
    let backPt = CGFloat(abs(swing.back)) * g.scale
    let zoneTop = size.height * MeterLayout.zoneFrom
    var y0 = max(zoneTop + R + 4, g.yHome)
    y0 = min(y0, size.height - R - 8 - backPt)
    return (x, max(zoneTop + 2, y0))
  }

  static func clampArm(_ a: Double) -> Double {
    max(-LinearMeter.tune.range, min(LinearMeter.tune.range, a))
  }

  func nudge(
    _ f: NudgeFrame, swing: NudgeSwing, on meter: MeterLayout, safeLeft: CGFloat, safeRight: CGFloat,
    besideFree: Bool = true
  ) {
    guard f.alpha > 0 else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.setAlpha(min(1, f.alpha))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    defer { context.endTransparencyLayer() }
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let finger = Self.nudgeFinger(
      meter, arm: f.arm, swing: swing, size: size, safeLeft: safeLeft, safeRight: safeRight,
      besideFree: besideFree)
    switch meter {
    case .clock(let c):
      let r = c.radius
      let lw = max(1.5, r * 0.03)
      let kr = r * 0.145
      let knob = c.point(arm: f.arm, radius: r * 0.82)
      ghostArm(c.center, c.point(arm: f.arm, radius: r * 0.82 - kr), lw)
      ghostKnob(knob, kr, lw)
      if f.step == .still { clockArrows(c, swing) }
    case .linear(let g):
      let lw = max(1.5, g.width * 0.03)
      let ky = g.y(arm: Self.clampArm(f.arm))
      let kr = g.knobRadius
      if abs(ky - g.yHome) > kr {
        ghostArm(
          CGPoint(x: g.knobX, y: g.yHome),
          CGPoint(x: g.knobX, y: ky + (g.yHome > ky ? kr : -kr)), lw)
      }
      ghostKnob(CGPoint(x: g.knobX, y: ky), kr, lw)
      if f.step == .still {
        let z = Self.nudgePath(g, swing: swing, size: size, safeLeft: safeLeft, safeRight: safeRight)
        linearArrows(g, z, swing)
      }
    }
    fingertip(finger, f)
  }

  private func dashed(_ draw: () -> Void, _ lw: CGFloat) {
    context.saveGState()
    context.setAlpha(NudgePaint.ghostLine)
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(lw)
    context.setLineDash(phase: 0, lengths: NudgePaint.dash)
    draw()
    context.restoreGState()
  }

  private func ghostArm(_ a: CGPoint, _ b: CGPoint, _ lw: CGFloat) {
    dashed(
      {
        context.beginPath()
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()
      }, lw)
  }

  private func ghostKnob(_ c: CGPoint, _ kr: CGFloat, _ lw: CGFloat) {
    let rect = CGRect(x: c.x - kr, y: c.y - kr, width: 2 * kr, height: 2 * kr)
    context.saveGState()
    context.setAlpha(NudgePaint.ghostFill)
    disk(c, kr, paper)
    context.restoreGState()
    dashed({ context.strokeEllipse(in: rect) }, lw)
    context.saveGState()
    context.setAlpha(NudgePaint.ghostLine)
    disk(c, kr * 0.16, ink)
    context.restoreGState()
  }

  /// A fingertip at `p`. `press`: 0 lifted, 1 down; `ring`: the press cue round it.
  private func fingertip(_ p: CGPoint, _ f: NudgeFrame) {
    let R = NudgePaint.finger
    let up = 1 - f.press
    let x = p.x + up * R * NudgePaint.lift * 0.5
    let y = p.y - up * R * NudgePaint.lift
    if let ring = f.ring, ring.alpha > 0 {
      context.saveGState()
      context.setAlpha(ring.alpha)
      let rr = R * ring.k
      let rect = CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)
      context.setStrokeColor(ink.cgColor)
      context.setLineWidth(2.5)
      context.strokeEllipse(in: rect)
      context.setStrokeColor(paper.cgColor)
      context.setLineWidth(1.2)
      context.strokeEllipse(in: rect)
      context.restoreGState()
    }
    // the hard shadow falls right and down, farther while lifted
    let sh = R * (NudgePaint.shadow + up * 0.5)
    context.saveGState()
    context.setAlpha(0.35)
    disk(CGPoint(x: x + sh, y: y + sh), R, ink)
    context.restoreGState()
    context.saveGState()
    context.setAlpha(NudgePaint.fingerFill)
    disk(CGPoint(x: x, y: y), R, paper)
    context.restoreGState()
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(2.5)
    context.strokeEllipse(in: CGRect(x: x - R, y: y - R, width: 2 * R, height: 2 * R))
    // the nail's edge, so it reads as a fingertip, not a button
    context.setLineWidth(1.5)
    context.beginPath()
    context.addArc(
      center: CGPoint(x: x, y: y - R * 0.18), radius: R * 0.5, startAngle: .pi * 1.1,
      endAngle: .pi * 1.9, clockwise: false)
    context.strokePath()
  }

  // ---------- reduced motion: a still picture and the strokes' arrows ----------

  private func arrowHead(at tip: CGPoint, from: CGPoint) {
    let a = atan2(tip.y - from.y, tip.x - from.x)
    let s: CGFloat = 9
    context.beginPath()
    context.move(to: CGPoint(x: tip.x - s * cos(a - 0.5), y: tip.y - s * sin(a - 0.5)))
    context.addLine(to: tip)
    context.addLine(to: CGPoint(x: tip.x - s * cos(a + 0.5), y: tip.y - s * sin(a + 0.5)))
    context.strokePath()
  }

  private func arrowLine(_ pts: [CGPoint], _ lw: CGFloat) {
    guard pts.count > 1 else { return }
    for (color, w) in [(paper, lw + 3), (ink, lw)] {
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(w)
      context.beginPath()
      context.addLines(between: pts)
      context.strokePath()
      arrowHead(at: pts[pts.count - 1], from: pts[pts.count - 2])
    }
  }

  /// Slow down the left (a thin arrow) and fast up past 6 to the release (a thick one).
  private func clockArrows(_ c: ClockMeter, _ swing: NudgeSwing) {
    let r = c.radius * (NudgePaint.beside + 0.35)
    func arc(_ a0: Double, _ a1: Double) -> [CGPoint] {
      (0...16).map { c.point(arm: a0 + (a1 - a0) * Double($0) / 16, radius: r) }
    }
    arrowLine(arc(-8, -abs(swing.back) + 8), 2)
    arrowLine(arc(-abs(swing.back) + 14, abs(swing.release)), 4)
  }

  private func linearArrows(_ g: LinearMeter, _ z: (x: CGFloat, y0: CGFloat), _ swing: NudgeSwing) {
    let R = NudgePaint.finger
    let back = CGFloat(abs(swing.back)) * g.scale
    let fwd = CGFloat(abs(swing.release)) * g.scale
    let dx = (g.side == .right ? -1 : 1) * (R + 10)
    arrowLine([CGPoint(x: z.x + dx, y: z.y0 - R), CGPoint(x: z.x + dx, y: z.y0 + back)], 2)
    arrowLine([CGPoint(x: z.x - dx, y: z.y0 + back - R), CGPoint(x: z.x - dx, y: z.y0 - fwd)], 4)
  }
}
