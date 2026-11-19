import KubbRenderer
import UIKit

/// The throw's coach line (KubbRenderer Coach.swift), drawn as the web's
/// `.coach` (game.css, hud.js showCoach): just over the meter's prompt so the
/// two read as one, centred over the clock's plate or from the linear meter's
/// inner edge over its tab, at most 280 pt wide and short of any plan column
/// level with it. Words only: it takes no touches.
extension PracticeHUD {
  enum CoachAlign { case center, left, right }

  struct CoachPlace: Equatable {
    var bottom, anchor: CGFloat
    var align: CoachAlign
  }

  static let coachMax: CGFloat = 280

  /// Where the line goes over a meter (the web's numbers).
  static func coachPlace(_ meter: MeterLayout) -> CoachPlace {
    switch meter {
    case .clock(let c):
      // the prompt plate (dial(...): centred r + 20 over the hub, Londrina 20)
      let font = UIFont(name: "LondrinaSolid-Black", size: 20) ?? .boldSystemFont(ofSize: 20)
      let half = ("W" as NSString).size(withAttributes: [.font: font]).height / 2 + 3
      return CoachPlace(bottom: c.center.y - c.radius - 20 - half - 8, anchor: c.center.x, align: .center)
    case .linear(let g):
      let right = g.side == .right
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
    for r in plans where r.width > 0 && !(r.maxY < p.bottom - 76 || r.minY > p.bottom) {
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

  func coach(_ c: Coach.Line, _ p: CoachPlace, left: CGFloat, width: CGFloat) {
    guard width > 40 else { return }
    let font = UIFont.systemFont(ofSize: 13, weight: .heavy)
    let lineHeight: CGFloat = 13 * 1.25
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
    style.alignment = p.align == .center ? .center : (p.align == .right ? .right : .left)
    var y = p.bottom
    // drawn from the foot up: the line, then the lead over it
    for (text, inverted) in [(c.line, false), (c.lead, true)] {
      guard let text else { continue }
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .kern: 13 * 0.04, .paragraphStyle: style,
        .foregroundColor: inverted ? paper : ink,
      ]
      let inner = width - 20  // 8 padding and 2 border each side
      let s = Self.balanced(text.uppercased() as NSString, attributes, inner, lineHeight)
      let w = s.width + 20
      let h = s.height + 3 + 4 + 4
      let x =
        switch p.align {
        case .center: left + (width - w) / 2
        case .right: left + width - w
        case .left: left
        }
      let box = CGRect(x: x, y: y - h, width: w, height: h).insetBy(dx: 1, dy: 1)
      let path = UIBezierPath(roundedRect: box, cornerRadius: 4)
      ink.setFill()
      UIBezierPath(roundedRect: box.offsetBy(dx: 2, dy: 2), cornerRadius: 4).fill()
      (inverted ? ink : paper).setFill()
      path.fill()
      ink.setStroke()
      path.lineWidth = 2
      path.stroke()
      (text.uppercased() as NSString).draw(
        with: CGRect(x: x + 10, y: y - h + 5, width: s.width, height: s.height),
        options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
      y -= h + 4
    }
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
