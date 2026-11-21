import Foundation
import Testing

@testable import KubbPitch

/// A fake API: answers each request with `body` and `status`, keeping the requests.
final class FakeAPI: @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [URLRequest] = []
  var body: String
  var status: Int
  var failure: URLError?
  init(_ body: String, status: Int = 200) {
    self.body = body
    self.status = status
  }
  var requests: [URLRequest] { lock.withLock { _requests } }
  /// The JSON body of request `i`.
  func sent(_ i: Int = 0) throws -> JSONNode {
    try JSONNode.parse(String(decoding: requests[i].httpBody ?? Data(), as: UTF8.self))
  }
  var api: PitchAPI {
    PitchAPI(base: URL(string: "http://127.0.0.1:8798/api/")!, appVersion: "0.0-test") { [self] request in
      lock.withLock { _requests.append(request) }
      if let failure { throw failure }
      return (
        Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    }
  }
}

/// The `reel` and `replay` calls (the web's backend/api/API.md), answered in every
/// state the API gives.
@Suite struct ReelTests {
  static let pitch = "abcdefgh23"

  func ask(_ reply: String, status: Int = 200, v: Int? = nil) async throws -> (ReelAnswer, FakeAPI) {
    let fake = FakeAPI(reply, status: status)
    return (try await fake.api.reel(pitch: Self.pitch, v: v), fake)
  }

  @Test func theRequestIsOnePostToReel() async throws {
    let (answer, fake) = try await ask(
      #"{"pitch":"abcdefgh23","v":4,"reel":{"state":"rendering","tag":"r1-0.7","at":1}}"#)
    #expect(answer == .rendering(v: 4, tag: "r1-0.7"))
    let request = try #require(fake.requests.first)
    #expect(request.httpMethod == "POST" && request.url?.absoluteString == "http://127.0.0.1:8798/api/reel")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ThrowingWood/0.0-test (ios)")
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    #expect(try fake.sent().raw.text == #"{"pitch":"abcdefgh23"}"#)
  }

  @Test func theRequestNamesTheKeptVersionOrLeavesItOut() async throws {
    let (answer, fake) = try await ask(#"{"pitch":"abcdefgh23","v":9,"reel":null,"why":"moved"}"#, v: 7)
    #expect(answer == .none(v: 9, why: .moved))
    #expect(try fake.sent().raw.text == #"{"pitch":"abcdefgh23","v":7}"#)
    // never zero or less: refused here before anything is sent
    for bad in [0, -1] {
      let f = FakeAPI("{}")
      await #expect(throws: PitchError("bad-message")) { _ = try await f.api.reel(pitch: Self.pitch, v: bad) }
      #expect(f.requests.isEmpty)
    }
  }

  @Test func doneCarriesTheSitePaths() async throws {
    let (answer, _) = try await ask(
      #"{"pitch":"abcdefgh23","v":4,"reel":{"state":"done","tag":"r1-0.7","at":1,"tall":"/reels/abcdefgh23/4-r1-0.7/tall.mp4","wide":"/reels/abcdefgh23/4-r1-0.7/wide.mp4","edit":"/reels/abcdefgh23/4-r1-0.7/edit.json","seconds":36.5}}"#
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
      #"{"pitch":"abcdefgh23","v":4,"reel":{"state":"failed","tag":"r1-0.7","at":1"# + fields + "}}")
    #expect(answer == .failed(v: 4, tag: "r1-0.7", why: expected))
  }

  @Test(arguments: [
    ("unavailable", 0, ReelAnswer.ReelWhy.unavailable),
    ("replay", 0, .replay),
    ("engine", 3, .engine),
    ("busy", 4, .busy),
    ("moved", 9, .moved),
    ("newer", 4, .other("newer")),
  ])
  func noReelSaysWhy(_ why: String, _ v: Int, _ expected: ReelAnswer.ReelWhy) async throws {
    let (answer, _) = try await ask(#"{"pitch":"abcdefgh23","v":\#(v),"reel":null,"why":"\#(why)"}"#)
    #expect(answer == .none(v: v, why: expected))
  }

  @Test func aFailedCallIsNotStartedAndOtherRefusalsThrow() async throws {
    let (failed, _) = try await ask(#"{"error":"failed","message":"The reel could not be started."}"#, status: 500)
    #expect(failed == .notStarted)
    await #expect(throws: PitchError("unavailable", "No renderer.")) {
      _ = try await ask(#"{"error":"unavailable","message":"No renderer."}"#, status: 503)
    }
    // no body at all: the status says it
    await #expect(throws: PitchError("unavailable")) { _ = try await ask("", status: 503) }
    // another pitch's answer is not this one's
    await #expect(throws: PitchError("unexpected-reply")) {
      _ = try await ask(#"{"pitch":"otherpitch2","v":4,"reel":null,"why":"busy"}"#)
    }
  }

  @Test func aCallThatCouldNotBeMadeIsClosedOrTimeout() async throws {
    let fake = FakeAPI("")
    fake.failure = URLError(.notConnectedToInternet)
    await #expect(throws: PitchError("closed")) { _ = try await fake.api.reel(pitch: Self.pitch) }
    fake.failure = URLError(.timedOut)
    await #expect(throws: PitchError("timeout")) { _ = try await fake.api.reel(pitch: Self.pitch) }
  }

  @Test func onlyTheSitesReelPathsAreTaken() async throws {
    for (tall, wide) in [
      ("https://example.com/x.mp4", "/reels/abcdefgh23/4-r1-0.7/wide.mp4"),
      ("/reels/otherpitch2/4-r1-0.7/tall.mp4", "/reels/abcdefgh23/4-r1-0.7/wide.mp4"),
      ("/reels/abcdefgh23/../../index.html.mp4", "/reels/abcdefgh23/4-r1-0.7/wide.mp4"),
      ("/reels/abcdefgh23/4-r1-0.7/tall.mp4", "/reels/abcdefgh23/4-r1-0.7/edit.json"),
    ] {
      await #expect(throws: PitchError("bad-reel")) {
        _ = try await ask(
          #"{"pitch":"abcdefgh23","v":4,"reel":{"state":"done","tag":"r1-0.7","at":1,"tall":"\#(tall)","wide":"\#(wide)"}}"#)
      }
    }
  }

  @Test func aBadCodeSendsNothing() async throws {
    let fake = FakeAPI("{}")
    await #expect(throws: PitchError("bad-pitch")) { _ = try await fake.api.reel(pitch: "Not a code") }
    await #expect(throws: PitchError("bad-pitch")) { _ = try await fake.api.replay(pitch: "Not a code") }
    #expect(fake.requests.isEmpty)
  }

  /// The read-only `replay` call (API.md "replay"), which starts nothing.
  @Test func theKeptReplayIsReadWithoutStartingAnything() async throws {
    let fake = FakeAPI(
      #"{"pitch":"abcdefgh23","v":1764000000000,"at":1764000000000,"sealed":false,"replay":{"v":1,"n":2,"setup":{},"log":[],"hash":"9f3a","h0":"11aa","snap":"{}"}}"#
    )
    let k = try #require(try await fake.api.replay(pitch: Self.pitch))
    #expect(k.v == 1_764_000_000_000 && k.n == 2 && k.hash == "9f3a" && k.snap == "{}" && !k.sealed)
    let request = try #require(fake.requests.first)
    #expect(request.httpMethod ?? "GET" == "GET" && request.httpBody == nil)
    #expect(request.url?.absoluteString == "http://127.0.0.1:8798/api/replay?pitch=abcdefgh23")
    // the engine the match was played on, and a sealed pitch
    fake.body =
      #"{"pitch":"abcdefgh23","v":7,"at":7,"sealed":true,"replay":{"v":1,"n":2,"setup":{},"log":[],"hash":"9f3a","engine":"0.7.4"}}"#
    let named = try await fake.api.replay(pitch: Self.pitch)
    #expect(named?.engine == "0.7.4" && named?.sealed == true)
    fake.body = #"{"pitch":"abcdefgh23","v":0,"at":null,"sealed":false,"replay":null}"#
    #expect(try await fake.api.replay(pitch: Self.pitch) == nil)
    fake.body = #"{"error":"bad-pitch","message":"That is not a pitch code."}"#
    fake.status = 400
    await #expect(throws: PitchError.self) { _ = try await fake.api.replay(pitch: Self.pitch) }
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

  /// A report (`POST report { r }`) tagged as this app's, with the match's engine.
  @Test func aReportIsTaggedAndAnsweredOk() async throws {
    let fake = FakeAPI(#"{"ok":true}"#)
    try await fake.api.report(JSONText(#"{"kind":"feedback","text":"Hi","client":"web"}"#), engine: "0.9.0")
    let r = try #require(try fake.sent()["r"])
    #expect(r.members.map(\.key) == ["kind", "text", "client", "engine"])
    #expect(r["client"]?.string == "ios" && r["engine"]?.string == "0.9.0")
    #expect(fake.requests[0].url?.absoluteString == "http://127.0.0.1:8798/api/report")
    // a report naming its own engine keeps it; one with none and no default has none
    try await fake.api.report(JSONText(#"{"kind":"throw","engine":"0.8.2"}"#), engine: "0.9.0")
    #expect(try fake.sent(1)["r"]?["engine"]?.string == "0.8.2")
    try await fake.api.report(JSONText(#"{"kind":"throw"}"#))
    #expect(try fake.sent(2)["r"]?["engine"] == nil)
    fake.body = #"{"error":"too-big","message":"Too big."}"#
    fake.status = 413
    await #expect(throws: PitchError("too-big", "Too big.")) { try await fake.api.report(JSONText("{}")) }
  }
}
