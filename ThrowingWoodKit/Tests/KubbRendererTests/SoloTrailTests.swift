import Foundation
import KubbEngine
import KubbRooms
import Testing

@testable import KubbRenderer

/// The solo match's replay trail on disk (SoloTrail.swift, docs/MATCH.md "The replay trail").
@MainActor struct SoloTrailTests {
  private static let setup =
    #"{"mode":"match","seed":1001,"first":"A","cpu":"B","raising":"hand","surface":"grass","opening":"2-4-6","wind":"off","set":"classic","teams":{"A":{"name":"Ada","players":[{"name":"Ada","level":"club"}]},"B":{"name":"Computer","players":[{"name":"Computer","level":"club"}]}},"start":{"year":2026,"month":11,"day":17,"hour":12,"min":0}}"#

  private func folder() -> URL {
    URL.temporaryDirectory.appending(path: "trail-" + UUID().uuidString)
  }

  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  /// The person's move as the app commits it: applied, then `committed`, then the view.
  private func person(_ app: PitchSession, _ json: String) throws {
    let r: PlacementCheck = try app.read("apply", json)
    try #require(r.ok, "refused \(json)")
    try app.committed(JSONText(json))
    try app.adopt(app.read("view"))
  }

  /// One decision of a solo match: the computer's throws through the display clock, the
  /// person's raises through `raise`, their throws planned by a second engine.
  private func step(_ app: PitchSession, planner: Engine) throws {
    let need = try #require(app.need)
    app.dismissHandoff()
    switch need.kind {
    case "throw" where need.cpu == true:
      for _ in 0..<4000 where !app.playing { try app.tick(0.05) }
      try #require(app.playing)
      try app.skipPlayback()
    case "throw":
      var snap =
        try JSONSerialization.jsonObject(with: Data(app.engine.call("snapshot").utf8))
        as! [String: Any]
      var opts = snap["opts"] as! [String: Any]
      opts["cpu"] = ["A", "B"]
      snap["opts"] = opts
      _ = try planner.call(
        "restore",
        json: String(decoding: try JSONSerialization.data(withJSONObject: snap), as: UTF8.self))
      var found: String?
      for _ in 0..<400 where found == nil {
        found = try JSONNode.parse(planner.call("frame", json: #"{"dt":0.1}"#))["action"]?.raw.text
      }
      try person(app, #require(found))
    case "raise":
      try #require(try app.raise())
    case "punish":
      let c = try #require(app.cursor)
      try person(app, #"{"type":"punish","x":\#(c.x),"y":\#(c.y)}"#)
    default:
      Issue.record("unexpected need \(need.kind)")
    }
  }

  // A whole match against the computer, closed and resumed from disk half way, then
  // played again from the kept trail by the engine's own replay to the same end.
  @Test func finishedMatchReplaysToTheSameEnd() async throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let planner = try Engine(appVersion: "test")
    var app = try PitchSession(appVersion: "test")
    try app.openMatch("new", json: Self.setup, save: save)
    try app.checkpoint()
    #expect(app.trailComplete)
    var decisions = 0, resumed = false, midBytes = 0
    while app.need?.kind != "over" && decisions < 3000 {
      try step(app, planner: planner)
      decisions += 1
      if decisions == 40 {
        // a cold launch: a new session from the save alone
        midBytes = try save.trailFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        app = try PitchSession(appVersion: "test")
        try app.restore(#require(try save.read()), save: save)
        #expect(app.trailComplete)
        resumed = true
      }
      await Task.yield()
    }
    try #require(resumed)
    let winner = try #require(app.need?.winner?.winner)
    let finalHash = try app.engine.hash()
    #expect(!FileManager.default.fileExists(atPath: save.trailFile.path()))

    let match = try #require(save.finishedMatch())
    #expect(match.complete && match.winner == winner)
    #expect(match.engine == app.engine.engineVersion)
    #expect(match.name == "Ada" && match.level == "club")
    #expect(match.log.count == match.entries.count && match.throwCount > 10)
    #expect(match.start == (try JSONNode.parse(match.replay)["start"]?.string))

    // the replay's own form: { start, log = [{ a }] }, no hashes
    let replay = try Engine(appVersion: "test")
    _ = try replay.call("replayLoad", json: match.replay.text)
    var steps = 0
    for _ in match.entries {
      let r = try JSONNode.parse(replay.call("replayStep"))
      try #require(r["ok"]?.bool == true, "step \(steps)")
      steps += 1
    }
    #expect(try JSONNode.parse(replay.call("replayInfo"))["done"]?.bool == true)
    #expect(steps == match.entries.count)
    let need = try JSONNode.parse(replay.call("need"))
    #expect(need["kind"]?.string == "over")
    #expect(need["winner"]?["winner"]?.string == winner)
    #expect(try replay.hash() == finalHash)

    // and with the kept hashes, every action lands on the hash the match had
    let checked = JS.object([
      ("start", .string(match.start)),
      ("log", .array(match.entries.map { JS.object([("a", .raw($0.action)), ("h", .string($0.hash))]) })),
    ])
    _ = try replay.call("replayLoad", json: checked.ascii)
    for _ in match.entries { _ = try replay.call("replayStep") }
    let info = try JSONNode.parse(replay.call("replayInfo"))
    #expect(info["differs"]?.bool == false && info["done"]?.bool == true)

    let bytes = try save.finishedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    print(
      "solo trail: \(match.entries.count) actions, \(match.throwCount) throws, finished \(bytes) bytes, trail after 40 decisions \(midBytes) bytes"
    )
  }

  @Test func appendIsAtomicAndReloads() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    try save.beginTrail(start: #"{"v":1}"#, hash: "h0", engine: "0.7.2", complete: true)
    for i in 1...3 { try save.appendTrail(JSONText(#"{"type":"raise","n":\#(i)}"#), hash: "h\(i)") }
    var read = try #require(save.readTrail())
    #expect(read.trail.entries.map(\.hash) == ["h1", "h2", "h3"] && read.trail.complete)
    // a kill mid-append leaves part of a line: it is not read, and resume cuts it off
    let handle = try FileHandle(forWritingTo: save.trailFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"a":{"type":"thr"#.utf8))
    try handle.close()
    read = try #require(save.readTrail())
    #expect(read.trail.entries.count == 3)
    #expect(save.resumeTrail(hash: "h3", engine: "0.7.2")?.entries.count == 3)
    try save.appendTrail(JSONText(#"{"type":"raise","n":4}"#), hash: "h4")
    #expect(save.readTrail()?.trail.entries.map(\.hash) == ["h1", "h2", "h3", "h4"])
    // an append the save never caught up with (killed between the two) is cut back
    #expect(save.resumeTrail(hash: "h3", engine: "0.7.2")?.entries.count == 3)
    #expect(save.readTrail()?.trail.entries.count == 3)
    // a different engine, or a hash it never had, does not line up
    #expect(save.resumeTrail(hash: "h3", engine: "0.8.0") == nil)
    #expect(save.resumeTrail(hash: "zz", engine: "0.7.2") == nil)
    // a broken line in the middle is a broken trail
    try Data("{\"v\":1}\nnot json\n{}\n".utf8).write(to: save.trailFile)
    #expect(save.readTrail() == nil)
  }

  /// One of the computer's throws, committed through the display clock.
  private func computerThrows(_ app: PitchSession) throws {
    app.dismissHandoff()
    for _ in 0..<4000 where !app.playing { try app.tick(0.05) }
    try #require(app.playing)
    try app.skipPlayback()
  }

  // A save with no trail (from a build before this one), an unreadable trail, or one from
  // another match: the match resumes exactly as before and is marked not shareable.
  @Test(arguments: ["missing", "corrupt", "other"]) func resumeWithoutItsTrail(_ how: String)
    throws
  {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let snapshot = try fixture("computer")
    try save.write(snapshot)
    switch how {
    case "corrupt": try Data("\u{0}garbage\n{".utf8).write(to: save.trailFile)
    case "other":
      try save.beginTrail(start: fixture("aim"), hash: "0badf00d", engine: "0.7.2", complete: true)
    default: break
    }
    let app = try PitchSession(appVersion: "test")
    try app.restore(snapshot, save: save)
    let plain = try PitchSession(appVersion: "test")
    try plain.restore(snapshot, save: nil)
    #expect(try app.engine.hash() == plain.engine.hash())
    #expect(!app.trailComplete)
    // an unrelated trail names nothing: the save plays on the newest, not on 0.7
    #expect(app.engine.minor == Engine.newest)
    try computerThrows(app)
    try computerThrows(plain)
    #expect(try app.engine.hash() == plain.engine.hash())
    #expect(try save.read() == app.engine.call("snapshot"))
    // the trail from here on is kept, lines up on the next resume, and stays incomplete
    let kept = try #require(save.readTrail()?.trail)
    #expect(!kept.complete && kept.start == snapshot && kept.entries.count == 1)
    #expect(Engine.majorMinor(kept.engine) == Engine.newest)
    let again = try PitchSession(appVersion: "test")
    try again.restore(#require(try save.read()), save: save)
    #expect(!again.trailComplete && save.readTrail()?.trail.entries.count == 1)
  }

  /// A kept match resumes on the engine its trail names (a match begun on 0.7 by an
  /// earlier build plays on as it was), that engine's Lua state made only then; a new
  /// match and practice go back to the newest.
  @Test(.enabled(if: Engine.carried.count > 1)) func aKeptMatchResumesOnItsOwnEngine() throws {
    let older = Engine.carried[1]
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let first = try PitchSession(appVersion: "test")
    try first.useEngine(minor: older)
    try first.openMatch("new", json: Self.setup, save: save)
    try first.checkpoint()
    let planner = try Engine(minor: older, appVersion: "test")
    for _ in 0..<6 { try step(first, planner: planner) }
    #expect(Engine.majorMinor(save.readTrail()?.trail.engine) == older)
    let hash = try first.engine.hash()

    let again = try PitchSession(appVersion: "test")
    #expect(again.loadedEngines == [Engine.newest])
    try again.restore(#require(try save.read()), save: save)
    #expect(again.engine.minor == older)
    #expect(Set(again.loadedEngines) == Set([Engine.newest, older]))
    #expect(try again.engine.hash() == hash && again.trailKept)
    // the same snapshot named by its replay's engine, and with nothing to name it
    let shown = try PitchSession(appVersion: "test")
    try shown.restore(#require(try save.read()), save: nil, engine: older + ".9")
    #expect(shown.engine.minor == older)
    try shown.restore(#require(try save.read()), save: nil, engine: "0.6.0")
    #expect(shown.engine.minor == Engine.newest)

    try again.practice()
    #expect(again.engine.minor == Engine.newest)
    var choices = again.options.defaults
    choices["level"] = "pro"
    try again.startSolo(name: "Bo", selections: choices, save: save)
    #expect(again.engine.minor == Engine.newest)
    #expect(Engine.majorMinor(save.readTrail()?.trail.engine) == Engine.newest)
  }

  /// A match finished on an older carried engine and reopened on its winner card: the
  /// trail has become the finished-match file, which names the engine, so the save is
  /// restored on it and the match may still be shared (a review finding on PR #30).
  @Test(.enabled(if: Engine.carried.count > 1)) func aFinishedMatchReopensOnItsOwnEngine() throws {
    let older = Engine.carried[1]
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let first = try PitchSession(appVersion: "test")
    try first.useEngine(minor: older)
    try first.openMatch("new", json: Self.setup, save: save)
    try first.checkpoint()
    first.dismissHandoff()
    try first.resign()
    #expect(first.need?.kind == "over")
    #expect(save.readTrail() == nil)
    #expect(Engine.majorMinor(save.finishedMatch()?.engine) == older)

    let again = try PitchSession(appVersion: "test")
    try again.restore(#require(try save.read()), save: save)
    again.dismissHandoff()
    #expect(again.engine.minor == older)
    #expect(again.need?.kind == "over")
    let m = try #require(again.shareableMatch(save: save))
    guard case .message = try again.shareMessage(m.source, name: "Alder") else {
      Issue.record("refused")
      return
    }
    #expect(try again.sheet().text == first.sheet().text)

    // a finished file of another match names nothing for this save
    let other = MatchSave(file: dir.appending(path: "other.json"))
    let next = try PitchSession(appVersion: "test")
    try next.openMatch("new", json: Self.setup.replacingOccurrences(of: "1001", with: "1002"), save: nil)
    try other.write(next.engine.call("snapshot"))
    try FileManager.default.copyItem(at: save.finishedFile, to: other.finishedFile)
    let shown = try PitchSession(appVersion: "test")
    try shown.restore(#require(try other.read()), save: other)
    #expect(shown.engine.minor == Engine.newest)
  }

  private func startSolo(_ save: MatchSave, name: String) throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    var choices = app.options.defaults
    choices["level"] = "pro"
    try app.startSolo(name: name, selections: choices, save: save)
    return app
  }

  // The finished match outlives Home, a relaunch and a new match in progress; it is
  // replaced only when that one ends.
  @Test func finishedMatchSurvivesUntilTheNextOneEnds() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    #expect(save.finishedMatch() == nil)
    let first = try startSolo(save, name: "Ada")
    first.dismissHandoff()
    try first.resign()
    let one = try #require(save.finishedMatch())
    #expect(one.complete && one.winner == "B" && one.throwCount == 0 && one.entries.count == 1)
    #expect(one.name == "Ada" && one.level == "pro")
    // the resignation replays too
    let replay = try Engine(appVersion: "test")
    _ = try replay.call("replayLoad", json: one.replay.text)
    _ = try replay.call("replayStep")
    #expect(try JSONNode.parse(replay.call("need"))["kind"]?.string == "over")
    #expect(try replay.hash() == first.engine.hash())

    // the app closed on the winner card and opened twice: the save is the finished one
    for _ in 0..<2 {
      let reopened = try PitchSession(appVersion: "test")
      try reopened.restore(#require(try save.read()), save: save)
      #expect(reopened.need?.kind == "over")
      #expect(!FileManager.default.fileExists(atPath: save.trailFile.path()))
    }
    #expect(save.finishedMatch()?.start == one.start && save.finishedMatch()?.complete == true)
    try save.clear()  // Home after the win
    let relaunched = MatchSave(file: save.file)
    #expect(relaunched.finishedMatch()?.start == one.start)

    let second = try startSolo(relaunched, name: "Bo")
    #expect(relaunched.finishedMatch()?.start == one.start)
    second.dismissHandoff()
    try second.resign()
    let two = try #require(relaunched.finishedMatch())
    #expect(two.start != one.start && two.name == "Bo")
  }

  // Killed after the last save and before the finished match was written: the next
  // launch finds the trail lined up with a finished save and keeps it then.
  @Test func finishedOnTheNextLaunchAfterAKill() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let app = try startSolo(save, name: "Ada")
    let head = try Data(contentsOf: save.trailFile)
    app.dismissHandoff()
    try app.resign()
    let done = try #require(save.finishedMatch())
    try FileManager.default.removeItem(at: save.finishedFile)
    let line = JS.object([("a", .raw(done.entries[0].action)), ("h", .string(done.entries[0].hash))])
    try (head + Data((line.ascii + "\n").utf8)).write(to: save.trailFile)
    let reopened = try PitchSession(appVersion: "test")
    try reopened.restore(#require(try save.read()), save: save)
    let kept = try #require(save.finishedMatch())
    #expect(kept.complete && kept.start == done.start && kept.winner == "B")
    #expect(!FileManager.default.fileExists(atPath: save.trailFile.path()))
  }

  // Practice and online play keep nothing on disk.
  @Test func practiceAndOnlineWriteNothing() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let app = try PitchSession(appVersion: "test")
    try app.practice()
    try app.committed(JSONText(#"{"type":"surface","surface":"sand"}"#))
    #expect(!FileManager.default.fileExists(atPath: dir.path()))
    // an online board: every action goes to the room
    let board = try PitchSession(appVersion: "test")
    var sent: [JSONText] = []
    try board.restore(fixture("aim"), save: nil)
    board.onlineAction = { sent.append($0) }
    board.save = save
    try board.committed(JSONText(#"{"type":"resign","side":"A"}"#))
    #expect(sent.count == 1)
    #expect(!FileManager.default.fileExists(atPath: dir.path()))
  }
}
