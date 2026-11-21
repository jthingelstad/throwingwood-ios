import Foundation
import Testing

@testable import KubbPitch

@MainActor final class MemoryID: MemberIDStore {
  var id: String?
  init(_ id: String? = "Native_Member") { self.id = id }
  func load() -> String? { id }
  func save(_ id: String) { self.id = id }
}

/// A socket a test feeds by hand (frames in, frames out), for exact wire checks.
@MainActor final class MockTransport: PitchTransport {
  var sent: [JSONNode] = []
  var frames: [String] = []
  var onSend: ((JSONNode) -> Void)?
  var pending: CheckedContinuation<String, Error>?
  var buffer: [Result<String, Error>] = []
  var closed = false
  func send(_ text: String) async throws {
    frames.append(text)
    guard text != "ping" else { return }
    let node = try JSONNode.parse(text)
    sent.append(node)
    onSend?(node)
  }
  func receive() async throws -> String {
    if !buffer.isEmpty { return try buffer.removeFirst().get() }
    if closed { throw PitchError("closed") }
    return try await withCheckedThrowingContinuation { pending = $0 }
  }
  func push(_ text: String) { deliver(.success(text)) }
  func deliver(_ value: Result<String, Error>) {
    if let p = pending {
      pending = nil
      p.resume(with: value)
    } else {
      buffer.append(value)
    }
  }
  func close() {
    closed = true
    if pending != nil { deliver(.failure(PitchError("closed"))) }
  }
}

@MainActor func eventually(_ test: () -> Bool) async throws {
  for _ in 0..<3000 {
    if test() { return }
    try await Task.sleep(for: .milliseconds(2))
  }
  throw PitchError("test-timeout")
}

/// Fast retries; answers never time out (beside the other suites the main actor can be
/// held for seconds, and a timer firing then would drop a socket the test relies on).
func fastTiming() -> PitchClient.Timing {
  var t = PitchClient.Timing()
  t.firstRetry = .milliseconds(2)
  t.retry = .milliseconds(2)
  t.retryMax = .milliseconds(5)
  t.answer = .seconds(600)
  t.ping = .seconds(600)
  return t
}

@MainActor func makeClient(
  _ factory: @escaping PitchClient.Factory, store: any MemberIDStore = MemoryID(),
  observing: Bool = false, timing: PitchClient.Timing = fastTiming(), code: String = "abcdefghjk"
) throws -> PitchClient {
  try PitchClient(
    url: URL(string: "ws://127.0.0.1:1")!, pitch: code, appVersion: "0.0-test", store: store,
    observing: observing, timing: timing, factory: factory)
}

@Suite @MainActor struct PitchClientTests {
  @Test func theSocketIsThePitchsAddressWithNoOrigin() async throws {
    let fake = FakePitch()
    let store = MemoryID(nil)
    let pitch = try makeClient(fake.factory, store: store)
    defer { pitch.close() }
    pitch.setMe([("name", .string("Å 🎯")), ("level", .string("pro"))])
    pitch.connect()
    try await pitch.ready()
    #expect(store.id == pitch.you)
    let request = fake.links[0].request
    #expect(request.url?.absoluteString == "ws://127.0.0.1:1/ws?pitch=abcdefghjk")
    #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ThrowingWood/0.0-test (ios)")
    let join = fake.links[0].sent[0]
    #expect(join["t"]?.string == "join" && join["member"]?.string == pitch.you)
    #expect(join["role"]?.string == "player" && join["me"]?["name"]?.string == "Å 🎯")
    #expect(join["v"] == nil && join["n"] == nil && join["create"] == nil)
    #expect(pitch.isHost && pitch.status == .open)
    // the base may carry a path; the socket is always <base>/ws
    #expect(
      PitchClient.socketURL(URL(string: "wss://example.test/pitch")!, pitch: "abcdefghjk").absoluteString
        == "wss://example.test/pitch/ws?pitch=abcdefghjk")
  }

  @Test func aCodeThatIsNotAPitchCodeIsRefusedBeforeAnySocket() {
    #expect(throws: PitchError("bad-pitch")) { _ = try makeClient({ _ in MockTransport() }, code: "ABC") }
  }

  @Test func aReconnectSaysTheVersionItHoldsAndTheMeItHas() async throws {
    let fake = FakePitch()
    let pitch = try makeClient(fake.factory)
    defer { pitch.close() }
    pitch.connect()
    try await pitch.ready()
    _ = try await pitch.update { _ in JSONText(#"{"teams":{}}"#) }
    pitch.setMe([("level", .string("club"))])
    pitch.setMe([("level", .null), ("name", .string("Tester"))])
    try await eventually { fake.members[pitch.you]?.me.count == 1 }
    fake.links[0].drop()
    try await eventually { fake.links.count == 2 && pitch.status == .open }
    let join = fake.links[1].sent[0]
    #expect(join["v"]?.int == 1)
    #expect(join["me"]?["name"]?.string == "Tester" && join["me"]?["level"] == nil)
    // the pitch did not send the document it already has, and the client kept it
    #expect(fake.links[1].got("joined")[0]["doc"] == nil)
    #expect(pitch.document == JSONText(#"{"teams":{}}"#) && pitch.version == 1)
  }

  @Test func lobbyWritesAreCompareAndSetAndRunAgainOnNo() async throws {
    let fake = FakePitch()
    let a = try makeClient(fake.factory, store: MemoryID("Member_A1"))
    let b = try makeClient(fake.factory, store: MemoryID("Member_B1"))
    defer {
      a.close()
      b.close()
    }
    a.connect()
    b.connect()
    try await a.ready()
    try await b.ready()
    func add(_ key: String) -> PitchClient.Reducer {
      { doc in
        let node = try JSONNode.parse(doc)
        let old = node.kind == .object ? node.members.map { ($0.key, JS.raw($0.value.raw)) } : []
        return JS.object(old + [(key, .bool(true))]).json
      }
    }
    // b's socket holds its write back until a's has landed: b's base is then stale
    fake.links[1].swallow = true
    let bw = Task { try await b.update(add("b")) }
    try await eventually { fake.links[1].sent("set").count == 1 }
    fake.links[1].swallow = false
    _ = try await a.update(add("a"))
    try await eventually { b.version == 1 }
    // b's first set never reached the pitch: it is still waiting; send it again by dropping
    fake.links[1].drop()
    _ = try await bw.value
    #expect(fake.v == 2)
    let doc = try JSONNode.parse(fake.doc)
    #expect(doc["a"]?.bool == true && doc["b"]?.bool == true)
    #expect(a.document == fake.doc && b.document == fake.doc)
    // a write the pitch refuses (`no`) runs the reducer again on the newer document
    let c = try makeClient(fake.factory, store: MemoryID("Member_C1"))
    defer { c.close() }
    c.connect()
    try await c.ready()
    fake.links.last!.swallow = true
    let cw = Task { try await c.update(add("c")) }
    try await eventually { fake.links.last!.sent("set").count == 1 }
    _ = try await a.update(add("a2"))
    try await eventually { c.version == 3 }
    fake.links.last!.swallow = false
    // resend by hand the stale write as the pitch would have seen it: answered `no`
    let stale = fake.links.last!.sent("set")[0]
    fake.handle(fake.links.last!, stale.raw.text)
    _ = try await cw.value
    #expect(try fake.v == 4 && (JSONNode.parse(fake.doc))["c"]?.bool == true)
  }

  @Test(arguments: [true, false]) func aWriteWhoseAnswerWasLostIsSettledByTheNextJoin(landed: Bool) async throws {
    let fake = FakePitch()
    let pitch = try makeClient(fake.factory)
    defer { pitch.close() }
    pitch.connect()
    try await pitch.ready()
    var runs = 0
    if landed { fake.links[0].deaf = true } else { fake.links[0].swallow = true }
    let write = Task {
      try await pitch.update { _ in
        runs += 1
        return JSONText(#"{"n":1}"#)
      }
    }
    try await eventually { fake.links[0].sent("set").count == 1 }
    fake.links[0].drop()
    #expect(try await write.value == JSONText(#"{"n":1}"#))
    // landed: the join shows version base+1 by this member, so it is not written again
    #expect(runs == (landed ? 1 : 2))
    #expect(fake.v == 1 && pitch.version == 1)
  }

  @Test func aGapInTheStampIsAResyncAndNothingPastItCounts() async throws {
    let t = MockTransport()
    let pitch = try makeClient { _ in t }
    defer { pitch.close() }
    var docs: [Int] = []
    pitch.observe { if case .document(let v, _, _) = $0 { docs.append(v) } }
    pitch.connect()
    try await eventually { t.sent.count == 1 }
    t.push(#"{"t":"joined","pitch":"abcdefghjk","you":"Native_Member","role":"player","host":"Native_Member","s":5,"ts":1,"members":[],"v":0,"by":null,"doc":null,"match":null}"#)
    try await pitch.ready()
    t.push(#"{"t":"doc","v":1,"by":"Other_Member","doc":{"a":1},"s":6,"ts":2}"#)
    t.push(#"{"t":"doc","v":3,"by":"Other_Member","doc":{"a":3},"s":8,"ts":3}"#)  // 7 missed
    t.push(#"{"t":"doc","v":4,"by":"Other_Member","doc":{"a":4},"s":9,"ts":4}"#)
    try await eventually { t.sent.contains { $0["t"]?.string == "resync" } }
    #expect(docs == [1] && pitch.s == 6 && pitch.gaps == 1)
    #expect(t.sent.filter { $0["t"]?.string == "resync" }.count == 1)
    t.push(#"{"t":"state","s":9,"ts":5,"host":"Native_Member","members":[],"v":4,"by":"Other_Member","doc":{"a":4},"match":null}"#)
    try await eventually { pitch.s == 9 }
    #expect(pitch.version == 4 && pitch.document == JSONText(#"{"a":4}"#))
    // an old frame (s not past the one held) is ignored
    t.push(#"{"t":"doc","v":2,"by":"Other_Member","doc":{"a":2},"s":7,"ts":6}"#)
    t.push(#"{"t":"host","host":"Other_Member","s":10,"ts":7}"#)
    try await eventually { pitch.host == "Other_Member" }
    #expect(pitch.version == 4 && pitch.s == 10)
  }

  @Test func framesBeforeJoinedAreIgnored() async throws {
    let t = MockTransport()
    let pitch = try makeClient { _ in t }
    defer { pitch.close() }
    pitch.connect()
    try await eventually { t.sent.count == 1 }
    t.push(#"{"t":"doc","v":9,"by":"Other_Member","doc":{"x":1},"s":1,"ts":1}"#)
    t.push(#"{"t":"joined","pitch":"abcdefghjk","you":"Native_Member","role":"player","host":"Native_Member","s":0,"ts":1,"members":[],"v":0,"by":null,"doc":null,"match":null}"#)
    try await pitch.ready()
    #expect(pitch.version == 0 && pitch.s == 0)
  }

  /// Actions are sent at once and never waited on; one whose answer was lost is sent
  /// again, as it was, after the reconnect, and the pitch answers it `dup` without
  /// storing it twice.
  @Test func actionsAreRetriedByIdAfterAReconnectAndStoredOnce() async throws {
    let fake = FakePitch()
    let pitch = try makeClient(fake.factory)
    defer { pitch.close() }
    pitch.connect()
    try await pitch.ready()
    fake.match = .init(n: 1, meta: JSONText("{}"), h0: "h0", at: 0, h: "h0", snap: "s0")
    fake.links[0].deaf = true
    pitch.act(id: "act-one-1", n: 1, seq: 1, a: JSONText(#"{"type":"x"}"#), h: "h1", snap: "s1", over: false)
    pitch.act(id: "act-two-2", n: 1, seq: 2, a: JSONText(#"{"type":"y"}"#), h: "h2", snap: "s2", over: true)
    try await eventually { fake.match?.acts.count == 2 }
    #expect(pitch.outbox.map(\.id) == ["act-one-1", "act-two-2"])
    let first = fake.links[0].sent("act")[0]
    #expect(first["c"]?.string == "ios" && first["over"] == nil)
    #expect(fake.links[0].sent("act")[1]["over"]?.bool == true)
    fake.links[0].drop()
    try await eventually { pitch.outbox.isEmpty }
    let oks = fake.links[1].got("ok")
    #expect(oks.count == 2 && oks.allSatisfy { $0["dup"]?.bool == true })
    #expect(fake.match?.acts.map(\.id) == ["act-one-1", "act-two-2"] && fake.match?.over == true)
    // the same frames, byte for byte
    #expect(fake.links[1].sent("act").map(\.raw) == fake.links[0].sent("act").map(\.raw))
    // a dup ok does not move s
    #expect(pitch.s == fake.s)
  }

  @Test func anActionTheClientMakesWhileAwayIsSentAfterTheJoin() async throws {
    let fake = FakePitch()
    fake.fresh = false
    fake.match = .init(n: 1, meta: JSONText("{}"), h0: "h0", at: 0, h: "h0", snap: "s0")
    let pitch = try makeClient(fake.factory)
    defer { pitch.close() }
    pitch.act(id: "early-1", n: 1, seq: 1, a: JSONText("{}"), h: "h1", snap: "s1", over: false)
    pitch.connect()
    try await eventually { pitch.outbox.isEmpty }
    #expect(fake.links[0].sent.map { $0["t"]?.string } == ["join", "act"])
    #expect(fake.match?.acts.count == 1)
  }

  @Test func aStartGoesAsOneMessageAndIsAnsweredWithItsMatchNumber() async throws {
    let fake = FakePitch()
    let pitch = try makeClient(fake.factory)
    defer { pitch.close() }
    pitch.connect()
    try await pitch.ready()
    let landed = try await pitch.start(
      base: 0, doc: JSONText(#"{"started":true}"#), n: 1, h: "h0", snap: "s0", meta: JSONText(#"{"v":1}"#))
    #expect(landed && pitch.version == 1 && pitch.by == pitch.you)
    let start = fake.links[0].sent("start")[0]
    #expect(start.members.map(\.key) == ["t", "id", "base", "doc", "n", "h", "snap", "meta"])
    #expect(fake.match?.n == 1 && fake.match?.meta == JSONText(#"{"v":1}"#))
    // a START on a stale base is answered `no`: false, and the lobby is the pitch's
    #expect(try await pitch.start(base: 0, doc: JSONText("{}"), n: 2, h: "h", snap: "s", meta: JSONText("{}")) == false)
    // the wrong match number is the pitch's error
    await #expect(throws: PitchError.self) {
      _ = try await pitch.start(base: 1, doc: JSONText("{}"), n: 5, h: "h", snap: "s", meta: JSONText("{}"))
    }
  }

  @Test func theKeepAliveIsTheLiteralPingAndASilentSocketIsDropped() async throws {
    let fake = FakePitch()
    var timing = fastTiming()
    timing.ping = .milliseconds(30)
    timing.pong = .milliseconds(400)  // roomy: a busy test host must not drop a live socket
    let pitch = try makeClient(fake.factory, timing: timing)
    defer { pitch.close() }
    pitch.connect()
    try await pitch.ready()
    // answered: the socket stays
    try await eventually { fake.links[0].sent("ping").count >= 2 }
    #expect(fake.links.count == 1)
    // not answered: gone, and the client joins again on a new socket
    let count = fake.links.count
    fake.links.last!.noPong = true
    try await eventually { fake.links.count > count && pitch.status == .open }
  }

  @Test func theSameMemberSomewhereElseReplacesThisOne() async throws {
    let fake = FakePitch()
    let a = try makeClient(fake.factory)
    let b = try makeClient(fake.factory)
    defer {
      a.close()
      b.close()
    }
    a.connect()
    try await a.ready()
    b.connect()
    try await b.ready()
    try await eventually { a.status == .replaced }
    await #expect(throws: PitchError.self) { try await a.ready() }
    #expect(fake.links.count == 2)
  }

  @Test func aJoinErrorClosesTheClient() async throws {
    let fake = FakePitch()
    let watcher = try makeClient(fake.factory, observing: true)
    defer { watcher.close() }
    var errors: [String] = []
    watcher.observe {
      if case .message(let m) = $0, m["t"]?.string == "error" { errors.append(m["code"]?.string ?? "") }
    }
    watcher.connect()
    await #expect(throws: PitchError.self) { try await watcher.ready() }
    #expect(errors == ["no-pitch"] && watcher.status == .closed)
    #expect(fake.links[0].sent[0]["role"]?.string == "observer")
  }

  @Test func castsGoOnlyWhenJoinedAndAllMarksTheOnesObserversMustSee() async throws {
    let fake = FakePitch()
    let pitch = try makeClient(fake.factory)
    defer { pitch.close() }
    #expect(!pitch.cast(JSONText(#"{"t":"aim"}"#)))
    pitch.connect()
    try await pitch.ready()
    #expect(pitch.cast(JSONText(#"{"t":"aim"}"#)))
    #expect(pitch.cast(JSONText(#"{"t":"shout","w":"TOK!"}"#), all: true))
    #expect(pitch.list(JSONText(#"{"seats":2,"state":"waiting"}"#)))
    try await eventually { fake.links[0].sent("cast").count == 2 && fake.open != nil }
    let casts = fake.links[0].sent("cast")
    #expect(casts[0]["all"] == nil && casts[1]["all"]?.bool == true)
    #expect(fake.open == JSONText(#"{"seats":2,"state":"waiting"}"#))
  }

  @Test func leaveSaysSoThenCloses() async throws {
    let fake = FakePitch()
    let pitch = try makeClient(fake.factory)
    pitch.connect()
    try await pitch.ready()
    await pitch.leave()
    #expect(fake.links[0].sent.last?["t"]?.string == "leave")
    #expect(pitch.status == .closed && fake.members.isEmpty)
  }

  /// The web's pitch-client.js tune: the numbers both clients keep.
  @Test func theTimingIsTheWebs() {
    let t = PitchClient.Timing()
    #expect(t.firstRetry == .milliseconds(300) && t.retry == .seconds(1) && t.retryMax == .seconds(10))
    #expect(t.ping == .seconds(20) && t.pong == .seconds(10) && t.answer == .seconds(10))
    #expect(PitchClient.final == ["full", "no-pitch", "bad-member", "bad-role", "already-joined", "bad-message"])
  }

  /// A refused action takes every later pending one with it: each follows the refused one.
  @Test func aRefusalDropsThatActionAndEveryLaterOne() async throws {
    var sockets: [MockTransport] = []
    let pitch = try makeClient({ _ in
      let t = MockTransport()
      sockets.append(t)
      return t
    })
    defer { pitch.close() }
    pitch.connect()
    try await eventually { sockets.count == 1 && !sockets[0].sent.isEmpty }
    sockets[0].push(#"{"t":"joined","pitch":"abcdefghjk","you":"Native_Member","role":"player","host":"Native_Member","s":1,"ts":1,"members":[],"limits":{},"v":0,"by":null,"doc":null,"match":null}"#)
    try await pitch.ready()
    for i in 1...3 {
      pitch.act(id: "act-\(i)", n: 1, seq: i, a: JSONText("{}"), h: "h\(i)", snap: "s", over: false)
    }
    try await eventually { pitch.outbox.count == 3 }
    sockets[0].push(#"{"t":"refused","id":"act-2","n":1,"seq":2,"why":"seq","head":{"n":1,"seq":0,"h":"h0"}}"#)
    try await eventually { pitch.outbox.map(\.id) == ["act-1"] }
  }

  /// A join refused for now (not in the web's FINAL list) is tried again; one refused for
  /// good closes the client.
  @Test func aJoinRefusedForNowIsTriedAgain() async throws {
    var sockets: [MockTransport] = []
    let pitch = try makeClient({ _ in
      let t = MockTransport()
      sockets.append(t)
      return t
    })
    defer { pitch.close() }
    pitch.connect()
    try await eventually { sockets.count == 1 && !sockets[0].sent.isEmpty }
    sockets[0].push(#"{"t":"error","re":"join","code":"busy","message":"Busy."}"#)
    try await eventually { sockets.count == 2 && !sockets[1].sent.isEmpty }
    #expect(pitch.status == .connecting)
    sockets[1].push(#"{"t":"error","re":"join","code":"full","message":"Full."}"#)
    try await eventually { pitch.status == .closed }
    try await Task.sleep(for: .milliseconds(30))
    #expect(sockets.count == 2)
  }

  /// The device came online or the app became active: a reconnect waiting out its
  /// backoff goes at once, and an open socket is checked with a ping.
  @Test func retryNowSkipsTheBackoffOrPingsAnOpenSocket() async throws {
    var sockets: [MockTransport] = []
    var slow = fastTiming()
    slow.firstRetry = .seconds(600)
    slow.retry = .seconds(600)
    let pitch = try makeClient(
      { _ in
        let t = MockTransport()
        sockets.append(t)
        return t
      }, timing: slow)
    defer { pitch.close() }
    pitch.connect()
    try await eventually { sockets.count == 1 && !sockets[0].sent.isEmpty }
    let joined = #"{"t":"joined","pitch":"abcdefghjk","you":"Native_Member","role":"player","host":"Native_Member","s":1,"ts":1,"members":[],"limits":{},"v":0,"by":null,"doc":null,"match":null}"#
    sockets[0].push(joined)
    try await pitch.ready()
    pitch.retryNow()
    try await eventually { sockets[0].frames.last == "ping" }
    sockets[0].close()
    try await eventually { pitch.status == .reconnecting }
    try await Task.sleep(for: .milliseconds(20))
    #expect(sockets.count == 1)  // waiting out a long backoff
    pitch.retryNow()
    try await eventually { sockets.count == 2 }
  }
}
