import KubbRenderer
import UIKit

/// The meters' colours: the web's HUD palette (src/render/palette.js), so the
/// linear meter is the same instrument on a phone and in a browser.
enum MeterPaint {
  static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
    UIColor(
      red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
      blue: CGFloat(v & 0xff) / 255, alpha: a)
  }
  static let face = hex(0xfbf6ea)
  static let faceShade = hex(0xeadfc8)
  static let ring = hex(0xf1e7d2)
  static let power = hex(0xff7a3d)
  static let powerDeep = hex(0xc4521f)
  static let release = hex(0x33b6e8)
  static let releaseDeep = hex(0x1f7fa8)
  static let dead = hex(0xc9bfa9)
  static let over = hex(0xe5484d)
  static let hand = hex(0x7a5530)
  static let knob = hex(0xf2e2c0)
  static let knobGrab = UIColor.white
  static let glow = UIColor(red: 1, green: 246 / 255, blue: 200 / 255, alpha: 0.55)
}

/// The engine's prompts are the crank's; on the linear meter they read as its own motion.
func linearWords(_ prompt: String?) -> String? {
  switch prompt {
  case "WIND BACK": "DRAW BACK"
  case "FLICK!": "FLING!"
  case "CRANK DOWN": "BACK TO MIDDLE"
  default: prompt
  }
}

extension PracticeHUD {
  /// The linear meter (KubbRenderer `LinearMeter`): the same instrument as the
  /// clock laid out straight. A heavy ink frame with a hard shadow; the lane as
  /// the clock's ring (targets solid across it, ink edges); the channel as its
  /// face, with the hours ticked in. Down the channel runs the slot the knob
  /// slides in; the wooden stem fills it from home to the knob. Home is a hub in
  /// the groove, marked across the body and by an index in the lane, and the
  /// prompt is a tab hung off the body there. Each end is a stop.
  func linear(_ d: DialState, _ g: LinearMeter, held: Bool, prompt: String?) {
    let ctx = context
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    let R = LinearMeter.tune.range
    let lw = max(1, g.width * 0.024)
    let live = d.phase == "winding" || d.phase == "swinging"
    let in0 = g.left + g.frame, in1 = g.right - g.frame
    let top = g.top + g.frame, bottom = g.bottom - g.frame
    let laneFirst = g.side != .left  // the lane on the left, toward the centre
    let lane = laneFirst ? (in0, g.divider) : (g.divider, in1)
    let chan = laneFirst ? (g.divider, in1) : (in0, g.divider)
    let laneC = (lane.0 + lane.1) / 2
    let kc = g.knobX
    let slotW = max(4, g.channelWidth * 0.17)
    let corner = g.width * 0.12
    func y(_ a: Double) -> CGFloat { g.y(arm: a) }
    func band(_ span: (CGFloat, CGFloat), _ a0: Double, _ a1: Double) -> CGRect {
      let y0 = y(a0), y1 = y(a1)
      return CGRect(x: span.0, y: min(y0, y1), width: span.1 - span.0, height: abs(y1 - y0))
    }
    func fill(_ r: CGRect, _ c: UIColor) {
      ctx.setFillColor(c.cgColor)
      ctx.fill(r)
    }
    func across(_ a: Double, _ width: CGFloat) {
      line(CGPoint(x: in0, y: y(a)), CGPoint(x: in1, y: y(a)), ink, width)
    }

    // the body: hard shadow, ink frame
    let body = CGRect(x: g.left, y: g.top, width: g.width, height: g.bottom - g.top)
    ctx.setFillColor(ink.cgColor)
    ctx.addPath(
      CGPath(
        roundedRect: body.offsetBy(dx: g.shadow, dy: g.shadow), cornerWidth: corner,
        cornerHeight: corner, transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.fillPath()
    ctx.saveGState()
    let innerCorner = max(1, corner - g.frame)
    let inner = CGRect(x: in0, y: top, width: in1 - in0, height: bottom - top)
    ctx.addPath(
      CGPath(roundedRect: inner, cornerWidth: innerCorner, cornerHeight: innerCorner, transform: nil))
    ctx.clip()

    // the face and the ring
    fill(CGRect(x: chan.0, y: top, width: chan.1 - chan.0, height: bottom - top), held ? MeterPaint.knobGrab : MeterPaint.face)
    fill(CGRect(x: lane.0, y: top, width: lane.1 - lane.0, height: bottom - top), MeterPaint.ring)

    // the zones: the dead zone dotted, past overpowered hatched
    if d.deadDeg > 0 {
      let r = band(chan, -d.deadDeg, 0)
      fill(r, MeterPaint.faceShade)
      ctx.saveGState()
      ctx.clip(to: r)
      ctx.setFillColor(MeterPaint.dead.cgColor)
      let step = max(3, g.channelWidth * 0.14)
      var row = 0
      var yy = r.minY + step / 2
      while yy < r.maxY + step {
        var x = chan.0 + (row % 2 == 1 ? step / 2 : 0)
        while x < chan.1 + step {
          ctx.fillEllipse(in: CGRect(x: x - step * 0.14, y: yy - step * 0.14, width: step * 0.28, height: step * 0.28))
          x += step
        }
        yy += step
        row += 1
      }
      ctx.restoreGState()
    }
    let over = overStart(d)
    if over < R {
      let r = band(chan, -R, -over)
      ctx.saveGState()
      ctx.clip(to: r)
      let step = max(3, g.channelWidth * 0.16)
      ctx.setStrokeColor(MeterPaint.over.cgColor)
      ctx.setLineWidth(step * 0.28)
      ctx.setLineCap(.butt)
      var dd = -r.height
      while dd < r.width + r.height {
        ctx.move(to: CGPoint(x: r.minX + dd, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.minX + dd + r.height, y: r.maxY))
        dd += step
      }
      ctx.strokePath()
      ctx.restoreGState()
      fill(band(lane, -R, -over), MeterPaint.over)
      across(-over, lw)
    }
    // the targets: power behind home, release ahead of it
    func target(_ a0: Double, _ a1: Double, _ light: UIColor, _ deep: UIColor) {
      fill(band(chan, a0, a1), light)
      fill(band(lane, a0, a1), deep)
      across(a0, lw)
      across(a1, lw)
    }
    if let lo = d.powerLo, let hi = d.powerHi, hi > lo {
      target(-hi, -lo, MeterPaint.power, MeterPaint.powerDeep)
    }
    if let lo = d.releaseLo, let hi = d.releaseHi, hi > lo {
      target(lo, hi, MeterPaint.release, MeterPaint.releaseDeep)
    }

    // the ends: past each stop the face is shaded, with a wooden peg in the lane
    for (y0, y1) in [(top, g.yForward), (g.yBack, bottom)] {
      fill(CGRect(x: in0, y: y0, width: in1 - in0, height: y1 - y0), MeterPaint.faceShade)
      let py = (y0 + y1) / 2 + (y0 == top ? g.frame * 0.25 : -g.frame * 0.25)
      let pr = min((lane.1 - lane.0) * 0.28, (y1 - y0) * 0.28)
      let peg = CGRect(x: laneC - pr, y: py - pr, width: 2 * pr, height: 2 * pr)
      ctx.setFillColor(MeterPaint.knob.cgColor)
      ctx.fillEllipse(in: peg)
      ctx.setStrokeColor(ink.cgColor)
      ctx.setLineWidth(lw)
      ctx.strokeEllipse(in: peg)
      disk(CGPoint(x: laneC, y: py), max(0.8, pr * 0.3), MeterPaint.hand)
    }
    across(R, lw * 1.6)
    across(-R, lw * 1.6)

    // the lane's edge and the hours: ticked in from the lane toward the slot,
    // the quarters longer
    line(CGPoint(x: g.divider, y: top), CGPoint(x: g.divider, y: bottom), ink, lw)
    let inward: CGFloat = kc > g.divider ? 1 : -1
    let rail = kc - inward * slotW / 2
    var a = -R + 30
    while a < R {
      if a != 0 {
        let long = Int(a) % 90 == 0
        line(
          CGPoint(x: g.divider, y: y(a)),
          CGPoint(x: g.divider + (rail - g.divider) * (long ? 0.78 : 0.5), y: y(a)), ink,
          long ? lw * 2 : lw)
      }
      a += 30
    }

    // the slot, stop to stop: an ink groove
    ctx.setFillColor(ink.cgColor)
    ctx.addPath(
      CGPath(
        roundedRect: CGRect(x: kc - slotW / 2, y: g.yForward - slotW / 2, width: slotW, height: g.yBack - g.yForward + slotW),
        cornerWidth: slotW / 2, cornerHeight: slotW / 2, transform: nil))
    ctx.fillPath()

    // home: the line a throw is flung through, the six's index in the lane, the hub
    across(0, lw * 2.4)
    let ix = (lane.1 - lane.0) * 0.42
    let iBase = g.divider - inward * ix
    ctx.setFillColor(ink.cgColor)
    ctx.move(to: CGPoint(x: g.divider, y: g.yHome))
    ctx.addLine(to: CGPoint(x: iBase, y: g.yHome - ix * 0.85))
    ctx.addLine(to: CGPoint(x: iBase, y: g.yHome + ix * 0.85))
    ctx.closePath()
    ctx.fillPath()
    disk(CGPoint(x: kc, y: g.yHome), slotW * 0.95, ink)

    // the arm: at rest the knob is home; held, it is where the finger has it
    let raw = live ? d.arm : (held ? d.crank : 0)
    let arm = max(-R, min(R, raw))
    let ky = y(arm)
    let kr = g.knobRadius * (held ? 1.08 : 1)
    if held {
      let cw = chan.1 - chan.0
      ctx.setFillColor(MeterPaint.glow.cgColor)
      ctx.addPath(
        CGPath(
          roundedRect: CGRect(x: chan.0, y: ky - kr * 1.7, width: cw, height: kr * 3.4),
          cornerWidth: cw * 0.5, cornerHeight: min(cw * 0.5, kr * 1.7), transform: nil))
      ctx.fillPath()
    }
    if abs(ky - g.yHome) > 1 {
      let stW = slotW - lw * 1.3
      ctx.setFillColor(MeterPaint.hand.cgColor)
      ctx.addPath(
        CGPath(
          roundedRect: CGRect(x: kc - stW / 2, y: min(ky, g.yHome) - stW / 2, width: stW, height: abs(ky - g.yHome) + stW),
          cornerWidth: stW / 2, cornerHeight: stW / 2, transform: nil))
      ctx.fillPath()
    }
    linearMarks(d, g, lane: lane, live: live, lw: lw)
    ctx.restoreGState()  // the body's clip

    // the knob: a little baton end, wood with an ink rim and end-grain rings
    woodKnob(CGPoint(x: kc, y: ky), kr, held: held, lw: lw)

    if let prompt { tab(g, prompt, lane: lane) }
  }

  /// Practice's hint, beside the meter at the bottom of the screen.
  func linearHint(_ g: LinearMeter, safeBottom: CGFloat) {
    let x = g.side == .right ? (g.left - 10) / 2 : (g.right + g.shadow + 10 + size.width) / 2
    let y = size.height - safeBottom - 22
    text("Draw back · fling up", at: CGPoint(x: x, y: y), size: 16, color: ink, plate: true)
    text("Drag target to aim", at: CGPoint(x: x, y: y - 34), size: 16, color: ink, plate: true)
  }

  /// A little baton end: the knob of both meters.
  func woodKnob(_ c: CGPoint, _ kr: CGFloat, held: Bool, lw: CGFloat) {
    disk(CGPoint(x: c.x + kr * 0.18, y: c.y + kr * 0.18), kr, ink)
    let r = CGRect(x: c.x - kr, y: c.y - kr, width: 2 * kr, height: 2 * kr)
    context.setFillColor((held ? MeterPaint.knobGrab : MeterPaint.knob).cgColor)
    context.fillEllipse(in: r)
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(lw * 1.8)
    context.strokeEllipse(in: r)
    context.setStrokeColor(MeterPaint.hand.cgColor)
    context.setLineWidth(lw * 0.8)
    for k in [0.62, 0.36] as [CGFloat] {
      context.strokeEllipse(in: r.insetBy(dx: kr * (1 - k), dy: kr * (1 - k)))
    }
    disk(c, kr * 0.14, MeterPaint.hand)
  }

  /// The prompt: a tab hung off the body on the lane's side at home, its inner
  /// end tucked under the frame so it is one piece with the body.
  private func tab(_ g: LinearMeter, _ text: String, lane: (CGFloat, CGFloat)) {
    let h = g.promptHeight
    let inverted = text.hasSuffix("!")
    let font = UIFont(name: "LondrinaSolid-Black", size: (h * 0.74).rounded()) ?? .boldSystemFont(ofSize: h * 0.74)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: inverted ? paper : ink,
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    let w = size.width + h * 0.8
    let dir = g.tabDirection
    let out = dir < 0 ? g.left : g.right
    let x1 = out - dir * g.frame * 0.5
    let x0 = x1 + dir * (w + g.frame * 0.5)
    let left = min(x0, x1)
    let rect = CGRect(x: left, y: g.yHome - h / 2, width: abs(x1 - x0), height: h)
    let r = h * 0.22
    func path(_ rect: CGRect) -> UIBezierPath {
      UIBezierPath(
        roundedRect: rect, byRoundingCorners: dir < 0 ? [.topLeft, .bottomLeft] : [.topRight, .bottomRight],
        cornerRadii: CGSize(width: r, height: r))
    }
    let sh = g.shadow * 0.8
    ink.setFill()
    path(rect.offsetBy(dx: sh, dy: sh)).fill()
    let p = path(rect)
    (inverted ? ink : paper).setFill()
    p.fill()
    ink.setStroke()
    p.lineWidth = max(1.5, h * 0.1)
    p.stroke()
    let cx = (x0 + x1) / 2 + dir * g.frame / 4
    (text as NSString).draw(
      in: CGRect(x: cx - size.width / 2, y: g.yHome - size.height / 2 + h * 0.05, width: size.width, height: size.height),
      withAttributes: attributes)
  }

  /// Where the red begins: the engine's overpowered mark (11 o'clock), but never
  /// over the power target. The engine's own overpower cost starts past the
  /// target's top (core/throwplan `past = back - powerHi`), so a target that
  /// lies past 11 o'clock (a long throw) is not overpowered.
  func overStart(_ d: DialState) -> Double {
    max(d.overDeg, d.powerHi ?? 0)
  }

  /// The last throw's peak and stop, and the live peak.
  private func linearMarks(_ d: DialState, _ g: LinearMeter, lane: (CGFloat, CGFloat), live: Bool, lw: CGFloat) {
    let laneC = (lane.0 + lane.1) / 2
    let dr = g.laneWidth * 0.26
    func dot(_ a: Double, solid: Bool) {
      let p = CGPoint(x: laneC, y: g.y(arm: max(-180, min(180, a))))
      disk(p, dr + lw, paper)
      if solid {
        disk(p, dr - lw * 0.5, ink)
      } else {
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(lw * 1.4)
        context.strokeEllipse(in: CGRect(x: p.x - dr, y: p.y - dr, width: 2 * dr, height: 2 * dr))
      }
    }
    if let b = d.lastBack { dot(-b, solid: false) }
    if let s = d.lastStop { dot(s, solid: false) }
    if live && d.back > 0 { dot(-min(180, d.back), solid: true) }
  }
}
