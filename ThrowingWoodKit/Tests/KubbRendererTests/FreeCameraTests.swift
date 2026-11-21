import CoreGraphics
import Foundation
import Testing

@testable import KubbEngine
@testable import KubbRenderer

/// The watcher's free camera (the web's docs/OBSERVER.md and freecam.js numbers), the
/// wide view it flies in, and the watcher's hand-off words.
@Suite @MainActor struct FreeCameraTests {
  static let phone = CGSize(width: 375, height: 667)  // the 16e's points
  static let phoneSafe = ScreenInsets(top: 20)
  static let phoneSide = CGSize(width: 667, height: 375)
  static let ipad = CGSize(width: 1032, height: 1376)  // the iPad Pro 13-inch

  func close(_ a: Camera, _ b: Camera, _ eps: Double = 1e-9) -> Bool {
    let x = [a.px, a.py, a.pz, a.fx, a.fy, a.fz, a.rx, a.ry, a.rz, a.ux, a.uy, a.uz, a.f, a.cx, a.cy]
    let y = [b.px, b.py, b.pz, b.fx, b.fy, b.fz, b.rx, b.ry, b.rz, b.ux, b.uy, b.uz, b.f, b.cx, b.cy]
    return zip(x, y).allSatisfy { abs($0 - $1) <= eps }
  }

  /// core/camera.lua's lookAt in the engine's own Lua state, the fields it sets.
  @Test func lookAtIsTheEnginesLookAtToTheLastBit() throws {
    let engine = try Engine(appVersion: "test")
    try engine.run(
      """
      function observerLookAt(s)
        local v = {}
        for n in string.gmatch(s, "%S+") do v[#v + 1] = tonumber(n) end
        local c = tw.camera.new and tw.camera.new() or {}
        tw.camera.lookAt(c, v[1], v[2], v[3], v[4], v[5], v[6])
        local out = {}
        for _, k in ipairs({"px","py","pz","fx","fy","fz","rx","ry","rz","ux","uy","uz","lx","ly","lz"}) do
          out[#out + 1] = string.format("%.17g", c[k])
        end
        return table.concat(out, " ")
      end
      """, name: "observer-test")
    let cases: [[Double]] = [
      [0, -9, 4.2, 0, 4, 0],
      [3.7, 12.25, 1.1, -0.4, 4.5, 0.3],
      [-6, 2, 0.35, 1.5, 9.75, 0],
      [0.001, -0.002, 24, 0, 0, 0],
      [-2.5, -2.5, 8.123456789, 4, 10.5, 0.2],
    ]
    for v in cases {
      let lua = try engine.callGlobal("observerLookAt", v.map { String(format: "%.17g", $0) }.joined(separator: " "))
        .split(separator: " ").map { Double($0)! }
      let c = FreeCam.lookAt(px: v[0], py: v[1], pz: v[2], tx: v[3], ty: v[4], tz: v[5], f: 900, cx: 200, cy: 120)
      let mine = [c.px, c.py, c.pz, c.fx, c.fy, c.fz, c.rx, c.ry, c.rz, c.ux, c.uy, c.uz, c.lx!, c.ly!, c.lz!]
      #expect(mine == lua, "lookAt \(v)")
    }
  }

  /// The free camera starts at the engine's wide camera, untouched, and its orbit gives
  /// that camera back.
  @Test func itStartsAtTheEnginesWideCamera() throws {
    let pitch = try PitchSession(appVersion: "test")
    #expect(try pitch.watchWide(size: Self.phone, safe: Self.phoneSafe))
    #expect(pitch.wideOn && pitch.freeOn)
    let lens = try #require(pitch.freeCamera.lens)
    #expect(lens.lx != nil && lens.ly != nil && lens.lz != nil)
    #expect(!pitch.freeCamera.moved)
    #expect(close(pitch.shownCamera, pitch.camera, 0))
    let again = FreeCam.camera(FreeCam.orbit(of: lens), lens: lens)
    #expect(close(again, lens, 1e-9))
    // the lens is unchanged by a move: closer is the eye moving
    pitch.moveFree { $0.zoomBy(0.5) }
    #expect(pitch.freeCamera.moved)
    #expect(pitch.shownCamera.f == lens.f && pitch.shownCamera.cx == lens.cx && pitch.shownCamera.cy == lens.cy)
    try pitch.endWide()
    #expect(!pitch.wideOn && !pitch.freeOn && !pitch.freeCamera.moved)
  }

  @Test func theWideViewFitsOnEveryScreenAndOffWhereKubbsAreTooSmall() throws {
    let pitch = try PitchSession(appVersion: "test")
    #expect(try pitch.watchWide(size: Self.phoneSide, safe: ScreenInsets(left: 47, bottom: 21, right: 47)))
    #expect(try pitch.watchWide(size: Self.ipad, safe: ScreenInsets(top: 24, bottom: 20)))
    #expect(try pitch.watchWide(size: CGSize(width: 40, height: 60), safe: ScreenInsets()) == false)
    #expect(!pitch.wideOn)
  }

  /// A first look that does not fit leaves the engine in the thrower's view, not in a
  /// wide view this session never showed.
  @Test func aWideViewThatDoesNotFitLeavesTheEngineInTheThrowersView() throws {
    let pitch = try PitchSession(appVersion: "test")
    let before: ViewOutput = try pitch.read("view")
    #expect(try pitch.watchWide(size: CGSize(width: 40, height: 60), safe: ScreenInsets()) == false)
    #expect(!pitch.wideOn && !pitch.freeOn)
    let after: ViewOutput = try pitch.read("view")
    #expect(close(after.camera, before.camera, 0))
    #expect(close(pitch.camera, before.camera, 0))
  }

  @Test func theBoxIsTheWebsWideBox() {
    // upright: the HUD's top is 132 pt; on its side, 70
    let up = WatchView.box(size: Self.phone, safe: Self.phoneSafe)
    let k = 375.0 / 400, oy = (667 - 240 * k) / 2
    #expect(abs(up.left - 16 / k) < 1e-9 && abs(up.right - (375 - 16) / k) < 1e-9)
    #expect(abs(up.top - (152 - oy) / k) < 1e-9 && abs(up.bottom - (667 - 16 - oy) / k) < 1e-9)
    let side = WatchView.box(size: Self.phoneSide, safe: ScreenInsets(left: 47, right: 47))
    let ks = 375.0 / 240, ox = (667 - 400 * ks) / 2
    #expect(abs(side.top - 70 / ks) < 1e-9)
    #expect(abs(side.left - (47 + 16 - ox) / ks) < 1e-9)
  }

  @Test func theOrbitStaysInsideTheWebsLimits() {
    let o = Orbit(yaw: 7, pitch: 2, dist: 100, tx: 9, ty: -9, tz: 0)
    let c = FreeCam.clamped(o)
    #expect(c.dist == 24 && c.tx == 4 && c.ty == -2.5)
    #expect(abs(c.pitch - 86 * .pi / 180) < 1e-12)
    #expect(c.yaw > -.pi && c.yaw <= .pi)
    let low = FreeCam.clamped(Orbit(yaw: 0, pitch: 0, dist: 0.1, tx: 0, ty: 4, tz: 0))
    #expect(low.dist == 2.5)
    #expect(FreeCam.eye(of: low).z >= 0.35 - 1e-12)
    let tilt = FreeCam.turn(Orbit(yaw: 0, pitch: 0.5, dist: 10, tx: 0, ty: 4, tz: 0), 0, -5)
    #expect(abs(tilt.pitch - 4 * .pi / 180) < 1e-12)
  }

  @Test func gesturesTurnZoomAndSlide() throws {
    let cam = FreeCamera()
    cam.setLens(FreeCam.lookAt(px: 0, py: -9, pz: 4, tx: 0, ty: 4, tz: 0, f: 900, cx: 200, cy: 120))
    let start = FreeCam.orbit(of: cam.lens!)
    cam.oneFinger(dx: 100, dy: 0)
    #expect(abs(FreeCam.wrap(cam.orbit!.yaw - start.yaw) + 0.6) < 1e-9)
    cam.home()
    cam.oneFinger(dx: 0, dy: 50)
    #expect(abs(cam.orbit!.pitch - start.pitch - 0.2) < 1e-9)
    cam.home()
    // two fingers spread to twice as far apart: half the distance
    cam.twoFingers(from: CGPoint(x: 150, y: 100), to: CGPoint(x: 200, y: 100), other: CGPoint(x: 100, y: 100))
    #expect(abs(cam.orbit!.dist - start.dist / 2) < 1e-9)
    let g = FreeCam.twoFingers(
      CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 10, y: 120))
    #expect(abs(g.scale - 1) < 1e-12 && abs(g.angle - .pi / 2) < 1e-12)
    #expect(g.dx == -40 && g.dy == 70)
  }

  @Test func resetEasesBackOrJumpsWithReduceMotion() {
    let cam = FreeCamera()
    cam.setLens(FreeCam.lookAt(px: 0, py: -9, pz: 4, tx: 0, ty: 4, tz: 0, f: 900, cx: 200, cy: 120))
    cam.zoomBy(0.5)
    cam.reset(reduced: false)
    #expect(cam.easing && cam.moved)
    #expect(cam.tick(0.2))
    #expect(cam.moved)
    #expect(cam.tick(0.25 + 1e-9))
    #expect(!cam.moved && !cam.easing)
    #expect(!cam.tick(0.1))
    cam.zoomBy(2)
    cam.reset(reduced: true)
    #expect(!cam.moved && !cam.easing)
    // a resize keeps the orbit chosen; letting go of the lens forgets it
    cam.turnBy(0.3, 0)
    cam.setLens(FreeCam.lookAt(px: 0, py: -10, pz: 4, tx: 0, ty: 4, tz: 0, f: 700, cx: 200, cy: 120))
    #expect(cam.moved)
    cam.setLens(nil)
    #expect(!cam.moved)
  }

  @Test func observeLinksOpenWatching() throws {
    let link = try #require(PitchLink("https://throwingwood.com/p/mapkubb2?observe=1"))
    #expect(link.observe && link.code == "mapkubb2")
    #expect(link.url.absoluteString == "https://throwingwood.com/p/mapkubb2")
    #expect(PitchLink("https://throwingwood.com/p/mapkubb2")?.observe == false)
    #expect(PitchLink("https://throwingwood.com/p/mapkubb2?observe=0")?.observe == false)
    #expect(PitchLink("mapkubb2")?.observing(true).observe == true)
  }

  func handoff(_ json: String) throws -> MatchNeed.Handoff {
    try JSONDecoder().decode(MatchNeed.Handoff.self, from: Data(json.utf8))
  }

  @Test func aWatcherSeesBothTeamsByName() throws {
    let c = try handoff(
      #"{"toName":"North","fromName":"South","turn":3,"kubbs":2,"batons":6,"baseText":["YOUR BASE 4","THEIRS 5"],"to":"A","from":"B","base":[5,4]}"#
    )
    #expect(HandoffWords.watcherBases(c) == ["SOUTH BASE 5", "NORTH BASE 4"])
    #expect(HandoffWords.watcherBases(c, teams: ["A": "Oaks", "B": ""]) == ["SOUTH BASE 5", "OAKS BASE 4"])
    #expect(HandoffWords.throwLine(c, watcher: true) == "2 kubbs in, then 6 batons.")
    #expect(HandoffWords.throwLine(c, watcher: false) == "Throw 2 kubbs in, then 6 batons.")
    let first = try handoff(#"{"toName":"","turn":1,"kubbs":0,"batons":6,"baseText":[],"to":"B","base":[5,5]}"#)
    #expect(HandoffWords.watcherBases(first) == ["TEAM A BASE 5", "TEAM B BASE 5"])
    #expect(HandoffWords.throwLine(first, watcher: true) == "They throw 6 batons.")
    let old = try handoff(#"{"toName":"North","turn":1,"kubbs":1,"batons":6,"baseText":["YOUR BASE 5"]}"#)
    #expect(HandoffWords.watcherBases(old).isEmpty)
    #expect(HandoffWords.throwLine(old, watcher: true) == "1 kubb in, then 6 batons.")
  }
}
