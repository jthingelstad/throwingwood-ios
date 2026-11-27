import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// RESIGN against the computer ends the match at once (the owner, 2026-11-27: "they should
/// not have to watch the computer play out its turn"): the engine takes a resignation only
/// on the side's own turn (session.lua `resignPending`), so the app makes what stands
/// between with no frames (`endResignation`), every action kept, and shows the winner card.
@MainActor struct ResignTests {
  private func folder() -> URL {
    URL.temporaryDirectory.appending(path: "resign-" + UUID().uuidString)
  }

  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  private func armPoints(_ d: DialState) throws -> [CGPoint] {
    let dt = 1.0 / 60
    let back = try #require(d.powerLo.flatMap { lo in d.powerHi.map { (lo + $0) / 2 } })
    let stop = try #require(d.releaseLo.flatMap { lo in d.releaseHi.map { (lo + $0) / 2 } })
    var a = -5.0
    var angles = [0.0, a]
    while a > -back {
      a = max(-back, a - 400 * dt)
      angles.append(a)
    }
    while a < stop {
      a = min(stop, a + 2400 * dt)
      angles.append(a)
    }
    return angles.map { a in CGPoint(x: sin(a * .pi / 180), y: cos(a * .pi / 180)) }
  }

  /// The person's throw on the dial, released: its recording starts playing.
  private func personThrows(_ app: PitchSession) throws {
    for p in try armPoints(app.dial) {
      app.sample(p)
      try app.tick(1.0 / 60)
    }
    app.sample(nil)
    try app.tick(1.0 / 60)
  }

  /// A solo match (the throw to go off), played by the person to the computer's first throw.
  private func atComputersTurn(_ save: MatchSave? = nil) throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "Mighty Maple", selections: app.options.withoutTogo, save: save)
    for _ in 0..<20000 {
      app.dismissHandoff()
      if app.need?.kind == "throw", app.need?.cpu == true, !app.playing, !app.raiseShowing { break }
      if app.playing {
        try app.skipPlayback()
      } else if app.canAim, app.need?.cpu != true {
        try personThrows(app)
      } else {
        try app.tick(0.05)
      }
    }
    try #require(app.need?.kind == "throw" && app.need?.cpu == true)
    return app
  }

  /// The kept match replayed from its finished file, action by action, to the end.
  private func replayed(_ save: MatchSave) throws -> (over: Bool, hash: String) {
    let done = try #require(save.finishedMatch())
    #expect(done.complete && done.winner == "B")
    let replay = try Engine(appVersion: "test")
    _ = try replay.call("replayLoad", json: done.replay.text)
    for _ in 0..<(done.entries.count + 2) { _ = try? replay.call("replayStep") }
    let over = try JSONNode.parse(replay.call("need"))["kind"]?.string == "over"
    return (over, try replay.hash())
  }

  /// What stands between a waiting resignation and the side's own turn, made on a second
  /// engine: this side's raises by the engine's advice, its punishment kubb on the engine's
  /// spot, the computer's throws by `cpuPlay`.
  private func playOut(_ reference: Engine) throws {
    for _ in 0..<60 {
      let n = try JSONNode.parse(reference.call("need"))
      switch n["kind"]?.string {
      case "raise": _ = try reference.call("apply", json: #"{"type":"raise"}"#)
      case "punish":
        let c = try #require(n["cursor"])
        let frame = n["frame"]?.string.map { #","frame":"\#($0)""# } ?? ""
        _ = try reference.call(
          "apply", json: #"{"type":"punish","x":\#(c["x"]!.raw.text),"y":\#(c["y"]!.raw.text)\#(frame)}"#)
      case "throw": _ = try reference.call("cpuPlay", json: #"{"recordings":false}"#)
      default: return
      }
    }
  }

  /// RESIGN while the computer's throw plays: the match is over at once, nothing more
  /// plays or sounds, the save is the resigned match and the kept trail replays to it.
  @Test func resigningDuringTheComputersThrowEndsAtOnce() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let app = try atComputersTurn(save)
    app.dismissHandoff()
    for _ in 0..<4000 where !app.playing { try app.tick(1.0 / 60) }
    try #require(app.playing && app.computerTurn)
    let before = try app.engine.call("snapshot")
    var cues = 0, cancelled = 0
    app.onFeedback = { _ in cues += 1 }
    app.cancelFeedback = { cancelled += 1 }
    try app.resign()
    #expect(app.need?.kind == "over" && app.need?.winner?.winner == "B")
    #expect(!app.playing && !app.raiseShowing && !app.computerTurn && app.result == nil && app.handoff == nil)
    #expect(cancelled >= 1)
    for _ in 0..<600 { try app.tick(1.0 / 60) }
    #expect(cues == 0, "\(cues) cues after the resignation")
    #expect(try save.read() == app.engine.call("snapshot"))
    let r = try replayed(save)
    #expect(try r.over && r.hash == app.engine.hash())
    // the same turn made on a second engine: the throw that was playing, then the
    // resignation waits while the computer's turn is made, then takes
    let reference = try Engine(appVersion: "test")
    _ = try reference.call("restore", json: before)
    _ = try reference.call("setControl", json: #"{"sides":["A"],"cpu":true}"#)
    _ = try reference.call("apply", json: #"{"type":"resign","side":"A"}"#)
    #expect(try JSONNode.parse(reference.call("need"))["resignPending"]?.string == "A")
    try playOut(reference)
    #expect(try JSONNode.parse(reference.call("need"))["kind"]?.string == "over")
    // the stamps differ (each action carries the device's clock), the match does not
    #expect(try JSONNode.parse(reference.call("need"))["text"]?.string == JSONNode.parse(app.engine.call("need"))["text"]?.string)
    // and it reopens resigned
    let again = try PitchSession(appVersion: "test")
    try again.restore(#require(try save.read()), save: save)
    #expect(again.need?.kind == "over" && again.need?.winner?.winner == "B")
  }

  /// RESIGN while the person's own throw plays (the engine takes it at once, on its own
  /// turn): the throw stops and the winner card shows, no rest of the throw first.
  @Test func resigningDuringTheOwnThrowEndsAtOnce() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    try personThrows(app)
    try #require(app.playing)
    var cues = 0
    app.onFeedback = { _ in cues += 1 }
    try app.resign()
    #expect(app.need?.kind == "over" && !app.playing && app.result == nil)
    for _ in 0..<300 { try app.tick(1.0 / 60) }
    #expect(cues == 0)
  }

  /// RESIGN while the person's raise is watched: the watched raise is cut, this side's
  /// raises and punishment kubbs go by the engine's advice and the computer's turn is made,
  /// then the winner card; the same actions as on a second engine, hash for hash.
  @Test func resigningDuringAWatchedRaiseEndsAtOnce() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    app.raiseAutomatically = true
    try app.tick(0.02)
    try #require(app.raiseShowing)
    try app.resign()
    #expect(app.need?.kind == "over" && !app.raiseShowing && !app.playing)
    let reference = try Engine(appVersion: "test")
    _ = try reference.call("restore", json: try fixture("raise-many"))
    _ = try reference.call("setControl", json: #"{"sides":["A"],"cpu":true}"#)
    _ = try reference.call("apply", json: #"{"type":"resign","side":"A"}"#)
    try playOut(reference)
    #expect(try JSONNode.parse(reference.call("need"))["text"]?.string == JSONNode.parse(app.engine.call("need"))["text"]?.string)
    #expect(try reference.hash() == app.engine.hash())
  }

  /// RESIGN at the throw to go: the engine holds it until the match has a turn, and only
  /// the person can throw their baton to go, so that baton is still theirs to throw; once
  /// it is out the match ends at once, without playing the batons out or the turn after.
  @Test func resigningAtTheThrowToGoEndsOnTheBaton() throws {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "Mighty Maple", selections: app.options.defaults, save: nil)
    try #require(app.need?.kind == "togo" && app.togoToThrow)
    app.dismissHandoff()
    try app.resign()
    #expect(app.need?.resignPending == "A" && app.canAim)
    for _ in 0..<6 where app.need?.kind == "togo" {
      app.dismissHandoff()
      try personThrows(app)
      try app.tick(1.0 / 60)
    }
    #expect(app.need?.kind == "over" && !app.playing && !app.raiseShowing)
  }

  /// A kept match closed while its resignation waited (a build before this one) ends on
  /// the first tick after it reopens.
  @Test func aWaitingResignationEndsOnTheNextTick() throws {
    let app = try atComputersTurn()
    _ = try app.engine.call("apply", json: #"{"type":"resign","side":"A"}"#)
    let snapshot = try app.engine.call("snapshot")
    let again = try PitchSession(appVersion: "test")
    try again.restore(snapshot, save: nil)
    #expect(again.need?.resignPending == "A")
    try again.tick(1.0 / 60)
    #expect(again.need?.kind == "over" && !again.playing)
  }
}
