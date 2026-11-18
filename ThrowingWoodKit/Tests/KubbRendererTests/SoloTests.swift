import Foundation
import KubbEngine
import Testing

@testable import KubbRenderer

@MainActor struct SoloTests {
  // CPU on both sides exercises the same on-screen clock, release and playback as a solo CPU turn.
  // The reference advances independently. It never receives an action or snapshot from the app.
  @Test func fullMatchAgreesAfterEveryRelease() throws {
    let setup =
      #"{"mode":"match","cpu":"both","seed":1001,"opening":"2-4-6","raising":"hand","start":{"year":2026,"month":11,"day":17,"hour":12,"min":0}}"#
    let app = try PitchSession(appVersion: "test")
    let ref = try Engine(appVersion: "test")
    try app.openMatch("new", json: setup, save: nil)
    _ = try ref.call("new", json: setup)
    var releases = 0
    for _ in 0..<40_000 {
      if app.need?.kind == "over" { break }
      try app.tick(0.05)
      let frame = try ref.call("frame", json: #"{"dt":0.05}"#)
      let released = frame.contains(#""action":{"#)
      try #require(app.playing == released)
      if released {
        releases += 1
        try #require(try app.engine.hash() == ref.hash(), "release \(releases)")
        try app.skipPlayback()
      }
    }
    try #require(app.need?.winner != nil)
    #expect(releases > 10)
    #expect(try app.engine.call("sheet") == ref.call("sheet"))
    print("solo controller \(releases)/\(releases) hashes, final \(try ref.hash())")
  }

  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  @Test func restoreDuringFlightCommitsExactlyOneThrow() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let save = MatchSave(file: folder.appending(path: "match.json"))
    let live = try PitchSession(appVersion: "test")
    try live.restore(fixture("computer"), save: save)
    for _ in 0..<200 where !live.playing { try live.tick(0.05) }
    try #require(live.playing)
    let text = try #require(try save.read())
    #expect(try live.engine.call("snapshot") == text)
    let restored = try PitchSession(appVersion: "test")
    try restored.restore(text, save: save)
    try live.skipPlayback()
    #expect(try live.engine.hash() == restored.engine.hash())
    #expect(try live.engine.call("need") == restored.engine.call("need"))
    for _ in 0..<200 where !live.playing {
      try live.tick(0.05)
      try restored.tick(0.05)
    }
    #expect(live.playing && restored.playing)
    #expect(try live.engine.hash() == restored.engine.hash())
  }

  @Test func raisingAndPunishmentUseProjectedLegalChoices() throws {
    let app = try PitchSession(appVersion: "test")
    let size = CGSize(width: 390, height: 844)
    try app.restore(fixture("raise"), save: nil)
    let end = try #require(app.need?.ends?.first { $0.ok == true })
    let old = try app.engine.hash()
    let point = try #require(
      app.scene.projection(size, app.camera).project(V3(end.pose.x, end.pose.y, 0)))
    try app.raise(at: point, size: size)
    #expect(try app.engine.hash() != old)
    try app.restore(fixture("punish"), save: nil)
    let cursor = try #require(app.cursor)
    let p = app.scene.projection(size, app.camera)
    let legal = try #require(p.project(cursor.point))
    let king = try #require(app.need?.keepOut?.first { $0.kind == "king" })
    let blocked = try #require(p.project(king.point))
    try app.movePunishment(to: blocked, size: size)
    #expect(app.placement?.ok == false)
    let before = try app.engine.hash()
    try app.placePunishment()
    #expect(try app.engine.hash() == before)
    try app.movePunishment(to: legal, size: size)
    #expect(app.placement?.ok == true)
    try app.placePunishment()
    #expect(try app.engine.hash() != before)
  }

  @Test func bothEdgeTargetsStayInTheAimAndPlanView() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    for size in [CGSize(width: 390, height: 844), CGSize(width: 440, height: 956)] {
      let screen = CGRect(origin: .zero, size: size)
      for x in [-2.0, 2.0] {
        let mark = V3(x, 8, 0)
        let tap = try #require(app.scene.projection(size, app.camera).project(mark))
        try app.target(tap, size: size, snap: true)
        for _ in 0..<2 {
          let p = app.scene.projection(size, app.camera)
          let circle = try #require(app.scene.marker)
          #expect(abs(circle.x - x) < 0.01)
          for world in [
            mark + V3(0, 0, 0.15), mark + V3(circle.r!, 0, 0), mark - V3(circle.r!, 0, 0),
          ] {
            #expect(try screen.contains(#require(p.project(world))))
          }
          try app.togglePlan()
          for _ in 0..<90 { try app.tick(1.0 / 60) }
        }
      }
    }
  }

  @Test func optionsAndLocalStart() throws {
    let app = try PitchSession(appVersion: "test")
    #expect(
      app.options.rows.map(\.id) == ["level", "surface", "opening", "raising", "wind", "set"])
    var choices = app.options.defaults
    choices["surface"] = "sand"
    try app.startSolo(name: "You", selections: choices, save: nil)
    #expect(app.scene.surface == .sand && app.handoff != nil)
    app.dismissHandoff()
    #expect(app.canAim)
    try app.togglePlan()
    try app.toggleWalk()
    for _ in 0..<60 { try app.tick(1.0 / 60) }
    #expect(app.walking && app.plan)
    let prior = try #require(app.scene.thrower)
    app.walk(drag: CGPoint(x: -68, y: 0))
    for _ in 0..<20 { try app.tick(1.0 / 60) }
    app.walk(drag: .zero)
    #expect(try #require(app.scene.thrower).x < prior.x)
    try app.adjustPlan(arc: true, step: 1)
    try app.adjustPlan(arc: false, step: 1)
    #expect(try app.sheet().done == false)
  }
}
