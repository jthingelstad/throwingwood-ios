import KubbRenderer
import UIKit

@MainActor struct PracticeHUD {
  let context: CGContext, size: CGSize
  /// The scene's skin (Skin.swift): the day's colours are the HUD's as they always were.
  let skin = SkinStore.shared.skin
  /// The meters' lines and type, and their faces (the web's HUD frame and face).
  var ink: UIColor { UIColor(skin.frame) }
  var paper: UIColor { UIColor(skin.face) }
  /// A prompt plate's type and face.
  var type: UIColor { UIColor(skin.promptInk) }
  var plateFace: UIColor { UIColor(skin.prompt) }
  private var drop: UIColor { skin.isDay ? ink : UIColor(skin.drop) }

  func disk(_ p: CGPoint, _ r: CGFloat, _ paint: UIColor) {
    context.setFillColor(paint.cgColor)
    context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
  }
  func line(_ a: CGPoint, _ b: CGPoint, _ color: UIColor, _ width: Double) {
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width)
    context.beginPath()
    context.move(to: a)
    context.addLine(to: b)
    context.strokePath()
  }
  /// The width a plated word takes (its plate 9 pt wider each side than the word).
  func plateWidth(_ word: String, size: Double) -> CGFloat {
    let font = UIFont(name: "LondrinaSolid-Black", size: size) ?? UIFont.boldSystemFont(ofSize: size)
    return (word as NSString).size(withAttributes: [.font: font]).width + 18
  }

  /// `fill`: the plate's own face and type (an inverted tab: ink with paper type; the
  /// WATCH tab: the thrower's team colour).
  func text(
    _ word: String, at p: CGPoint, size: Double, color: UIColor, plate: Bool = false,
    outlined: Bool = false, fill: UIColor? = nil
  ) {
    let font =
      UIFont(name: "LondrinaSolid-Black", size: size) ?? UIFont.boldSystemFont(ofSize: size)
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if outlined {
      attributes[.strokeColor] = skin.isDay ? ink : UIColor(skin.star)
      attributes[.strokeWidth] = -5
    }
    let s = (word as NSString).size(withAttributes: attributes)
    let rect = CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height)
    if plate {
      let box = rect.insetBy(dx: -9, dy: -3)
      drop.setFill()
      UIBezierPath(roundedRect: box.offsetBy(dx: 2, dy: 3), cornerRadius: 4).fill()
      (fill ?? plateFace).setFill()
      let path = UIBezierPath(roundedRect: box, cornerRadius: 4)
      path.fill()
      (fill == nil ? type : ink).setStroke()
      path.lineWidth = 2
      path.stroke()
    }
    (word as NSString).draw(in: rect, withAttributes: attributes)
  }

  /// `hintBeside`: on a phone on its side there is no room under the ring, so
  /// the practice hint goes level with its foot on the screen's inner side.
  /// `distance`: the throw's distance ("8 m") on an inverted tab beside the prompt, the
  /// pair centred over the clock (the 1.0 design's "Meter marks and distance").
  /// `tab`: a WATCH tab in place of the prompt, on the thrower's team colour.
  func dial(_ d: DialState, at c: CGPoint, radius r: Double, showHint: Bool, finger: CGPoint? = nil,
    prompt: String?? = nil, hintBeside: MeterSide? = nil, distance: String? = nil
  ) {
    context.saveGState()
    defer { context.restoreGState() }
    context.setLineCap(.round)
    func at(_ a: Double, _ radius: Double) -> CGPoint {
      CGPoint(x: c.x + sin(a * .pi / 180) * radius, y: c.y + cos(a * .pi / 180) * radius)
    }
    disk(CGPoint(x: c.x + r * 0.05, y: c.y + r * 0.06), r, drop)
    disk(c, r, ink)
    disk(c, r * 0.96, paper)
    func sector(_ a: Double?, _ b: Double?, _ color: UIColor) {
      guard let a, let b, b > a else { return }
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(r * 0.17)
      context.setLineCap(.butt)
      context.beginPath()
      context.addArc(
        center: c, radius: r * 0.85, startAngle: (90 - b) * .pi / 180,
        endAngle: (90 - a) * .pi / 180, clockwise: false)
      context.strokePath()
    }
    sector(-180, 180, UIColor(skin.ring))
    sector(-180, -overStart(d), skin.isDay ? .systemRed : UIColor(skin.over))  // never over the power target
    sector(-d.deadDeg, 0, skin.isDay ? .systemGray3 : UIColor(skin.dead))
    // the power band striped, the release band solid, both with ink end-marks: told
    // apart by shape, never by colour alone (the 1.0 design)
    if let hi = d.powerHi, let lo = d.powerLo, hi > lo {
      context.saveGState()
      context.setLineWidth(r * 0.17)
      context.beginPath()
      context.addArc(
        center: c, radius: r * 0.85, startAngle: (90 + hi) * .pi / 180, endAngle: (90 + lo) * .pi / 180,
        clockwise: true)
      context.replacePathWithStrokedPath()
      context.clip()
      stripes(around: c, radius: r, UIColor(skin.power))
      context.restoreGState()
    }
    sector(d.releaseLo, d.releaseHi, UIColor(skin.release))
    let markW = max(2, r * 0.032)
    for a in [d.powerHi.map { -$0 }, d.powerLo.map { -$0 }, d.releaseLo, d.releaseHi].compactMap({ $0 }) {
      context.setLineCap(.butt)
      line(at(a, r * 0.75), at(a, r * 0.95), ink, markW)
    }
    for h in 0..<12 {
      let major = h.isMultiple(of: 3)
      let angle = Double(h) * 30
      line(at(angle, r * 0.76), at(angle, r * (major ? 0.58 : 0.66)), UIColor(skin.tick), major ? 3 : 1.7)
    }
    // the last throw's peak and stop: ghosts of the knob where it was, never rings
    // (a tester read the rings as targets)
    for angle in [d.lastBack.map { -$0 }, d.lastStop].compactMap({ $0 }) {
      ghostKnob(at(angle, r * 0.82), r * 0.145) { p, kr in
        disk(p, kr, ink)
        disk(p, kr * 0.115 / 0.145, UIColor(skin.meterKnob))
      }
    }
    context.setLineCap(.round)
    let knob = at(d.phase == "idle" ? d.crank : d.arm, r * 0.82)
    if let f = finger {
      // a finger turning the arm from beside the ring: a spoke from the knob to it
      let lw = max(1, r * 0.022)
      line(knob, f, paper, lw * 2.6)
      line(knob, f, ink, lw * 1.1)
      disk(f, r * 0.11 + lw * 1.2, paper)
      context.setStrokeColor(ink.cgColor)
      context.setLineWidth(lw * 1.5)
      context.strokeEllipse(in: CGRect(x: f.x - r * 0.11, y: f.y - r * 0.11, width: r * 0.22, height: r * 0.22))
    }
    line(c, knob, ink, 0.08 * r)
    line(c, knob, skin.isDay ? UIColor.brown : UIColor(skin.hand), 0.04 * r)
    disk(c, r * 0.07, ink)
    disk(knob, r * 0.145, ink)
    disk(knob, r * 0.115, UIColor(skin.meterKnob))
    if let prompt = prompt ?? d.prompt {
      let y = c.y - r - 20
      if let distance, MeterWords.showsDistance(prompt) {
        let wp = plateWidth(prompt, size: 20), wd = plateWidth(distance, size: 20)
        let left = c.x - (wp + 8 + wd) / 2
        text(prompt, at: CGPoint(x: left + wp / 2, y: y), size: 20, color: type, plate: true)
        text(distance, at: CGPoint(x: left + wp + 8 + wd / 2, y: y), size: 20, color: paper, plate: true, fill: ink)
      } else {
        text(prompt, at: CGPoint(x: c.x, y: y), size: 20, color: type, plate: true)
      }
    }
    if showHint {
      let words = "Tap or drag to aim · Circle dial to throw"
      var at = CGPoint(x: c.x, y: c.y + r + 24)
      if let side = hintBeside {
        let font = UIFont(name: "LondrinaSolid-Black", size: 16) ?? .boldSystemFont(ofSize: 16)
        let half = (words as NSString).size(withAttributes: [.font: font]).width / 2 + 6
        let off = r * 1.12 + 12 + half
        at = CGPoint(x: side == .right ? c.x - off : c.x + off, y: c.y + r * 0.85)
      }
      text(words, at: at, size: 16, color: type, plate: true)
    }
  }

  /// Diagonal stripes of `color` over the meter's face, 6 pt apart (3 of colour, 3 of
  /// face), across the clip the caller set.
  func stripes(around c: CGPoint, radius r: Double, _ color: UIColor) {
    let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    stripes(in: box, color)
  }
  func stripes(in box: CGRect, _ color: UIColor, step: CGFloat = 6) {
    context.setFillColor(paper.cgColor)
    context.fill(box)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(step / 2)
    context.setLineCap(.butt)
    var x = box.minX - box.height
    context.beginPath()
    while x < box.maxX + box.height {
      context.move(to: CGPoint(x: x, y: box.maxY))
      context.addLine(to: CGPoint(x: x + box.height, y: box.minY))
      x += step
    }
    context.strokePath()
  }

  /// The WATCH tab (the computer's or another player's turn), where the prompt goes, on
  /// the thrower's team colour.
  func watchTab(at p: CGPoint, size: Double, fill: UIColor, type: UIColor) {
    text(MeterWords.watch, at: p, size: size, color: type, plate: true, fill: fill)
  }

  /// An end's number beside its footprint on the raise screen (the web's drawEndLabels):
  /// gold when lit (a drag past half way, or the allowed end's hint), grey when refused.
  func endLabel(_ e: RaiseEndPoint) {
    let r = RaiseTouch.numberR
    let p = e.label
    disk(CGPoint(x: p.x + 3, y: p.y + 3), r, drop)
    let fill = UIColor(!e.ok ? skin.endRefused : e.lit ? skin.endLit : skin.face)
    disk(p, r, fill)
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(3)
    context.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    // a scene's lit end is light: its number the skin's on-accent
    let number = e.ok && e.lit && !skin.isDay ? UIColor(skin.onAccent) : skin.isDay ? ink : UIColor(skin.ink)
    text(String(e.index + 1), at: CGPoint(x: p.x, y: p.y + 1), size: 22, color: number, plate: false)
  }

  func burst(_ b: HitBurst, at anchor: CGPoint) {
    let width = max(90, min(size.width, size.height) * 0.3)
    // the day's: an ink star round a yellow inside; a scene's its own (BURST)
    let ink = skin.isDay ? self.ink : UIColor(skin.star)
    let paper = skin.isDay ? self.paper : UIColor(skin.flash)
    let yellow = UIColor(skin.inner)
    let crownFill = UIColor(skin.crown)
    func polygon(_ points: [CGPoint], _ color: UIColor) {
      let path = UIBezierPath()
      path.move(to: points[0])
      for p in points.dropFirst() { path.addLine(to: p) }
      path.close()
      color.setFill()
      path.fill()
    }
    func star(_ word: String, age: Double, tip: CGPoint, w: Double, seed: UInt32) {
      guard age >= 0, age < 0.6 else { return }
      var state = seed
      func random() -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Double(state % 10000) / 10000
      }
      let c = CGPoint(x: tip.x - w * 0.42, y: tip.y - w * 0.5)
      if age < 2.0 / 30 {
        let r = w * (0.25 + 0.35 * age * 15)
        disk(tip, r, ink)
        disk(tip, r - max(2, w * 0.03), paper)
        for i in 0..<8 {
          let a = Double(i) * .pi / 4 + 0.2
          func ray(_ scale: Double) -> CGPoint {
            CGPoint(x: tip.x + cos(a) * r * scale, y: tip.y + sin(a) * r * scale)
          }
          line(ray(1.15), ray(1.6), ink, max(2, w * 0.03))
        }
      } else if age < 14.0 / 30 {
        let grow = min(1, 0.7 + 0.3 * (age - 2.0 / 30) / 0.06)
        let direction = atan2(tip.y - c.y, tip.x - c.x)
        var points = [tip]
        for i in 1..<22 {
          let a = direction + Double(i) * .pi / 11
          let r =
            w * 0.5 * grow * (i.isMultiple(of: 2) ? 0.86 + random() * 0.16 : 0.58 + random() * 0.08)
          points.append(CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r * 0.78))
        }
        let shadow = max(2, w * 0.035) * 1.6
        polygon(points.map { CGPoint(x: $0.x + shadow, y: $0.y + shadow) }, ink)
        polygon(points, ink)
        polygon(
          points.map { CGPoint(x: c.x + ($0.x - c.x) * 0.84, y: c.y + ($0.y - c.y) * 0.84) },
          b.kind == "king" ? UIColor(skin.kingInner) : yellow
        )
        text(word, at: c, size: w * 0.27 * grow, color: UIColor(skin.word), outlined: true)
        if b.kind == "king" {
          let by = c.y - w * 0.14
          let side = w * 0.14
          let h = side * 1.1
          let crown = [
            CGPoint(x: c.x - side, y: by), CGPoint(x: c.x - side, y: by - h),
            CGPoint(x: c.x - side / 2, y: by - h / 2), CGPoint(x: c.x, y: by - h * 1.1),
            CGPoint(x: c.x + side / 2, y: by - h / 2), CGPoint(x: c.x + side, y: by - h),
            CGPoint(x: c.x + side, y: by),
          ]
          polygon(crown, ink)
          polygon(
            crown.map {
              CGPoint(x: c.x + ($0.x - c.x) * 0.77, y: by - h * 0.40 + ($0.y - by + h * 0.4) * 0.77)
            }, crownFill)
        }
      } else {
        let k = (age - 14.0 / 30) * 7.5
        for i in 0..<9 {
          let a = random() * 2 * .pi
          let d = w * (0.25 + random() * 0.35) * (0.5 + k)
          let side = w * (0.05 + random() * 0.05) * (1 - k * 0.6)
          context.saveGState()
          context.translateBy(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.8 + k * k * w * 0.25)
          context.rotate(by: random() * .pi + k * (random() - 0.5) * 6)
          let chip = skin.isDay ? (i.isMultiple(of: 3) ? ink : UIColor.brown) : UIColor(skin.chip[i % skin.chip.count])
          context.setFillColor(chip.cgColor)
          context.fill(CGRect(x: -side / 2, y: -side * 0.35, width: side, height: side * 0.7))
          context.restoreGState()
        }
      }
    }
    if b.kind == "double" {
      star("KLAK", age: b.age, tip: anchor, w: width * 0.82, seed: 11)
      star(
        "KLAK!", age: b.age - 0.1,
        tip: CGPoint(x: anchor.x + width * 0.5, y: anchor.y - width * 0.3), w: width * 0.82,
        seed: 23)
    } else {
      let king = b.kind == "king"
      if king && b.age < 2.0 / 30 {
        context.saveGState()
        // the day inverts the screen; a scene lights it a moment instead
        context.setBlendMode(skin.kingFlashInverts ? .difference : .plusLighter)
        context.setFillColor(skin.kingFlashInverts ? UIColor.white.cgColor : UIColor(skin.flash).withAlphaComponent(0.22).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.restoreGState()
      }
      star(king ? "KING!" : "TOK!", age: b.age, tip: anchor, w: width, seed: king ? 31 : 7)
    }
  }
}
