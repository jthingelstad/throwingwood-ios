import Foundation
import Testing

@testable import KubbRooms

@MainActor final class MemoryID: MemberIDStore {
  var id: String?
  init(_ id: String? = "Native_Member") { self.id = id }
  func load() -> String? { id }
  func save(_ id: String) { self.id = id }
}
@MainActor final class MockTransport: RoomsTransport {
  var sent: [JSONNode] = []
  var frames: [String] = []
  var onSend: ((JSONNode) -> Void)?
  var pending: CheckedContinuation<String, Error>?
  var buffer: [Result<String, Error>] = []
  var closed = false
  var parts = Frames.Reassembler()
  func send(_ text: String) async throws {
    frames.append(text)
    if let text = parts.accept(text) {
      let node = try JSONNode.parse(text)
      sent.append(node)
      onSend?(node)
    }
  }
  func receive() async throws -> String {
    if !buffer.isEmpty { return try buffer.removeFirst().get() }
    if closed { throw RoomError("closed") }
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
    if pending != nil { deliver(.failure(RoomError("closed"))) }
  }
  func joined(v: Int = 0, doc: String = "null", sid: String? = nil, by: String = "Native_Member") {
    push(
      "{\"t\":\"joined\",\"room\":\"abcdefghjk\",\"host\":\"Native_Member\",\"rev\":1,\"members\":[],\"v\":\(v),\"doc\":\(doc),\"by\":\(ASCIIJSON.quote(by)),\"sid\":\(sid.map(ASCIIJSON.quote) ?? "null"),\"limits\":{\"frame\":30000}}"
    )
  }
}

@MainActor func eventually(_ test: () -> Bool) async throws {
  for _ in 0..<3000 {
    if test() { return }
    try await Task.sleep(for: .milliseconds(2))
  }
  throw RoomError("test-timeout")
}
@MainActor func makeClient(
  _ factory: @escaping RoomsClient.Factory, store: MemoryID = MemoryID(),
  timing: RoomsClient.Timing? = nil
) throws -> RoomsClient {
  var fast = RoomsClient.Timing()
  fast.retry = .milliseconds(2)
  fast.retryMax = .milliseconds(5)
  return try RoomsClient(
    url: URL(string: "ws://127.0.0.1:1")!, room: "abcdefghjk", engineVersion: "0.3.0",
    appVersion: "0.0-test", store: store, timing: timing ?? fast, factory: factory)
}

@Suite @MainActor struct RoomsClientTests {
  @Test func identityHeadersMeAndReconnect() async throws {
    let store = MemoryID(nil)
    var requests: [URLRequest] = []
    var transports: [MockTransport] = []
    let room = try makeClient(
      { request in
        requests.append(request)
        let t = MockTransport()
        transports.append(t)
        t.onSend = { msg in if msg["t"]?.string == "join" { t.joined() } }
        return t
      }, store: store)
    defer { room.close() }
    room.connect()
    try await room.ready()
    #expect(store.id == room.you)
    #expect(requests[0].value(forHTTPHeaderField: "Origin") == "https://app.throwingwood.com")
    #expect(requests[0].value(forHTTPHeaderField: "User-Agent") == "ThrowingWood/0.0-test (ios)")
    room.setMe([("name", .string("Å 🎯")), ("level", .string("pro"))])
    room.setMe([("level", .null)])
    try await eventually { transports[0].sent.count == 3 }
    transports[0].deliver(.failure(RoomError("network")))
    try await eventually { transports.count == 2 && room.status == .open }
    let join = transports[1].sent[0]
    #expect(join["member"]?.string == room.you)
    #expect(join["me"]?["name"]?.string == "Å 🎯")
    #expect(join["me"]?["level"] == nil)
    #expect(join["me"]?["engine"]?.string == "0.3.0")
  }

  @Test func revisionsAndVersionsNeverGoBack() async throws {
    let t = MockTransport()
    let room = try makeClient { _ in t }
    defer { room.close() }
    room.connect()
    t.joined()
    try await room.ready()
    t.push(#"{"t":"member","rev":9,"member":{"id":"Person_01","joined":1,"connected":true}}"#)
    t.push(#"{"t":"left","rev":8,"id":"Person_01"}"#)
    t.push(#"{"t":"host","rev":8,"host":"Person_01"}"#)
    t.push(#"{"t":"host","rev":7,"host":"Other_01"}"#)
    t.push(#"{"t":"doc","v":5,"doc":{"n":5,"snap":"{\"x\":3.0}"},"by":"Person_01"}"#)
    t.push(#"{"t":"no","id":900,"v":2,"doc":null}"#)
    try await eventually { room.version == 5 }
    #expect(room.members.count == 1)
    #expect(room.host == "Person_01")
    #expect(try JSONNode.parse(room.document)["snap"]?.string == #"{"x":3.0}"#)
    t.push(#"{"t":"left","rev":10,"id":"Person_01"}"#)
    t.push(#"{"t":"member","rev":9,"member":{"id":"Person_01"}}"#)
    try await eventually { room.members.isEmpty }
    #expect(room.members.isEmpty)
  }

  @Test func serializedReducersRetryOnNoAndPreserveRawChunks() async throws {
    let t = MockTransport()
    let room = try makeClient { _ in t }
    defer { room.close() }
    room.connect()
    t.joined()
    try await room.ready()
    var sets = 0
    var calls = 0
    t.onSend = { m in
      if m["t"]?.string == "set" {
        sets += 1
        if sets == 1 {
          t.push("{\"t\":\"no\",\"id\":\(m["id"]!.int!),\"v\":1,\"doc\":{\"n\":9}}")
        } else {
          t.push("{\"t\":\"ok\",\"id\":\(m["id"]!.int!),\"v\":\(m["base"]!.int!+1)}")
        }
      }
    }
    let big = String(repeating: "x", count: 70_000)
    let a = Task {
      try await room.update { doc in
        calls += 1
        let n = (try JSONNode.parse(doc)["n"]?.int ?? 0) + 1
        return JSONText("{\"n\":\(n),\"raw\":3.0,\"blob\":\(ASCIIJSON.quote(big))}")
      }
    }
    let b = Task { try await room.update { _ in JSONText(#"{"n":11}"#) } }
    _ = try await a.value
    _ = try await b.value
    #expect(calls == 2)
    #expect(sets == 3)
    #expect(room.version == 3)
    let written = t.sent.filter { $0["t"]?.string == "set" }
    #expect(written[1]["doc"]?["raw"]?.raw.text == "3.0")
    #expect(t.frames.allSatisfy { $0.utf8.count <= 30_000 })
    #expect(written[1]["doc"]?["n"]?.int == 10)
    #expect(written[2]["base"]?.int == 2)
  }

  @Test(arguments: ["landed", "retry", "uncertain"])
  func unansweredSetsAreSettledByRejoin(_ outcome: String) async throws {
    var sockets: [MockTransport] = []
    let room = try makeClient { _ in
      let t = MockTransport()
      sockets.append(t)
      let index = sockets.count
      t.onSend = { m in
        if m["t"]?.string == "join" {
          if index == 1 {
            t.joined()
          } else if outcome == "retry" {
            t.joined()
          } else {
            t.joined(v: 1, doc: "{\"n\":1}", sid: outcome == "landed" ? "1" : "999")
          }
        }
        if m["t"]?.string == "set" {
          if index == 1 {
            t.deliver(.failure(RoomError("network")))
          } else {
            t.push("{\"t\":\"ok\",\"id\":\(m["id"]!.int!),\"v\":1}")
          }
        }
      }
      return t
    }
    defer { room.close() }
    room.connect()
    try await room.ready()
    var runs = 0
    do {
      _ = try await room.update { _ in
        runs += 1
        return JSONText(#"{"n":1}"#)
      }
      #expect(outcome != "uncertain")
    } catch let error as RoomError { #expect(error.code == "uncertain" && outcome == "uncertain") }
    #expect(runs == (outcome == "retry" ? 2 : 1))
  }

  @Test func fatalErrorsAndCorrelatedReplies() async throws {
    let t = MockTransport()
    let room = try makeClient { _ in t }
    defer { room.close() }
    room.connect()
    t.joined()
    try await room.ready()
    t.onSend = { m in
      if m["t"]?.string == "game" { t.push("{\"t\":\"recorded\",\"id\":\(m["id"]!.int!)}") }
      if m["t"]?.string == "report" {
        t.push(
          "{\"t\":\"error\",\"id\":\(m["id"]!.int!),\"re\":\"report\",\"code\":\"unavailable\"}")
      }
    }
    #expect(try await room.request("game")["t"]?.string == "recorded")
    do {
      _ = try await room.request("report")
      Issue.record("should fail")
    } catch let e as RoomError { #expect(e.code == "unavailable") }
    t.push(#"{"t":"error","code":"replaced","message":"new socket"}"#)
    try await eventually { room.status == .replaced }
    room.connect()
    #expect(room.status == .replaced)
  }
  @Test func answerTimeoutReconnectsAndUsesTaggedRecordHelpers() async throws {
    var sockets: [MockTransport] = []
    var timing = RoomsClient.Timing()
    timing.answer = .seconds(3)
    timing.retry = .milliseconds(2)
    let room = try makeClient(
      { _ in
        let t = MockTransport()
        sockets.append(t)
        let index = sockets.count
        t.onSend = { m in
          switch m["t"]?.string {
          case "join":
            if index == 1 { t.joined() } else { t.joined(v: 1, doc: "{}", sid: "1") }
          case "game", "report":
            let type = m["t"]!.string!
            let payload = m[type == "game" ? "g" : "r"]!
            #expect(payload["client"]?.string == "ios")
            #expect(payload["engine"]?.string == "0.3.0")
            t.push(
              "{\"t\":\"\(type == "game" ? "recorded" : "reported")\",\"id\":\(m["id"]!.int!)}")
          default: break  // the first set is deliberately never answered
          }
        }
        return t
      }, timing: timing)
    defer { room.close() }
    room.connect()
    try await room.ready()
    _ = try await room.update { _ in JSONText("{}") }
    #expect(sockets.count == 2)
    #expect(
      try await room.recordGame(JSONText(#"{"client":"web","engine":"9.0","start":"-"}"#))["t"]?
        .string == "recorded")
    #expect(try await room.report(JSONText(#"{"happened":"test"}"#))["t"]?.string == "reported")
    // An authoritative join also clears a previous incarnation's document.
    room.receive(#"{"t":"joined","host":"Native_Member","rev":1,"members":[],"v":0,"doc":null}"#)
    #expect(room.version == 0 && room.document == .null)
  }

}
