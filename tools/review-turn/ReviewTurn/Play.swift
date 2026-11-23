import ObjectiveC
import XCTest

/// Plays the running app with a finger, for the App Store preview footage
/// (tools/store-previews.py; simulator only, never the app's tests). The app is the
/// build as it is: nothing is launched with a review mode, and every touch goes in
/// through the simulator's own event path, as a finger's does. Each step prints
/// `PLAY <n> <verb> <seconds since 1970>` as it starts, and a swing `PLAY <n> release
/// <seconds>` for the moment its finger lifts, so the tool can cut the recording by them.
///
/// TEST_RUNNER_PLAY is a list of steps, `;` between them, in screen points:
///
///   wait <seconds>
///   tap <x> <y>
///   drag <x1> <y1> <x2> <y2> <seconds>
///   swing <cx> <cy> <radius> <back> <stop> [<back deg/s> <flick deg/s> <hold>]
///
/// `swing` is a throw on the clock at (cx, cy): a press on the ring at six, round to
/// `back` degrees on the left, held `hold` seconds, a flick through six to `stop`
/// degrees on the right and the finger lifted (the dial's own angles: 0 is six, the
/// backswing negative).
///
/// XCTest's public gestures are one straight stroke; a throw is a curve with a slow
/// part and a fast part in one touch, so the path is built with the same event
/// classes XCTest's own gestures use (XCPointerEventPath, XCSynthesizedEventRecord).
final class Play: XCTestCase {
  @MainActor func testPlay() throws {
    let script = ProcessInfo.processInfo.environment["PLAY"] ?? ""
    for (index, step) in script.split(separator: ";").enumerated() {
      let words = step.split(separator: " ").map(String.init)
      guard let verb = words.first else { continue }
      let n = words.dropFirst().map { Double($0) ?? 0 }
      let began = Date().timeIntervalSince1970
      print("PLAY \(index) \(verb) \(began)")
      switch verb {
      case "wait":
        Thread.sleep(forTimeInterval: n[0])
      case "tap":
        let p = CGPoint(x: n[0], y: n[1])
        try touch([(p, 0), (p, 0.06)])
      case "drag":
        let a = CGPoint(x: n[0], y: n[1]), b = CGPoint(x: n[2], y: n[3])
        try touch(line(a, b, seconds: n[4], rest: 0.15))
      case "swing":
        let path = swing(
          center: CGPoint(x: n[0], y: n[1]), radius: n[2], back: n[3], stop: n[4],
          backRate: n.count > 5 ? n[5] : 400, flickRate: n.count > 6 ? n[6] : 2400,
          hold: n.count > 7 ? n[7] : 0.12)
        print("PLAY \(index) release \(began + (path.last?.1 ?? 0))")
        try touch(path)
      default:
        XCTFail("unknown step \(verb)")
      }
    }
  }

  /// A straight stroke, a sample every 60th of a second, the finger resting at its end.
  private func line(_ a: CGPoint, _ b: CGPoint, seconds: Double, rest: Double) -> [(CGPoint, Double)] {
    let steps = max(1, Int((seconds * 60).rounded()))
    var out: [(CGPoint, Double)] = [(a, 0), (a, 0.08)]
    for i in 1...steps {
      let t = Double(i) / Double(steps)
      // eased, as a finger starts and stops
      let e = t * t * (3 - 2 * t)
      out.append((CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), 0.08 + seconds * t))
    }
    out.append((b, 0.08 + seconds + rest))
    return out
  }

  /// The clock's swing as points on its ring and when the finger is at each.
  private func swing(
    center: CGPoint, radius: Double, back: Double, stop: Double, backRate: Double, flickRate: Double,
    hold: Double
  ) -> [(CGPoint, Double)] {
    func at(_ arm: Double) -> CGPoint {
      let a = arm * .pi / 180
      return CGPoint(x: center.x + sin(a) * radius, y: center.y + cos(a) * radius)
    }
    let dt = 1.0 / 60
    var out: [(CGPoint, Double)] = [(at(0), 0)]
    var t = 0.1, a = 0.0
    out.append((at(0), t))
    while a > -back {
      a = max(-back, a - backRate * dt)
      t += dt
      out.append((at(a), t))
    }
    t += hold
    out.append((at(a), t))
    while a < stop {
      a = min(stop, a + flickRate * dt)
      t += dt
      out.append((at(a), t))
    }
    return out
  }

  private enum PlayError: Error { case noEventClasses, refused(String) }

  /// One finger down at the first point, through each point at its time, and up.
  private func touch(_ points: [(CGPoint, Double)]) throws {
    guard let pathClass = NSClassFromString("XCPointerEventPath"),
      let recordClass = NSClassFromString("XCSynthesizedEventRecord"),
      let first = points.first, let last = points.last
    else { throw PlayError.noEventClasses }
    typealias Raw = UnsafeMutableRawPointer
    func imp<T>(_ cls: AnyClass, _ name: String, as _: T.Type) throws -> (T, Selector) {
      let sel = NSSelectorFromString(name)
      guard let m = class_getInstanceMethod(cls, sel) else { throw PlayError.refused(name) }
      return (unsafeBitCast(method_getImplementation(m), to: T.self), sel)
    }
    func make(_ cls: AnyClass) throws -> Raw {
      guard let o = class_createInstance(cls, 0) else { throw PlayError.noEventClasses }
      return Unmanaged.passRetained(o as AnyObject).toOpaque()
    }
    let (initPath, initPathSel) = try imp(
      pathClass, "initForTouchAtPoint:offset:",
      as: (@convention(c) (Raw, Selector, CGPoint, Double) -> Raw).self)
    let (move, moveSel) = try imp(
      pathClass, "moveToPoint:atOffset:", as: (@convention(c) (Raw, Selector, CGPoint, Double) -> Void).self)
    let (lift, liftSel) = try imp(
      pathClass, "liftUpAtOffset:", as: (@convention(c) (Raw, Selector, Double) -> Void).self)
    let (initRecord, initRecordSel) = try imp(
      recordClass, "initWithName:interfaceOrientation:",
      as: (@convention(c) (Raw, Selector, NSString, Int) -> Raw).self)
    let (add, addSel) = try imp(
      recordClass, "addPointerEventPath:", as: (@convention(c) (Raw, Selector, Raw) -> Void).self)
    let (send, sendSel) = try imp(
      recordClass, "synthesizeWithError:",
      as: (@convention(c) (Raw, Selector, UnsafeMutablePointer<NSError?>?) -> Bool).self)

    let path = initPath(try make(pathClass), initPathSel, first.0, first.1)
    for p in points.dropFirst() { move(path, moveSel, p.0, p.1) }
    lift(path, liftSel, last.1 + 0.01)
    let record = initRecord(
      try make(recordClass), initRecordSel, "play", UIInterfaceOrientation.portrait.rawValue)
    add(record, addSel, path)
    var error: NSError?
    if !send(record, sendSel, &error) { throw PlayError.refused(error?.localizedDescription ?? "touch") }
  }
}
