import KubbRenderer
import UIKit

/// The throw's coach line (KubbRenderer Coach.swift), drawn as the web's
/// `.coach` (game.css, hud.js showCoach): just over the meter's prompt so the
/// two read as one, centred over the clock's plate or from the linear meter's
/// inner edge over its tab, at most 280 pt wide and short of any plan column
/// level with it. On a wide screen the linear meter's line hangs under its tab
/// instead (the tab is level with the far baseline there) and keeps to the
/// meter's half. Words only: it takes no touches.
extension PracticeHUD {
  enum CoachAlign { case center, left, right }

  struct CoachPlace: Equatable {
    var bottom, anchor: CGFloat
    var align: CoachAlign
    /// The line hangs from `bottom` (its top) instead of standing on it: the
    /// linear meter on a wide screen, whose tab is level with the far baseline.
    var hangs = false
  }

  static let coachMax: CGFloat = 280

  /// Where the line goes over a meter (the web's numbers).
  static func coachPlace(_ meter: MeterLayout, wide: Bool = false) -> CoachPlace {
    switch meter {
    case .clock(let c):
      // the prompt plate (dial(...): centred r + 20 over the hub, Londrina 20); the
      // chip stands 8 pt over it
      let font = UIFont(name: "LondrinaSolid-Black", size: 20) ?? .boldSystemFont(ofSize: 20)
      let half = ("W" as NSString).size(withAttributes: [.font: font]).height / 2 + 3
      return CoachPlace(bottom: c.center.y - c.radius - 20 - half - 8, anchor: c.center.x, align: .center)
    case .linear(let g):
      let right = g.side == .right
      if wide {
        // on its side the knob's home is level with the far baseline, so over
        // the tab the line would cover its kubbs: it hangs under the tab instead
        return CoachPlace(
          bottom: g.yHome + g.promptHeight / 2 + 8, anchor: right ? g.box.minX : g.box.maxX,
          align: right ? .right : .left, hangs: true)
      }
      return CoachPlace(
        bottom: g.yHome - g.promptHeight / 2 - 8, anchor: right ? g.box.minX : g.box.maxX,
        align: right ? .right : .left)
    }
  }

  /// The room either side of the anchor: inside the safe edges and short of
  /// the plan columns level with the line (up to 76 pt above its foot).
  static func coachWidth(
    _ p: CoachPlace, screen: CGSize, safeLeft: CGFloat, safeRight: CGFloat, plans: [CGRect]
  ) -> (left: CGFloat, width: CGFloat) {
    var lo = safeLeft + 8
    var hi = screen.width - safeRight - 8
    let band = p.hangs ? (p.bottom, p.bottom + 76) : (p.bottom - 76, p.bottom)
    for r in plans where r.width > 0 && !(r.maxY < band.0 || r.minY > band.1) {
      if r.maxX <= p.anchor { lo = max(lo, r.maxX + 8) } else if r.minX >= p.anchor { hi = min(hi, r.minX - 8) }
    }
    switch p.align {
    case .center:
      let w = min(coachMax, 2 * min(p.anchor - lo, hi - p.anchor))
      return (p.anchor - w / 2, w)
    case .right:
      let w = min(coachMax, p.anchor - lo)
      return (p.anchor.rounded(.down) - w, w)
    case .left:
      let w = min(coachMax, hi - p.anchor)
      return (p.anchor.rounded(.up), w)
    }
  }

  /// The coach's one style (the 1.0 design): an inverted ink chip, paper capitals in
  /// Inter 800 15 (the web's), standing on `bottom` (or hanging from it); the slow lead and the
  /// line in the same chip, the lead on its own first line, so there are never three
  /// pills at once. `beside` is no longer used: one chip has no lead beside it.
  func coach(_ c: Coach.Line, _ p: CoachPlace, left: CGFloat, width: CGFloat, beside: CoachAlign? = nil) {
    guard width > 40 else { return }
    let size: CGFloat = 15
    let font = Self.inter(size, .heavy)
    let lineHeight: CGFloat = size * 1.25
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
    style.alignment = p.align == .center ? .center : (p.align == .right ? .right : .left)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .kern: size * 0.04, .paragraphStyle: style, .foregroundColor: paper,
    ]
    let text = ([c.lead, c.line].compactMap { $0 }.joined(separator: "\n")).uppercased() as NSString
    let inner = width - 24  // 10 padding and 2 border each side
    let s = Self.balanced(text, attributes, inner, lineHeight)
    let w = s.width + 24
    let h = s.height + 12
    let x: CGFloat =
      switch p.align {
      case .center: left + (width - w) / 2
      case .right: left + width - w
      case .left: left
      }
    let top = p.hangs ? p.bottom : p.bottom - h
    let box = CGRect(x: x, y: top, width: w, height: h).insetBy(dx: 1, dy: 1)
    let path = UIBezierPath(roundedRect: box, cornerRadius: 6)
    ink.setFill()
    path.fill()
    ink.setStroke()
    path.lineWidth = 2
    path.stroke()
    text.draw(
      with: CGRect(x: x + 12, y: top + 6, width: s.width, height: s.height),
      options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
  }

  /// Inter (bundled, a variable font) at a weight.
  static func inter(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
    let d = UIFontDescriptor(fontAttributes: [.family: "Inter", .traits: [UIFontDescriptor.TraitKey.weight: weight]])
    let f = UIFont(descriptor: d, size: size)
    return f.familyName == "Inter" ? f : .systemFont(ofSize: size, weight: weight)
  }

  /// The text's size wrapped in `width`, as narrow as it can be on as many
  /// lines (CSS text-wrap: balance).
  private static func balanced(
    _ text: NSString, _ attributes: [NSAttributedString.Key: Any], _ width: CGFloat, _ lh: CGFloat
  ) -> CGSize {
    func size(_ w: CGFloat) -> CGSize {
      let r = text.boundingRect(
        with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
        attributes: attributes, context: nil)
      return CGSize(width: ceil(r.width), height: ceil(r.height))
    }
    let full = size(width)
    let lines = (full.height / lh).rounded()
    guard lines > 1 else { return full }
    var lo = width / lines, hi = width
    for _ in 0..<12 {
      let mid = (lo + hi) / 2
      if (size(mid).height / lh).rounded() > lines { lo = mid } else { hi = mid }
    }
    return size(hi)
  }
}
