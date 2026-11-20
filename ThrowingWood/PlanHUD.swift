import UIKit

extension PracticeHUD {
  /// While TILT is held: the baton as it leaves the hand, standing over the aim
  /// circle and leaning by the tilt as the thrower sees it from behind (the
  /// engine turns the baton's plane toward the right by the tilt:
  /// core/world.lua `batonLaunchState`), beside a dashed upright for the
  /// straight throw. Plain wood, no bands, as on the pitch (Jamie, 2026-11-20).
  /// Drawn only; nothing here reaches the engine.
  func leaningBaton(at circle: CGPoint, tiltDegrees: Double) {
    let ink = UIColor(red: 0.09, green: 0.078, blue: 0.059, alpha: 1)
    let wood = UIColor(red: 0.95, green: 0.89, blue: 0.75, alpha: 1)
    let length: CGFloat = 62, width: CGFloat = 11
    let foot = CGPoint(x: circle.x, y: circle.y - 10)
    context.saveGState()
    defer { context.restoreGState() }
    // the straight throw
    context.setStrokeColor(ink.withAlphaComponent(0.7).cgColor)
    context.setLineWidth(2)
    context.setLineDash(phase: 0, lengths: [5, 4])
    context.beginPath()
    context.move(to: foot)
    context.addLine(to: CGPoint(x: foot.x, y: foot.y - length - 8))
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])
    // the baton, turned about its foot
    context.translateBy(x: foot.x, y: foot.y)
    context.rotate(by: tiltDegrees * .pi / 180)
    let body = CGRect(x: -width / 2, y: -length, width: width, height: length)
    let shadow = UIBezierPath(roundedRect: body.offsetBy(dx: 2, dy: 3), cornerRadius: width / 2)
    ink.setFill()
    shadow.fill()
    let path = UIBezierPath(roundedRect: body, cornerRadius: width / 2)
    wood.setFill()
    path.fill()
    ink.setStroke()
    path.lineWidth = 2
    path.stroke()
  }
}
