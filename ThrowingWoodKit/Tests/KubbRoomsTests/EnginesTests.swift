import Foundation
import KubbEngine
import Testing

@testable import KubbRooms

/// Several engines in one room (kubb-engine docs/ROOM.md "Engines in one match",
/// "The room's engine", "Speaking down"), as the controller speaks it.
@Suite @MainActor struct EnginesTests {
  let at = JSONText(#"{"year":2026,"month":11,"day":17,"hour":12,"min":0}"#)

  func setup() async throws -> (PitchController, MockTransport) {
    let t = MockTransport()
    let engines = try EngineShelf(appVersion: "0.0-test")
    let room = try makeClient({ _ in t }, engineVersion: engines.newest.engineVersion)
    let p = try PitchController(room: room, engines: engines)
    // the server's echo of this member's presence, merged field by field
    var me: [(String, JS)] = []
    var rev = 100
    func echo(_ fields: JSONNode?) {
      for (k, v) in fields?.members ?? [] {
        me.removeAll { $0.0 == k }
        me.append((k, .raw(v.raw)))
      }
      rev += 1
      t.push(
        JS.object([
          ("t", .string("member")), ("rev", .int(rev)),
          ("member", .object([("id", .string("Native_Member")), ("connected", .bool(true)), ("joined", .int(0)), ("me", .object(me))])),
        ]).ascii)
    }
    t.onSend = { m in
      if m["t"]?.string == "join" {
        t.joined()
        echo(m["me"])
      }
      if m["t"]?.string == "me" { echo(m["me"]) }
      if m["t"]?.string == "set" {
        t.push("{\"t\":\"ok\",\"id\":\(m["id"]!.int!),\"v\":\(m["base"]!.int!+1)}")
      }
    }
    p.connect()
    try await room.ready()
    try await eventually { room.members.contains { $0["id"]?.string == "Native_Member" } }
    return (p, t)
  }

  /// A member whose presence is `me`, seated on `side`.
  func seat(_ p: PitchController, _ id: String, me: String, side: String, rev: Int) async throws {
    p.room.receive(
      #"{"t":"member","rev":\#(rev),"member":{"id":"\#(id)","connected":true,"joined":\#(rev),"me":\#(me)}}"#)
    _ = try await p.room.update { doc in
      try p.roomCall("joinTeam", [("doc", .raw(doc)), ("id", .string(id)), ("side", .string(side))]).raw
    }
  }

  func sets(_ t: MockTransport) -> [JSONNode] { t.sent.filter { $0["t"]?.string == "set" } }
  func lastMe(_ t: MockTransport) -> JSONNode? {
    t.sent.last { $0["t"]?.string == "me" }?["me"] ?? t.sent.first { $0["t"]?.string == "join" }?["me"]
  }

  /// The computer's level is a room option on 0.9 (in the document's `settings`, read
  /// with `optionsOf`); a room whose next match is on 0.8 offers and reads 0.8's five.
  @Test func theComputersLevelIsARoomOptionOnlyWhereTheMatchWouldTakeIt() async throws {
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    func ids() throws -> [String] { try p.optionRows().items.compactMap { $0.items.first?.string } }
    #expect(try ids().contains("computer"))
    #expect(try p.roomOptions(p.room.document)["computer"] == "club")
    _ = try await p.reduce("setOptions", fields: [("options", .object([("computer", .string("pro"))]))])
    let doc = try JSONNode.parse(p.room.document)
    #expect(doc["settings"]?["computer"]?.string == "pro" && doc["options"]?["computer"] == nil)
    #expect(try p.roomOptions(p.room.document)["computer"] == "pro")
    #expect(try p.roomOptions(p.room.document)["scene"] == "day")
    // the host's scene, as the web writes it: the document's settings.scene
    #expect(p.lobbyTakesScene())
    _ = try await p.reduce("setOptions", fields: [("options", .object([("scene", .string("night"))]))])
    #expect(try JSONNode.parse(p.room.document)["settings"]?["scene"]?.string == "night")
    #expect(try p.roomOptions(p.room.document)["scene"] == "night")

    // a tester on 0.8 takes a seat: the next match is on 0.8, which has no such option
    try await seat(p, "Guest_08", me: #"{"name":"Tester","engine":"0.8.1"}"#, side: "B", rev: 3)
    #expect(try p.roomEngine()["engine"]?.string == "0.8")
    #expect(try !ids().contains("computer"))
    #expect(!p.lobbyTakesScene())
    #expect(try p.roomOptions(p.room.document)["computer"] == nil)
    // 0.8's own write (the guest's seat) kept the host's setting
    #expect(try JSONNode.parse(p.room.document)["settings"]?["computer"]?.string == "pro")
  }

  @Test func aStartOnNineGivesTheComputerTheRoomsLevel() async throws {
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    _ = try await p.reduce("setOptions", fields: [("options", .object([("computer", .string("beginner"))]))])
    #expect(try await p.start(seed: 7, at: at))
    #expect(p.engine.minor == Engine.newest)
    #expect(try p.engine.call("snapshot").contains(#""computer":"beginner""#))
  }

  @Test func theJoinAnnouncesEveryEngineCarriedAndTheNewestAsTheRoomsEngine() async throws {
    let (p, t) = try await setup()
    defer { p.close() }
    let me = try #require(t.sent.first { $0["t"]?.string == "join" }?["me"])
    #expect(me["engine"]?.string == Engine.newest + "+engines")
    #expect(me["engines"]?.items.compactMap(\.string) == Engine.carried)
    // an older client reads the legacy field as its major.minor
    #expect(Engine.majorMinor(me["engine"]?.string) == Engine.newest)
  }

  @Test func aRiderDoesNotNameTheDevice() async throws {
    let (p, t) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: at))
    #expect(try await p.take(JSONText(#"{"type":"resign","side":"A"}"#)))
    let rider = try #require(sets(t).last?["with"])
    #expect(rider["c"]?.string == "web")  // the rider's default, as a browser's
    #expect(rider["e"]?.string == p.engine.engineVersion)
  }

  @Test func aPlayerOnAnEngineThisBuildLacksStopsStartAndNothingIsWritten() async throws {
    let (p, t) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    try await seat(p, "Guest_01", me: #"{"name":"Old","engine":"0.6"}"#, side: "B", rev: 3)
    let chosen = try p.roomEngine()
    #expect(chosen["engine"]?.isNull == true)
    #expect(chosen["missing"]?.items.compactMap(\.string) == ["Guest_01"])
    let before = sets(t).count
    #expect(try await p.start(seed: 3, at: at) == false)
    #expect(p.state == .versionMismatch && p.match == nil)
    #expect(sets(t).count == before)
    let m = try JSONNode.parse(try #require(p.mismatch))
    #expect(m["differ"]?.items.compactMap(\.string) == ["Guest_01"])
    // the announcement stays the newest: no engine is shared
    #expect(lastMe(t)?["engine"]?.string == Engine.newest + "+engines")
  }

  @Test func aRunningMatchOnAnEngineThisBuildLacksIsRefused() async throws {
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 5, at: at))
    let doc = try JSONNode.parse(p.room.document)
    let m = doc["match"]!
    // another match on the pitch, started by a client on an engine this build lacks
    let old = JS.object(
      m.members.map {
        switch $0.key {
        case "engine": ("engine", JS.string("0.6"))
        case "n": ("n", JS.int(9))
        default: ($0.key, JS.raw($0.value.raw))
        }
      })
    let next = JS.object(doc.members.map { ($0.key, $0.key == "match" ? old : JS.raw($0.value.raw)) })
    p.room.receive(JS.object([("t", .string("doc")), ("v", .int(p.room.version + 1)), ("doc", next)]).ascii)
    #expect(p.state == .versionMismatch)
    let refusal = try JSONNode.parse(try #require(p.mismatch))
    #expect(refusal["why"]?.string == "differs")
  }

  /// The room's engine follows the players: a seated player carrying only an older
  /// engine this build also carries brings the announcement down to it, START runs on
  /// that engine and stamps the match with it, and the older Lua state is made only then.
  @Test(.enabled(if: Engine.carried.count > 1)) func anOlderPlayerBringsTheRoomDownToTheirEngine()
    async throws
  {
    let older = Engine.carried[1]
    let (p, t) = try await setup()
    defer { p.close() }
    #expect(p.engines.loaded == [Engine.newest])
    try await p.joinTeam("A")
    try await seat(p, "Guest_07", me: #"{"name":"Old","engine":"\#(older)"}"#, side: "B", rev: 3)
    #expect(try p.roomEngine()["engine"]?.string == older)
    try await eventually { lastMe(t)?["engine"]?.string == older + "+engines" }
    #expect(try await p.start(seed: 1001, at: at))
    let match = try #require(JSONNode.parse(p.room.document)["match"])
    #expect(match["engine"]?.string == older)
    #expect(p.engine.minor == older)
    #expect(Set(p.engines.loaded) == Set([Engine.newest, older]))
    // the player leaves for good: back to the newest
    p.room.receive(#"{"t":"left","id":"Guest_07","rev":4}"#)
    try await eventually { lastMe(t)?["engine"]?.string == Engine.newest + "+engines" }
  }
}
