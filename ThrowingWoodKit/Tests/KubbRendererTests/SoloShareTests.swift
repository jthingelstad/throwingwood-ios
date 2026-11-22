import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// Sharing the finished match against the computer from its winner card (SoloShare.swift,
/// docs/ONLINE.md "Sharing a match against the computer").
@Suite @MainActor struct SoloShareTests {
  private func folder() -> URL {
    URL.temporaryDirectory.appending(path: "share-" + UUID().uuidString)
  }

  private func finished(_ save: MatchSave, name: String) throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: name, selections: app.options.defaults, save: save)
    app.dismissHandoff()
    try app.resign()
    return app
  }

  // ---------- which match may be shared ----------

  @Test func theFinishedMatchOnTheCardMayBeShared() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let app = try finished(save, name: "Brave Birch")
    let m = try #require(app.shareableMatch(save: save))
    #expect(m.key == save.finishedMatch()?.finalHash)
    #expect(m.key == (try app.engine.hash()))
    #expect(m.name == "Brave Birch")
    #expect(m.source.actions.count == 1 && m.source.winner == "B" && m.source.now != nil)
    guard case .message(let text, let bytes) = try app.shareMessage(m.source, name: "Mighty Maple")
    else {
      Issue.record("refused")
      return
    }
    let g = try JSONNode.parse(text.text)["g"]!
    #expect(g["client"]?.string == "ios")
    #expect(g["engine"]?.string == app.engine.engineVersion)
    #expect(try JSONNode.parse(g["start"]!.string!)["opts"]?["teams"]?["A"]?["name"]?.string == "Mighty Maple")
    #expect(g["end"]?.raw.text == #"{"winner":"B","throws":0}"#)
    #expect(bytes == text.text.utf8.count)
    // nothing about the device: only the five fields the web sends
    #expect(g.members.map(\.key) == ["client", "engine", "start", "log", "end"])
  }

  /// A match shared in a scene sends it: its start carries the match's options,
  /// the scene among them, so a sealed pitch watches it in its own.
  @Test func aSharedMatchSendsItsScene() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let app = try PitchSession(appVersion: "test")
    var choices = app.options.defaults
    choices["scene"] = "night"
    try app.startSolo(name: "Brave Birch", selections: choices, save: save)
    app.dismissHandoff()
    try app.resign()
    let m = try #require(app.shareableMatch(save: save))
    guard case .message(let text, _) = try app.shareMessage(m.source, name: "Brave Birch") else {
      Issue.record("refused")
      return
    }
    let start = try JSONNode.parse(try JSONNode.parse(text.text)["g"]!["start"]!.string!)
    #expect(start["opts"]?["scene"]?.string == "night")
    // and the start alone restores to a pitch in it
    let watcher = try PitchSession(appVersion: "test")
    try watcher.restore(m.source.start, save: nil)
    #expect(watcher.scene.look == "night")
  }

  /// A match played under a name the game did not make (a typed one from before) starts
  /// the row from the device's name: a typed name never reaches the reel.
  @Test func aTypedNameNeverStartsTheRow() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let app = try finished(save, name: "Mighty Maple")
    #expect(try #require(app.shareableMatch(save: save, deviceName: "Lucky Larch")).name == "Mighty Maple")
    // a typed name given for the match is never used: the session plays under a rolled one
    let typed = try finished(MatchSave(file: dir.appending(path: "typed.json")), name: "Ada")
    let start = try JSONNode.parse(typed.engine.call("snapshot"))["opts"]?["teams"]?["A"]?["name"]?.string
    #expect(start != "Ada" && typed.names.valid(.player, start).ok)
  }

  @Test func practiceOnlineAndAMatchStillBeingPlayedHaveNoShare() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    // nothing finished yet
    let playing = try PitchSession(appVersion: "test")
    try playing.startSolo(name: "Brave Birch", selections: playing.options.defaults, save: save)
    #expect(playing.shareableMatch(save: save) == nil)
    // practice
    let practice = try PitchSession(appVersion: "test")
    try practice.practice()
    #expect(practice.shareableMatch(save: save) == nil)
    // a finished match, but the one on the screen is another
    _ = try finished(save, name: "Brave Birch")
    let other = try PitchSession(appVersion: "test")
    try other.startSolo(name: "Mighty Maple", selections: other.options.defaults, save: nil)
    other.dismissHandoff()
    try other.resign()
    #expect(other.shareableMatch(save: save) == nil)
    // an online board on its winner card
    let board = try finished(MatchSave(file: dir.appending(path: "other.json")), name: "Brave Birch")
    board.onlineAction = { _ in }
    #expect(board.shareableMatch(save: save) == nil)
  }

  // ---------- the card ----------

  final class Wire {
    var replies: [Result<ShareReply, Error>] = []
    var sent: [JSONText] = []
    var online = true
    var made: [String] = []
  }

  private func card(_ wire: Wire, name: String = "Brave Birch", made: ShareMade? = nil) throws -> SoloShare {
    SoloShare(
      key: "h",
      name: name, names: Names(engine: try Engine(appVersion: "test")),
      make: { name in
        wire.made.append(name)
        return made ?? .message(JSONText(#"{"t":"share","id":1,"g":{"name":"\#(name)"}}"#), bytes: 1)
      },
      hooks: .init(
        send: { text in
          wire.sent.append(text)
          return try (wire.replies.isEmpty ? .success(ShareReply(code: nil, v: 0, why: "busy")) : wire.replies.removeFirst()).get()
        },
        reachable: { wire.online }))
  }

  private func settled(_ share: SoloShare) async throws {
    for _ in 0..<2000 where share.state.phase == .sending { try await Task.sleep(for: .milliseconds(2)) }
  }

  /// The card's name is the name row's, a generated one; nothing goes before SHARE, and
  /// a name that does not pass (none can come from the row) is said once SHARE is pressed.
  @Test func nothingIsSentBeforeShareAndANameTheReelCannotTakeSaysWhy() async throws {
    let wire = Wire()
    let share = try card(wire, name: "Ada")
    #expect(share.view.form && share.say == nil && share.problem == .pick)
    share.send()
    #expect(share.say == "Pick a name for your side." && wire.made.isEmpty && share.sent == 0)
    // the row starts from a generated name in place of one that does not pass
    let row = share.row
    #expect(share.names.valid(.player, row.text).ok && share.name == row.text && share.problem == nil)
    row.shuffle()
    #expect(share.name == row.text && share.say == nil)
    #expect(wire.sent.isEmpty)
  }

  @Test func aCodeHandsOverToTheReelCard() async throws {
    let wire = Wire()
    wire.replies = [.success(ShareReply(code: "abcdefgh23", v: 1, why: nil))]
    let share = try card(wire)
    var codes: [String] = []
    share.onShared = { codes.append($0) }
    share.send()
    #expect(share.view.line == ShareWords.checking && share.view.bar)
    try await settled(share)
    #expect(codes == ["abcdefgh23"] && share.view.code == "abcdefgh23")
    #expect(wire.made == ["Brave Birch"] && wire.sent.count == 1)
  }

  @Test func offlineSendsNothingAndTriesAgainAsOftenAsPressed() async throws {
    let wire = Wire()
    wire.online = false
    let share = try card(wire)
    for _ in 0..<3 {
      share.send()
      #expect(share.view.text == ShareWords.offline && share.view.retry)
    }
    #expect(wire.sent.isEmpty && share.sent == 0 && wire.made.count == 1)
    wire.online = true
    wire.replies = [.failure(PitchError("closed"))]
    share.send()
    try await settled(share)
    #expect(share.view.text == ShareWords.offline && share.view.retry)
  }

  @Test func aFailedShareIsTriedOnceMoreWithTheSameMessage() async throws {
    let wire = Wire()
    wire.replies = [.failure(PitchError("failed")), .failure(PitchError("failed"))]
    let share = try card(wire)
    share.send()
    try await settled(share)
    #expect(share.view.text == ShareWords.failed && share.view.retry)
    share.set("Lucky Larch")  // the row is not on screen now; the message already made goes
    share.send()
    try await settled(share)
    #expect(share.view.text == ShareWords.notThisTime && !share.view.retry)
    #expect(wire.sent.count == 2 && wire.sent[0] == wire.sent[1] && wire.made == ["Brave Birch"])
    share.send()
    #expect(wire.sent.count == 2)
  }

  @Test func aRefusalKnownHereSendsNothing() async throws {
    let wire = Wire()
    let share = try card(wire, made: .refused(.tooLong))
    share.send()
    #expect(share.view.text == ShareWords.why(.tooLong) && !share.view.retry)
    share.open()
    #expect(share.state.phase == .refused)  // final
    #expect(wire.sent.isEmpty)
  }

  @Test func busyStartsOverWhenTheCardOpensAgain() async throws {
    let wire = Wire()
    wire.replies = [.success(ShareReply(code: nil, v: 0, why: "busy"))]
    let share = try card(wire)
    share.send()
    try await settled(share)
    #expect(share.view.text == ShareWords.why(.busy))
    share.open()
    #expect(share.view.form)
  }
}
