import Foundation
import KubbEngine
import Testing

@testable import KubbRooms

@Suite @MainActor struct PitchTests {
  func setup() async throws -> (PitchController, MockTransport) {
    let t = MockTransport()
    let engine = try Engine(appVersion: "0.0-test")
    let room = try makeClient({ _ in t }, engineVersion: engine.engineVersion)
    let p = try PitchController(room: room, engine: engine)
    t.onSend = { m in
      if m["t"]?.string == "join" { t.joined() }
      if m["t"]?.string == "set" {
        t.push("{\"t\":\"ok\",\"id\":\(m["id"]!.int!),\"v\":\(m["base"]!.int!+1)}")
      }
    }
    p.connect()
    try await room.ready()
    // Real member payloads make the strict engine START check meaningful.
    room.receive(
      #"{"t":"member","rev":2,"member":{"id":"Native_Member","connected":true,"joined":1,"me":{"name":"Native","level":"pro","engine":"\#(engine.engineVersion)"}}}"#
    )
    return (p, t)
  }
  let at = JSONText(#"{"year":2026,"month":11,"day":17,"hour":12,"min":0}"#)

  @Test func hostComputerAndStrictMismatch() async throws {
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: at))
    #expect(p.state == .match && p.mayAct)
    // A resignation on A's turn leaves the computer's match finished and kept.
    #expect(try await p.take(JSONText(#"{"type":"resign","side":"A"}"#)))
    #expect(try JSONNode.parse(p.need)["kind"]?.string == "over")
    #expect(try JSONNode.parse(p.room.document)["match"]?["over"]?.bool == true)
    _ = try await p.reduce("backToLobby")
    #expect(p.state == .lobby)
    p.room.receive(
      #"{"t":"member","rev":3,"member":{"id":"Guest_01","connected":true,"joined":2,"me":{"engine":"0.2.0"}}}"#
    )
    _ = try await p.room.update { doc in
      let value = try p.roomCall(
        "joinTeam", [("doc", .raw(doc)), ("id", .string("Guest_01")), ("side", .string("B"))])
      return value.raw
    }
    #expect(try await p.start(seed: 3, at: at) == false)
    #expect(p.state == .versionMismatch)
  }

  @Test func aRoomThatCameBackIsNotAnsweredFromTheOldMatchsReplay() async throws {
    let resign = JSONText(#"{"type":"resign","side":"A"}"#)
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: at))
    #expect(try await p.take(resign))
    let first = try #require(p.finishedReplay)
    // another room's finished match, also its first, from another seed
    let (q, _) = try await setup()
    defer { q.close() }
    try await q.joinTeam("A")
    #expect(try await q.start(seed: 2002, at: at))
    #expect(try await q.take(resign))
    let second = try #require(q.finishedReplay)
    #expect(first.n == second.n && first != second)
    // the room expired and came back with that match under the same number
    p.room.receive(
      JS.object([
        ("t", .string("joined")), ("host", .string("Native_Member")), ("rev", .int(1)),
        ("members", .raw(JSONText("[]"))), ("v", .int(q.room.version)),
        ("doc", .raw(q.room.document)),
      ]).ascii)
    #expect(p.finishedReplay == second)
  }

  @Test func applyGapCorrectionAndRunningVersionMismatch() async throws {
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 10, at: at))
    let peer = try Engine(appVersion: "0.0-test")
    _ = try peer.call("restore", json: p.engine.call("snapshot"))
    let action = JSONText(#"{"type":"resign","side":"A"}"#)
    _ = try peer.call("apply", json: action.text)
    let doc = try p.roomCall(
      "commitAction",
      [
        ("doc", .raw(p.room.document)), ("n", .int(1)), ("seq", .int(1)),
        ("snap", .string(peer.call("snapshot"))), ("hash", .string(peer.hash())),
        ("action", .raw(action)), ("over", .bool(true)),
      ])
    let rider = try p.roomCall(
      "rider", [("n", .int(1)), ("seq", .int(1)), ("action", .raw(action))])
    p.room.receive(
      JS.object([
        ("t", .string("doc")), ("v", .int(3)), ("doc", .raw(doc.raw)), ("with", .raw(rider.raw)),
      ]).ascii)
    #expect(p.applied == 1 && p.corrections == 0)
    #expect(try p.engine.hash() == peer.hash())
    // A missing action is a gap adoption, distinct from a hash correction.
    let gapMatch = JS.object(
      doc["match"]!.members.map {
        ($0.key, $0.key == "seq" ? JS.int(3) : JS.raw($0.value.raw))
      })
    let gap = JS.object(
      doc.members.map { ($0.key, $0.key == "match" ? gapMatch : JS.raw($0.value.raw)) })
    p.room.receive(JS.object([("t", .string("doc")), ("v", .int(4)), ("doc", gap)]).ascii)
    #expect(p.adoptions == 1 && p.sequence == 3)
    // Return to the original seq to test same-sequence hash recovery.
    p.room.receive(
      JS.object([
        ("t", .string("joined")), ("host", .string(p.room.you)), ("rev", .int(10)),
        ("members", p.room.membersJSON), ("v", .int(5)), ("doc", .raw(doc.raw)),
      ]).ascii)
    #expect(p.sequence == 1)  // authoritative joined reset, not an ordinary old doc
    // Start another match to test same-sequence hash recovery.
    _ = try await p.reduce("backToLobby")
    #expect(try await p.start(seed: 11, at: at))
    let current = try JSONNode.parse(p.room.document)
    // A same-sequence document with a deliberately corrupt hash forces recovery.
    var m = current["match"]!.members.map { ($0.key, JS.raw($0.value.raw)) }
    m.removeAll { $0.0 == "hash" }
    m.append(("hash", .string("00000000")))
    let corrupt = JS.object(
      current.members.map { ($0.key, $0.key == "match" ? .object(m) : JS.raw($0.value.raw)) })
    p.room.receive(
      JS.object([("t", .string("doc")), ("v", .int(p.room.version + 1)), ("doc", corrupt)]).ascii)
    #expect(p.corrections == 1)
    m.removeAll { $0.0 == "engine" }
    m.append(("engine", .string("9.0")))
    let newer = JS.object(
      current.members.map { ($0.key, $0.key == "match" ? .object(m) : JS.raw($0.value.raw)) })
    p.room.receive(
      JS.object([("t", .string("doc")), ("v", .int(p.room.version + 1)), ("doc", newer)]).ascii)
    #expect(p.state == .versionMismatch && !p.mayAct)
  }

  @Test func hostCPUActuallyReleasesAndSeatsRemainCached() async throws {
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: at))
    // Exercise human computer-planned throws with a minimal legal fixed launch until
    // B's turn, then use the production frame path for the host-owned computer.
    for _ in 0..<6 {
      let n = try JSONNode.parse(p.need)
      if n["cpu"]?.bool == true { break }
      let a = JSONText(
        "{\"type\":\"throw\",\"seq\":\(n["throws"]!.int!),\"how\":\"baton\",\"launch\":{\"speed\":5,\"loft\":20,\"swivel\":0,\"legal\":true},\"stance\":{\"x\":0,\"y\":0},\"target\":{\"x\":0,\"y\":8},\"scripted\":true}"
      )
      #expect(try await p.take(a))
    }
    #expect(try JSONNode.parse(p.need)["cpu"]?.bool == true)
    let seq = p.sequence
    for _ in 0..<200 {
      _ = try await p.frame(JSONText(#"{"dt":0.1}"#))
      if p.sequence > seq { break }
    }
    #expect(p.sequence == seq + 1)
    #expect(p.lastError == nil)
  }
  @Test func rejoinAdoptsRestartedRoomWithReusedMatchNumber() async throws {
    let (p, _) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: at))
    let stale = try JSONNode.parse(p.room.document)
    let advanced = JS.object(
      stale["match"]!.members.map {
        ($0.key, $0.key == "seq" ? JS.int(8) : JS.raw($0.value.raw))
      })
    let staleDoc = JS.object(
      stale.members.map {
        ($0.key, $0.key == "match" ? advanced : JS.raw($0.value.raw))
      })
    p.room.receive(JS.object([("t", .string("doc")), ("v", .int(9)), ("doc", staleDoc)]).ascii)
    #expect(p.sequence == 8)
    let (fresh, _) = try await setup()
    defer { fresh.close() }
    try await fresh.joinTeam("A")
    #expect(try await fresh.start(seed: 2002, at: at))
    let newHash = try fresh.engine.hash()
    #expect(try p.engine.hash() != newHash)
    p.room.receive(
      JS.object([
        ("t", .string("joined")), ("host", .string(p.room.you)), ("rev", .int(1)),
        ("members", p.room.membersJSON), ("v", .int(2)), ("doc", .raw(fresh.room.document)),
      ]).ascii)
    #expect(p.matchNumber == 1 && p.sequence == 0 && p.state == .match)
    #expect(try p.engine.hash() == newHash)
    #expect(p.mayAct)
  }

  @Test func incompatibleRunningMatchSurvivesJoinedMembersEvent() async throws {
    let (host, _) = try await setup()
    defer { host.close() }
    try await host.joinTeam("A")
    #expect(try await host.start(seed: 7, at: at))
    let doc = try JSONNode.parse(host.room.document)
    let incompatible = JS.object(
      doc["match"]!.members.filter { $0.key != "engine" }.map {
        ($0.key, JS.raw($0.value.raw))
      } + [("engine", .string("9.0"))])
    let remoteDoc = JS.object(
      doc.members.map { ($0.key, $0.key == "match" ? incompatible : JS.raw($0.value.raw)) })
    let (guest, _) = try await setup()
    defer { guest.close() }
    // receive(joined) emits state followed immediately by members, as a real join.
    guest.room.receive(
      JS.object([
        ("t", .string("joined")), ("host", .string(host.room.you)), ("rev", .int(3)),
        ("members", host.room.membersJSON), ("v", .int(2)), ("doc", remoteDoc),
      ]).ascii)
    #expect(guest.state == .versionMismatch && !guest.mayAct)
    #expect(try JSONNode.parse(guest.mismatch!)["why"]?.string == "differs")
    guest.room.receive(
      #"{"t":"member","rev":4,"member":{"id":"Watcher_01","joined":3,"connected":true}}"#)
    #expect(guest.state == .versionMismatch)
  }

}
