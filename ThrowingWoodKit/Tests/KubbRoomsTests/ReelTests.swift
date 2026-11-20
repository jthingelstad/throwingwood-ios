import Foundation
import Testing

@testable import KubbRooms

/// The `reel` request (the web's docs/ROOMS.md section 12): one message on a socket of
/// its own, answered in every state the server's `reel()` gives
/// (`backend/rooms/core.mjs`, `tests/net/reels.test.mjs`).
@Suite @MainActor struct ReelTests {
  static let room = "abcdefgh23"

  /// A socket that answers the reel request with `reply` (`$ID` is the request's id).
  private func asking(_ reply: String, before: [String] = []) -> (RoomsClient.Factory, () -> [MockTransport]) {
    var made: [MockTransport] = []
    let factory: RoomsClient.Factory = { _ in
      let t = MockTransport()
      made.append(t)
      t.onSend = { m in
        guard m["t"]?.string == "reel" else { return }
        for text in before { t.push(text) }
        t.push(reply.replacingOccurrences(of: "$ID", with: String(m["id"]!.int!)))
      }
      return t
    }
    return (factory, { made })
  }

  private func ask(_ reply: String, before: [String] = []) async throws -> (ReelAnswer, [MockTransport]) {
    let (factory, made) = asking(reply, before: before)
    var timing = RoomsClient.Timing()
    timing.answer = .seconds(600)
    let answer = try await RoomsClient.reel(
      room: Self.room, url: URL(string: "ws://127.0.0.1:1")!, appVersion: "0.0-test",
      timing: timing, factory: factory)
    return (answer, made())
  }

  @Test func theRequestIsOneUnjoinedMessageAndTheSocketCloses() async throws {
    let (answer, sockets) = try await ask(
      #"{"t":"reel","id":$ID,"room":"abcdefgh23","v":4,"reel":{"state":"rendering","tag":"r1-0.7","at":1}}"#)
    #expect(answer == .rendering(v: 4, tag: "r1-0.7"))
    #expect(sockets.count == 1)
    let sent = sockets[0].sent
    #expect(sent.count == 1)
    #expect(sent[0].raw.text == #"{"t":"reel","id":1,"room":"abcdefgh23"}"#)
    #expect(sockets[0].closed)
  }

  @Test func doneCarriesTheSitePaths() async throws {
    let (answer, _) = try await ask(
      #"{"t":"reel","id":$ID,"room":"abcdefgh23","v":4,"reel":{"state":"done","tag":"r1-0.7","at":1,"tall":"/reels/abcdefgh23/4-r1-0.7/tall.mp4","wide":"/reels/abcdefgh23/4-r1-0.7/wide.mp4","edit":"/reels/abcdefgh23/4-r1-0.7/edit.json","seconds":36.5}}"#
    )
    guard case .done(let v, let tag, let files) = answer else {
      Issue.record("not done: \(answer)")
      return
    }
    #expect(v == 4 && tag == "r1-0.7")
    #expect(files.tall == "/reels/abcdefgh23/4-r1-0.7/tall.mp4")
    #expect(files.wide == "/reels/abcdefgh23/4-r1-0.7/wide.mp4")
    #expect(files.seconds == 36.5)
  }

  @Test(arguments: [
    (#""why":"render""#, ReelAnswer.ReelFailure.render),
    (#""why":"empty""#, .empty),
    ("", .timedOut),
    (#""why":"later""#, .other("later")),
  ])
  func failedIsFinalWithItsWhy(_ why: String, _ expected: ReelAnswer.ReelFailure) async throws {
    let fields = why.isEmpty ? "" : "," + why
    let (answer, _) = try await ask(
      #"{"t":"reel","id":$ID,"room":"abcdefgh23","v":4,"reel":{"state":"failed","tag":"r1-0.7","at":1"#
        + fields + "}}")
    #expect(answer == .failed(v: 4, tag: "r1-0.7", why: expected))
  }

  @Test(arguments: [
    ("unavailable", 0, ReelAnswer.ReelWhy.unavailable),
    ("replay", 0, .replay),
    ("engine", 3, .engine),
    ("busy", 4, .busy),
    ("newer", 4, .other("newer")),
  ])
  func noReelSaysWhy(_ why: String, _ v: Int, _ expected: ReelAnswer.ReelWhy) async throws {
    let (answer, _) = try await ask(
      #"{"t":"reel","id":$ID,"room":"abcdefgh23","v":"# + "\(v)" + #","reel":null,"why":""# + why
        + "\"}")
    #expect(answer == .none(v: v, why: expected))
  }

  @Test func theTwoErrorsAreAnswersAndOthersThrow() async throws {
    let (tooMany, _) = try await ask(
      #"{"t":"error","id":$ID,"code":"too-many","message":"A connection may start 3 reels."}"#)
    #expect(tooMany == .tooMany)
    let (failed, _) = try await ask(
      #"{"t":"error","id":$ID,"code":"failed","message":"The reel could not be started."}"#)
    #expect(failed == .notStarted)
    do {
      _ = try await ask(#"{"t":"error","id":$ID,"code":"throttled","message":"slow down"}"#)
      Issue.record("should throw")
    } catch let e as RoomError { #expect(e.code == "throttled") }
  }

  @Test func anotherMessageFirstIsSkipped() async throws {
    let (answer, _) = try await ask(
      #"{"t":"reel","id":$ID,"room":"abcdefgh23","v":4,"reel":{"state":"rendering","tag":"r1-0.7","at":1}}"#,
      before: [#"{"t":"pong"}"#, #"{"t":"reel","id":9,"room":"abcdefgh23","v":1,"reel":null,"why":"busy"}"#])
    #expect(answer == .rendering(v: 4, tag: "r1-0.7"))
  }

  @Test func onlyTheSitesReelPathsAreTaken() async throws {
    for (tall, wide) in [
      ("https://example.com/x.mp4", "/reels/abcdefgh23/4-r1-0.7/wide.mp4"),
      ("/reels/otherpitch2/4-r1-0.7/tall.mp4", "/reels/abcdefgh23/4-r1-0.7/wide.mp4"),
      ("/reels/abcdefgh23/../../index.html.mp4", "/reels/abcdefgh23/4-r1-0.7/wide.mp4"),
      ("/reels/abcdefgh23/4-r1-0.7/tall.mp4", "/reels/abcdefgh23/4-r1-0.7/edit.json"),
    ] {
      do {
        _ = try await ask(
          #"{"t":"reel","id":$ID,"room":"abcdefgh23","v":4,"reel":{"state":"done","tag":"r1-0.7","at":1,"tall":""#
            + tall + #"","wide":""# + wide + #""}}"#)
        Issue.record("took \(tall) \(wide)")
      } catch let e as RoomError { #expect(e.code == "bad-reel") }
    }
  }

  @Test func aBadCodeSendsNothing() async throws {
    var made = 0
    do {
      _ = try await RoomsClient.reel(
        room: "Not a code", url: URL(string: "ws://127.0.0.1:1")!, appVersion: "0",
        factory: { _ in
          made += 1
          return MockTransport()
        })
      Issue.record("should throw")
    } catch let e as RoomError { #expect(e.code == "bad-room") }
    #expect(made == 0)
  }

  @Test func anUnansweredRequestFailsAtTheDeadline() async throws {
    var timing = RoomsClient.Timing()
    timing.answer = .milliseconds(30)
    do {
      _ = try await RoomsClient.reel(
        room: Self.room, url: URL(string: "ws://127.0.0.1:1")!, appVersion: "0", timing: timing,
        factory: { _ in MockTransport() })
      Issue.record("should throw")
    } catch is RoomError {}
  }

  /// The read-only `replay` fetch (docs/ROOMS.md section 10), answered with `reply`.
  private func kept(_ reply: String) async throws -> (KeptReplay?, [MockTransport]) {
    var made: [MockTransport] = []
    let factory: RoomsClient.Factory = { _ in
      let t = MockTransport()
      made.append(t)
      t.onSend = { m in
        guard m["t"]?.string == "replay" else { return }
        t.push(#"{"t":"pong"}"#)
        t.push(reply)
      }
      return t
    }
    var timing = RoomsClient.Timing()
    timing.answer = .seconds(600)
    let k = try await RoomsClient.kept(
      room: Self.room, url: URL(string: "ws://127.0.0.1:1")!, appVersion: "0.0-test",
      timing: timing, factory: factory)
    return (k, made)
  }

  @Test func theKeptReplayIsReadWithoutStartingAnything() async throws {
    let (k, sockets) = try await kept(
      #"{"t":"replay","id":1,"room":"abcdefgh23","v":7,"at":1,"replay":{"v":1,"n":2,"setup":{},"log":[],"hash":"9f3a"}}"#
    )
    #expect(k == KeptReplay(v: 7, n: 2, hash: "9f3a"))
    #expect(sockets.count == 1 && sockets[0].closed)
    #expect(sockets[0].sent.map(\.raw.text) == [#"{"t":"replay","id":1,"room":"abcdefgh23"}"#])
    let (none, _) = try await kept(#"{"t":"replay","id":1,"room":"abcdefgh23","v":0,"at":null,"replay":null}"#)
    #expect(none == nil)
    do {
      _ = try await kept(#"{"t":"error","id":1,"code":"throttled","message":"slow down"}"#)
      Issue.record("should throw")
    } catch let e as RoomError { #expect(e.code == "throttled") }
  }

  @Test func aKeptReplayIsTheMatchByNumberAndHash() {
    let k = KeptReplay(v: 7, n: 2, hash: "a")
    #expect(k.isMatch(nil))
    #expect(k.isMatch(ReelMatch(n: 2, hash: "a")))
    #expect(k.isMatch(ReelMatch(n: 2, hash: nil)))
    #expect(KeptReplay(v: 7, n: 2, hash: nil).isMatch(ReelMatch(n: 2, hash: "a")))
    #expect(!k.isMatch(ReelMatch(n: 2, hash: "b")))
    #expect(!k.isMatch(ReelMatch(n: 1, hash: "a")))
    #expect(ReelAnswer.rendering(v: 7, tag: "t").version == 7)
    #expect(ReelAnswer.none(v: 0, why: .replay).version == nil)
    #expect(ReelAnswer.notStarted.version == nil)
  }

  @Test func aJoinedClientAsksOnASocketOfItsOwn() async throws {
    var sockets: [MockTransport] = []
    let room = try makeClient { _ in
      let t = MockTransport()
      sockets.append(t)
      t.onSend = { m in
        switch m["t"]?.string {
        case "join": t.joined()
        case "reel":
          t.push(
            #"{"t":"reel","id":1,"room":"abcdefghjk","v":2,"reel":{"state":"rendering","tag":"r1-0.7","at":1}}"#)
        default: break
        }
      }
      return t
    }
    defer { room.close() }
    room.connect()
    try await room.ready()
    let answer = try await room.reel()
    #expect(answer == .rendering(v: 2, tag: "r1-0.7"))
    #expect(sockets.count == 2)
    #expect(sockets[1].sent.map { $0["t"]?.string } == ["reel"])
    #expect(sockets[1].sent[0]["member"] == nil)
    #expect(sockets[1].closed && !sockets[0].closed)
  }
}
