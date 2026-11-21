import Foundation
import Testing

@testable import KubbPitch

/// The wire against PROTOCOL.md's own examples (`Fixtures/protocol-examples.json`): each
/// message this client sends has the example's fields in the example's order, and each
/// pitch frame in the table is read as the protocol says.
@Suite @MainActor struct ProtocolTests {
  let examples: JSONNode = {
    let url = Bundle.module.url(forResource: "Fixtures/protocol-examples", withExtension: "json")!
    return try! JSONNode.parse(String(contentsOf: url, encoding: .utf8))
  }()
  func keys(_ node: JSONNode?) -> [String] { node?.members.map(\.key) ?? [] }
  func example(_ t: String) -> [String] { keys(examples["client"]?[t]) }

  @Test func everyMessageSentHasTheExamplesFieldsInItsOrder() async throws {
    var sockets: [MockTransport] = []
    let pitch = try PitchClient(
      url: URL(string: "ws://127.0.0.1:1")!, pitch: "abcdefghjk", appVersion: "0.0-test",
      me: [("name", .string("Anna"))], store: MemoryID("Member_A1"), create: true, timing: fastTiming(),
      factory: { _ in
        let t = MockTransport()
        sockets.append(t)
        t.onSend = { m in
          guard m["t"]?.string == "join" else { return }
          t.push(
            #"{"t":"joined","pitch":"abcdefghjk","you":"Member_A1","role":"player","host":"Member_A1","s":0,"ts":1,"members":[],"v":3,"by":"Member_A1","doc":{"teams":{}},"match":null}"#
          )
        }
        return t
      })
    defer { pitch.close() }
    pitch.connect()
    try await pitch.ready()
    // a reconnect holding version 3 and match 2 at action 41
    pitch.cursor = { (2, 41) }
    sockets[0].deliver(.failure(PitchError("network")))
    try await eventually { sockets.count == 2 && pitch.status == .open }
    let join = sockets[1].sent[0]
    #expect(keys(join) == example("join"))
    #expect(keys(sockets[0].sent[0]) == ["t", "member", "role", "me", "create"])

    let t = sockets[1]
    pitch.setMe([("level", .string("club"))])
    t.onSend = { m in
      switch m["t"]?.string {
      case "set": t.push(#"{"t":"ok","re":"set","id":"\#(m["id"]!.string!)","v":4,"s":1,"ts":2}"#)
      case "start": t.push(#"{"t":"ok","re":"start","id":"\#(m["id"]!.string!)","v":5,"n":3,"s":2,"ts":3}"#)
      default: break
      }
    }
    _ = try await pitch.update { _ in JSONText(#"{"teams":{},"options":{}}"#) }
    #expect(
      try await pitch.start(
        base: 4, doc: JSONText(#"{"started":true}"#), n: 3, h: "h0", snap: "{}", meta: JSONText(#"{"v":1}"#)))
    pitch.act(id: "a-1", n: 3, seq: 1, a: JSONText("{}"), h: "h1", snap: "{}", over: true)
    pitch.cast(JSONText(#"{"t":"aim","s":{}}"#), all: true)
    pitch.list(JSONText(#"{"seats":12,"state":"waiting"}"#))
    pitch.resync()
    await pitch.leave()
    func sent(_ type: String) -> JSONNode? { t.sent.first { $0["t"]?.string == type } }
    for type in ["me", "set", "start", "act", "cast", "open", "resync", "leave"] {
      #expect(keys(sent(type)) == example(type), "\(type)")
    }
    #expect(sent("me")?.raw.text == #"{"t":"me","me":{"level":"club"}}"#)  // the example, compact
    #expect(sent("set")?["id"]?.string == "w1" && sent("start")?["id"]?.string == "go2")
    #expect(sent("act")?["c"]?.string == "ios")
    // the keep-alive is the literal text frame, never JSON
    #expect(!t.frames.contains { $0.contains(#""t":"ping""#) })
  }

  @Test func everyPitchFrameIsReadAsTheTableSays() async throws {
    let t = MockTransport()
    let pitch = try makeClient({ _ in t }, store: MemoryID("Member_A1"))
    defer { pitch.close() }
    var seen: [String] = []
    var docs: [Int] = []
    pitch.observe {
      switch $0 {
      case .message(let m): seen.append(m["t"]?.string ?? "")
      case .document(let v, _, _): docs.append(v)
      default: break
      }
    }
    pitch.connect()
    try await eventually { t.sent.count == 1 }
    let frames = examples["server"]!.items
    for f in frames { t.push(f.raw.text) }
    try await eventually { seen.last == "error" }
    #expect(pitch.status == .open && pitch.gaps == 0)
    #expect(pitch.s == 17)  // ten, then member … left; the cast and the dup move nothing
    #expect(docs == [4, 5] && pitch.version == 5)
    #expect(pitch.host == "Member_A1" && pitch.members.map { $0["id"]?.string } == ["Member_A1"])
    #expect(seen == ["joined", "member", "doc", "start", "act", "cast", "ok", "ok", "refused", "host", "left", "pong", "error"])
    #expect(pitch.limits?["resumeMax"]?.int == 64)
    #expect(pitch.lastJoin?["match"]?["full"]?.bool == false)
  }
}
