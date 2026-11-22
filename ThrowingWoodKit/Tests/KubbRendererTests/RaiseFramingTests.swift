import CoreGraphics
import Foundation
import Testing
import simd

@testable import KubbRenderer

/// The raise scene shows about twice as much (the owner, 2026-11-22: "When raising kubbs
/// the camera view is too close. We need to see about twice as much to know how to raise
/// them."): the camera twice as far back, so twice the ground each way round the kubb, the
/// kubb drawn half as big; its touch target still at least 44 pt across, its numbers
/// apart and on the screen, and nothing of it under the panel, upright, on its side and on
/// an iPad, in a crowded raise and beside the sideline.
@MainActor struct RaiseFramingTests {
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  static let screens: [(name: String, size: CGSize, safe: ScreenInsets)] = [
    ("16e", CGSize(width: 390, height: 844), ScreenInsets(top: 47, bottom: 34)),
    ("17 Pro Max", CGSize(width: 440, height: 956), ScreenInsets(top: 62, bottom: 34)),
    ("iPad mini", CGSize(width: 744, height: 1133), ScreenInsets(top: 24, bottom: 20)),
    ("16e on its side", CGSize(width: 844, height: 390), ScreenInsets(left: 47, bottom: 20, right: 47)),
    ("17 Pro Max on its side", CGSize(width: 956, height: 440), ScreenInsets(left: 62, bottom: 20, right: 62)),
    ("iPad mini on its side", CGSize(width: 1133, height: 744), ScreenInsets(top: 24, bottom: 20)),
  ]

  /// pt a metre across the screen at the lying kubb, in `camera`.
  private func ptPerMetre(_ app: PitchSession, _ size: CGSize, camera: Camera) throws -> Double {
    let p = try #require(app.need?.pose)
    let pr = app.scene.projection(size, camera)
    let r = camera.right
    let a = try #require(pr.project(V3(p.x, p.y, 0) - r * 0.5))
    let b = try #require(pr.project(V3(p.x, p.y, 0) + r * 0.5))
    return Double(a.distance(to: b))
  }

  @Test func theRaiseShowsTwiceAsMuch() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise"), save: nil)
    let p = try #require(app.need?.pose)
    let a = p.angle ?? 0
    // the camera it had before 2026-11-22: 1.15 m back, 1.05 up, looking 0.12 toward it
    let axis = V2(cos(a), sin(a))
    var normal = V3(-axis.y, axis.x, 0)
    if normal.y > 0.05 || (abs(normal.y) <= 0.05 && normal.x * p.x > 0) { normal = -normal }
    let f = app.camera.forward
    let spot = V3(p.x, p.y, 0)
    let eye = spot + normal * 1.15 + V3(0, 0, 1.05), at = spot + normal * 0.12
    let fw = simd_normalize(at - eye), rt = simd_normalize(simd_cross(fw, V3(0, 0, 1))), up = simd_cross(rt, fw)
    let before = Camera(
      px: eye.x, py: eye.y, pz: eye.z, fx: fw.x, fy: fw.y, fz: fw.z, rx: rt.x, ry: rt.y, rz: rt.z,
      ux: up.x, uy: up.y, uz: up.z, f: 520, cx: 200, cy: 120)
    // the same angle down
    #expect(abs(simd_dot(f, fw) - 1) < 1e-9)
    for s in Self.screens {
      let now = try ptPerMetre(app, s.size, camera: app.camera)
      let was = try ptPerMetre(app, s.size, camera: before)
      // about twice the ground across the screen at the kubb
      #expect(abs(was / now - 2) < 0.1, "\(s.name): \(was / now)")
    }
  }

  /// The kubb in hand is easy to hit and its numbers easy to read, on every screen and in
  /// every raise the fixtures and two invented ones (a crowded group, the sideline) have.
  @Test func theKubbStaysEasyToHit() throws {
    var needs: [(String, PitchSession)] = []
    for name in ["raise", "raise-many", "raise-refused"] {
      let app = try PitchSession(appVersion: "test")
      try app.restore(fixture(name), save: nil)
      needs.append((name, app))
    }
    for (name, json) in [("crowded", Self.crowded), ("sideline", Self.sideline)] {
      let app = try PitchSession(appVersion: "test")
      try app.restore(fixture("raise"), save: nil)
      app.need = try JSONDecoder().decode(MatchNeed.self, from: Data(json.utf8))
      try app.settleScene()
      needs.append((name, app))
    }
    for (name, app) in needs {
      for s in Self.screens {
        let tag = "\(name), \(s.name)"
        let g = try #require(app.raiseGeometry(in: s.size), "\(tag)")
        let xs = g.outline.map(\.x), ys = g.outline.map(\.y)
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        // drawn smaller, but its target (the outline and the press margin round it) is
        // at least 44 pt across every way
        #expect(min(w, h) + 2 * RaiseTouch.margin >= 44, "\(tag)")
        #expect(max(w, h) >= 24, "\(tag): \(max(w, h))")
        // the ends' numbers: apart, clear of the kubb, on the screen
        let ends = app.raiseEnds(in: s.size)
        #expect(ends.count == 2, "\(tag)")
        if ends.count == 2 {
          #expect(ends[0].label.distance(to: ends[1].label) >= 2 * RaiseTouch.numberR + 4, "\(tag)")
        }
        let screen = CGRect(origin: .zero, size: s.size).insetBy(dx: RaiseTouch.numberR, dy: RaiseTouch.numberR)
        for e in ends { #expect(screen.contains(e.label), "\(tag)") }
        // upright the panel stands at the foot: the kubb, its numbers and the press round
        // it stay above the tallest panel (about 190 pt with two lines of words and the
        // buttons, more at the largest text sizes)
        if !WideLayout.isWide(s.size) {
          let floor = s.size.height - s.safe.bottom - 8 - 230
          #expect(ys.max()! + RaiseTouch.margin <= floor, "\(tag)")
          for e in ends { #expect(e.label.y + RaiseTouch.numberR <= floor, "\(tag)") }
        }
      }
    }
  }

  /// Seven kubbs in a group in the near half, the one to raise among them.
  static let crowded = #"""
    {"kind":"raise","side":"A","team":"A","kubb":"b9","n":1,"of":7,"turn":3,
     "pose":{"x":-0.4,"y":2.2,"angle":0.4,"standing":false},
     "ends":[{"which":1,"pose":{"x":-0.299,"y":2.243,"angle":0.4,"standing":true},"ok":true},
             {"which":2,"pose":{"x":-0.501,"y":2.157,"angle":0.4,"standing":true},"ok":false,"why":"THAT END IS BLOCKED"}],
     "choices":[{"which":1,"pose":{"x":-0.299,"y":2.243,"angle":0.4,"standing":true}}],
     "default":1,
     "others":[{"id":"b1","pose":{"x":-0.2,"y":2.45,"angle":0,"standing":true}},
               {"id":"b2","pose":{"x":-0.65,"y":2.0,"angle":1.2,"standing":false}},
               {"id":"b3","pose":{"x":-0.1,"y":1.95,"angle":0.2,"standing":true}},
               {"id":"b4","pose":{"x":-0.7,"y":2.5,"angle":0,"standing":true}},
               {"id":"b5","pose":{"x":-0.3,"y":1.75,"angle":2.1,"standing":false}},
               {"id":"b6","pose":{"x":0.15,"y":2.3,"angle":0,"standing":true}}],
     "king":{"x":0,"y":4,"angle":0,"standing":true}}
    """#

  /// A kubb lying along the sideline, its outer end out.
  static let sideline = #"""
    {"kind":"raise","side":"A","team":"A","kubb":"b9","n":1,"of":1,"turn":3,
     "pose":{"x":2.42,"y":1.4,"angle":0.1,"standing":false},
     "ends":[{"which":1,"pose":{"x":2.529,"y":1.411,"angle":0.1,"standing":true},"ok":false,"why":"THAT END IS OUT"},
             {"which":2,"pose":{"x":2.311,"y":1.389,"angle":0.1,"standing":true},"ok":true}],
     "choices":[{"which":2,"pose":{"x":2.311,"y":1.389,"angle":0.1,"standing":true}}],
     "default":1,
     "others":[],
     "king":{"x":0,"y":4,"angle":0,"standing":true}}
    """#
}
