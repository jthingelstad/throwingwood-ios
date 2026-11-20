import Foundation
import KubbEngine
import KubbRooms
import Testing

@testable import KubbRenderer

@MainActor struct SoloTests {
  // CPU on both sides exercises the same on-screen clock, release and playback as a solo CPU turn.
  // The reference advances independently. It never receives an action or snapshot from the app.
  @Test func fullMatchAgreesAfterEveryRelease() async throws {
    let setup =
      #"{"mode":"match","cpu":"both","seed":1001,"opening":"2-4-6","raising":"hand","start":{"year":2026,"month":11,"day":17,"hour":12,"min":0}}"#
    let app = try PitchSession(appVersion: "test")
    let ref = try Engine(appVersion: "test")
    try app.openMatch("new", json: setup, save: nil)
    _ = try ref.call("new", json: setup)
    var cues: [PitchHaptic] = []
    app.onFeedback = { if let h = $0.haptic { cues.append(h) } }
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
        // Let the other main-actor Kit tests service their transports between throws.
        await Task.yield()
      }
    }
    try #require(app.need?.winner != nil)
    #expect(!cues.contains(.band) && !cues.contains(.release))
    #expect(cues.filter { $0 == .win }.count == (app.need?.winner?.winner == "A" ? 1 : 0))
    #expect(releases > 10)
    #expect(try app.engine.call("sheet") == ref.call("sheet"))
    print("solo controller \(releases)/\(releases) hashes, final \(try ref.hash())")
  }

  // A SLOW flick is coached on the player's next throw, however many of the
  // computer's come between: its throws carry no verdicts and change nothing.
  @Test func computerThrowsKeepThePlayersSlowFlick() throws {
    let setup =
      #"{"mode":"match","cpu":"both","seed":1001,"opening":"2-4-6","raising":"hand","start":{"year":2026,"month":11,"day":17,"hour":12,"min":0}}"#
    let app = try PitchSession(appVersion: "test")
    try app.openMatch("new", json: setup, save: nil)
    app.coachSlow = true
    var played = 0
    for _ in 0..<40_000 where played < 2 {
      let was = app.playing
      try app.tick(0.05)
      if was && !app.playing { played += 1 }
    }
    try #require(played == 2)
    #expect(app.coachSlow)
  }

  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  @Test func matchFeedbackUsesTheDisplayedCardAndPlayingSide() throws {
    let aim = try fixture("aim"), over = try fixture("over")
    for membership in ["winner", "loser", "watcher"] {
      let board = try PitchSession(appVersion: "test")
      var heard: [PitchHaptic] = []
      board.onFeedback = { if let pulse = $0.haptic { heard.append(pulse) } }
      try board.restore(aim, save: nil)
      try board.adopt(board.read("view"))
      #expect(heard == [.handoff])
      let final: ViewOutput = try board.read("restore", over)
      let won = try #require(final.need.winner?.winner)
      board.playerSide = {
        switch membership {
        case "winner": won
        case "loser": won == "A" ? "B" : "A"
        default: nil
        }
      }
      try board.adopt(final)
      try board.adopt(final)
      #expect(heard == (membership == "winner" ? [.handoff, .win] : [.handoff]))
    }
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
    let capture = try live.captureReport(size: CGSize(width: 390, height: 844), scale: 3)
    let report = try JSONNode.parse(capture.message(happened: "Stopped", should: "", selected: ["king"]))
    let replay = try Engine(appVersion: "test")
    _ = try replay.call("restore", json: #require(report["snapshots"]?["before"]?.string))
    _ = try replay.call("apply", json: #require(report["last"]?.raw.text))
    #expect(try replay.hash() == live.engine.hash())
    #expect(report["mode"]?.string == "solo")
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
    let i = try #require(app.raisePick(at: point, size: size))
    #expect(app.need?.ends?[i].which == end.which)
    try app.raiseTap(i)
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

  @Test func idlePlanChangesRefreshTheDialBeforeAnotherTouch() throws {
    struct View: Decodable { let dial: DialState }
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    let initial = app.dial
    try app.adjustPlan(arc: true, step: 1)
    let view: View = try app.read("view")
    #expect(app.dial != initial)
    #expect(app.dial == view.dial)
  }

  @Test func resignationOnOpeningTurnShowsWinnerImmediately() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    try app.resign()
    #expect(app.handoff == nil && app.need?.winner != nil)
    #expect(try app.sheet().done)
  }

  /// A scene this build does not draw is carried untouched and drawn as the day: a
  /// match started in one keeps it through a restore. The set-up offers the three.
  @Test func aMatchsSceneIsCarriedUntouched() throws {
    let start = try Engine(appVersion: "test")
    _ = try start.call(
      "new",
      json:
        #"{"mode":"match","cpu":"B","seed":5,"scene":"dusk","computer":"pro","teams":{"A":{"name":"You","players":[{"name":"You"}]},"B":{"name":"Computer","players":[{"name":"Computer"}]}},"start":{"year":2026,"month":11,"day":17,"hour":12,"min":0}}"#
    )
    let snapshot = try start.call("snapshot")
    #expect(snapshot.contains(#""scene":"dusk""#))
    let app = try PitchSession(appVersion: "test")
    try app.restore(snapshot, save: nil)
    #expect(try app.engine.call("snapshot") == snapshot)
    #expect(try JSONNode.parse(app.engine.call("view"))["scene"]?.string == "dusk")
    #expect(app.scene.look == "dusk" && SceneID.shown(app.scene.look) == "day")
    #expect(app.options.takesScene && app.options.rows.last?.id == "scene")
    #expect(app.options.defaults["scene"] == "day")
  }

  /// A solo match's scene is the set-up's choice: in the match's options, its view and
  /// its snapshot (so a reopened or shared match shows it too).
  @Test func aSoloMatchKeepsItsScene() throws {
    let app = try PitchSession(appVersion: "test")
    var choices = app.options.defaults
    choices["scene"] = "neon"
    try app.startSolo(name: "You", selections: choices, save: nil)
    #expect(app.scene.look == "neon")
    let snapshot = try app.engine.call("snapshot")
    #expect(snapshot.contains(#""scene":"neon""#))
    let again = try PitchSession(appVersion: "test")
    try again.restore(snapshot, save: nil)
    #expect(again.scene.look == "neon")
    choices["scene"] = "day"
    try app.startSolo(name: "You", selections: choices, save: nil)
    #expect(SceneID.shown(app.scene.look) == "day")
  }

  @Test func optionsAndLocalStart() throws {
    let app = try PitchSession(appVersion: "test")
    #expect(
      app.options.rows.map(\.id) == ["computer", "surface", "opening", "raising", "wind", "set", "scene"])
    var choices = app.options.defaults
    choices["surface"] = "sand"
    try app.startSolo(name: "You", selections: choices, save: nil)
    #expect(app.scene.surface == .sand && app.handoff != nil)
    app.dismissHandoff()
    #expect(app.canAim)
    try app.togglePlan()
    for _ in 0..<60 { try app.tick(1.0 / 60) }
    #expect(app.plan)
    let prior = try #require(app.scene.thrower)
    // STAND: a press on the plate's left quarter puts the thrower there
    app.stand(fx: 0.25, fy: 0.5, phase: .down)
    try app.tick(1.0 / 60)
    app.stand(fx: 0.25, fy: 0.5, phase: .up)
    #expect(try #require(app.scene.thrower).x < prior.x)
    try app.adjustPlan(arc: true, step: 1)
    try app.adjustPlan(arc: false, step: 1)
    #expect(try app.sheet().done == false)
  }
}
