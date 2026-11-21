import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// A member of a fake pitch with a real engine: the controller as the app runs it.
@MainActor func player(
  _ fake: FakePitch, _ id: String, engines: EngineShelf? = nil, observing: Bool = false
) async throws -> PitchController {
  let pitch = try makeClient(fake.factory, store: MemoryID(id), observing: observing)
  let p = try PitchController(pitch: pitch, engines: engines ?? EngineShelf(appVersion: "0.0-test"))
  p.connect()
  try await pitch.ready()
  return p
}

let startAt = JSONText(#"{"year":2026,"month":11,"day":17,"hour":12,"min":0}"#)

/// A legal fixed throw for whoever is to throw (a scripted launch, as the computer's).
@MainActor func scriptedThrow(_ p: PitchController) throws -> JSONText? {
  let n = try JSONNode.parse(p.need)
  guard n["kind"]?.string == "throw", let seq = n["throws"]?.int else { return nil }
  return JSONText(
    #"{"type":"throw","seq":\#(seq),"how":"baton","launch":{"speed":5,"loft":20,"swivel":0,"legal":true},"stance":{"x":0,"y":0},"target":{"x":0,"y":8},"scripted":true}"#
  )
}

/// A peer's action the test plays itself: from the pitch's head, its hash and snapshot.
@MainActor func peerAction(_ fake: FakePitch, _ action: JSONText) throws -> (h: String, snap: String) {
  let peer = try Engine(appVersion: "0.0-test")
  _ = try peer.call("restore", json: fake.match!.snap)
  _ = try peer.call("apply", json: action.text)
  return (try peer.hash(), try peer.call("snapshot"))
}

@MainActor func hash(_ p: PitchController) throws -> String { try p.engine.hash() }

@Suite @MainActor struct PitchTests {
  let resign = JSONText(#"{"type":"resign","side":"A"}"#)

  /// The host against the computer: START is one message, the match's start info goes
  /// once as `meta`, the action that ends it carries `over`, and the lobby stays lobby.
  @Test func aMatchAgainstTheComputerStartsPlaysAndEnds() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    #expect(p.state == .match && p.mayAct && p.matchNumber == 1 && p.sequence == 0)
    let meta = try JSONNode.parse(try #require(fake.match?.meta))
    // the web's pitch.js meta: { v: 1, setup, engine (major.minor), version, players, cpu }
    #expect(meta.members.map(\.key) == ["v", "setup", "engine", "version", "players", "cpu"])
    #expect(meta["v"]?.int == 1 && meta["engine"]?.string == p.engine.minor)
    #expect(meta["version"]?.string == p.engine.engineVersion && meta["host"] == nil)
    #expect(meta["setup"]?.kind == .object)
    // the document keeps only the match's header
    let doc = try JSONNode.parse(fake.doc)
    #expect(doc["started"]?.bool == true && doc["n"]?.int == 1)
    let header = try #require(doc["match"])
    #expect(header.members.map(\.key) == ["n", "players", "cpu", "host", "engine"])
    #expect(header["n"]?.int == 1 && header["host"]?.string == "Native_Member" && header["engine"]?.string == p.engine.minor)
    #expect(header["players"]?["A"]?.items.first?["id"]?.string == "Native_Member")
    #expect(try fake.match?.h0 == (hash(p)))

    #expect(try await p.take(resign))
    #expect(try JSONNode.parse(p.need)["kind"]?.string == "over")
    try await eventually { p.outstanding.isEmpty }
    #expect(fake.match?.over == true && fake.match?.acts.last?.over == true)
    #expect(fake.match?.acts.last?.c == "ios")
    #expect(p.finishedReplay == ReelMatch(n: 1, hash: fake.match!.h))
    #expect(try await p.take(resign) == false)  // over: nothing more

    _ = try await p.reduce("backToLobby")
    #expect(p.state == .lobby && p.match == nil && p.finishedReplay == nil)
    #expect(try await p.start(seed: 1002, at: startAt))
    #expect(fake.match?.n == 2 && p.matchNumber == 2)
  }

  @Test func twoPlayersStayInStepActionByAction() async throws {
    let fake = FakePitch()
    let a = try await player(fake, "Member_A1")
    let b = try await player(fake, "Member_B1")
    defer {
      a.close()
      b.close()
    }
    try await a.joinTeam("A")
    try await b.joinTeam("B")
    try await eventually { a.pitch.version == 2 }
    #expect(try await a.start(seed: 7, at: startAt))
    try await eventually { b.state == .match }
    #expect(try hash(a) == hash(b))
    var made = 0
    for _ in 0..<40 where made < 8 {
      let actor = a.mayAct ? a : b.mayAct ? b : nil
      guard let actor, let action = try scriptedThrow(actor) else { break }
      #expect(try await actor.take(action))
      made += 1
      try await eventually { a.sequence == made && b.sequence == made && a.outstanding.isEmpty && b.outstanding.isEmpty }
      #expect(try hash(a) == hash(b))
    }
    #expect(made >= 6)
    #expect(a.applied + b.applied == made && a.corrections + b.corrections == 0)
    #expect(fake.match?.seq == made)
  }

  /// The next action never waits for the last one's `ok`; then every socket drops with
  /// both answers lost, and the reconnect resumes by sequence: each action once, none lost.
  @Test func actionsInFlightSurviveEverySocketDropping() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    let watcher = try await player(fake, "Member_W1")  // in the lobby, no seat
    defer {
      p.close()
      watcher.close()
    }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    try await eventually { watcher.state == .match }
    fake.links(of: "Native_Member").last!.deaf = true
    let first = try #require(try scriptedThrow(p))
    #expect(try await p.take(first))
    let second = try #require(try scriptedThrow(p))
    #expect(try await p.take(second))
    #expect(p.outstanding.count == 2 && p.sequence == 2)
    try await eventually { fake.match?.seq == 2 && watcher.sequence == 2 }
    let ids = fake.match!.acts.map(\.id)
    #expect(ids == p.outstanding.map(\.id))

    fake.dropAll()
    try await eventually { p.pitch.status == .open && p.outstanding.isEmpty && p.pitch.outbox.isEmpty }
    let rejoin = try #require(fake.links(of: "Native_Member").last?.sent.first)
    #expect(rejoin["n"]?.int == 1 && rejoin["seq"]?.int == 0)
    #expect(fake.links(of: "Native_Member").last!.got("joined")[0]["match"]?["full"]?.bool == false)
    #expect(fake.match?.acts.map(\.id) == ids)  // stored once each
    #expect(try p.sequence == 2 && p.head?.h == fake.match?.h && (hash(p)) == fake.match?.h)
    try await eventually { watcher.pitch.status == .open }
    #expect(try watcher.sequence == 2 && (hash(watcher)) == fake.match?.h)
    #expect(p.corrections == 0 && p.adoptions == 0 && watcher.adoptions == 0)
  }

  @Test func aMemberThatWasAwayResumesFromWhereItWasOrTakesTheWholeMatch() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    let w = try await player(fake, "Member_W1")
    defer {
      p.close()
      w.close()
    }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    try await eventually { w.state == .match }
    // away for two actions: they come with the join, played and checked here
    fake.links(of: "Member_W1").last!.swallow = true
    fake.links(of: "Member_W1").last!.deaf = true
    for _ in 0..<2 {
      let action = try #require(try scriptedThrow(p))
      #expect(try await p.take(action, computer: true))
    }
    try await eventually { fake.match?.seq == 2 }
    fake.links(of: "Member_W1").last!.drop()
    try await eventually { w.pitch.status == .open && w.sequence == 2 }
    #expect(try w.applied == 2 && w.adoptions == 0 && (hash(w)) == fake.match?.h)
    // further behind than the pitch resumes: the whole match, from its head snapshot
    fake.resumeMax = 0
    fake.links(of: "Member_W1").last!.deaf = true
    let action = try #require(try scriptedThrow(p))
    #expect(try await p.take(action, computer: true))  // the computer's throw, the host's to make
    try await eventually { fake.match?.seq == 3 }
    fake.links(of: "Member_W1").last!.drop()
    try await eventually { w.pitch.status == .open && w.sequence == 3 }
    #expect(try w.adoptions == 1 && (hash(w)) == fake.match?.h && w.state == .match)
  }

  /// Two actions for one place: the peer's reached the pitch first. This member's is
  /// dropped, the engine goes back to the head and plays the peer's.
  @Test func aPeerFirstWinsAndOwnActionsRollBack() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    fake.links(of: "Native_Member").last!.swallow = true  // on its way, not there yet
    let mine = try #require(try scriptedThrow(p))
    #expect(try await p.take(mine))
    #expect(p.outstanding.count == 1)
    let peer = try peerAction(fake, resign)
    fake.store(from: "Member_P1", id: "peer-act-1", seq: 1, a: resign, h: peer.h, snap: peer.snap, over: true)
    try await eventually { p.conflicts == 1 }
    #expect(p.outstanding.isEmpty && p.pitch.outbox.isEmpty)
    #expect(try p.sequence == 1 && (hash(p)) == peer.h)
    #expect(try JSONNode.parse(p.need)["kind"]?.string == "over")
    #expect(fake.match?.acts.count == 1)
  }

  @Test func aRefusalPutsThisMemberBackOnThePitchsHead() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    let before = try hash(p)
    fake.refuseNext = "seq"
    let action = try #require(try scriptedThrow(p))
    #expect(try await p.take(action))
    try await eventually { p.outstanding.isEmpty && p.mayAct && !p.awaitingState }
    #expect(try p.sequence == 0 && (hash(p)) == before)
    #expect(fake.links(of: "Native_Member").last!.sent("resync").count == 1)
    // and plays on
    let again = try #require(try scriptedThrow(p))
    #expect(try await p.take(again))
    try await eventually { fake.match?.seq == 1 && p.outstanding.isEmpty }
  }

  @Test func aHashThatDiffersIsAResyncAndTheWholeMatchIsTaken() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    let w = try await player(fake, "Member_W1")
    defer {
      p.close()
      w.close()
    }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    try await eventually { w.state == .match }
    let peer = try peerAction(fake, resign)
    fake.store(from: "Member_P1", id: "peer-act-1", seq: 1, a: resign, h: "00000000", snap: peer.snap, over: true)
    try await eventually { w.corrections == 1 && w.adoptions == 1 }
    #expect(fake.links(of: "Member_W1").last!.sent("resync").count == 1)
    #expect(w.state == .match && w.sequence == 1 && w.head?.h == "00000000")
    #expect(try hash(w) == peer.h)  // the pitch's snapshot
  }

  @Test func aMatchOnAnEngineThisBuildLacksIsWatchedNotPlayed() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 7, at: startAt))
    let meta = try JSONNode.parse(fake.match!.meta)
    fake.match!.meta = PitchController.with(meta, [("engine", .string("9.0.0"))]).json
    let g = try await player(fake, "Member_G1")
    defer { g.close() }
    try await eventually { g.state == .versionMismatch }
    #expect(try !g.mayAct && (JSONNode.parse(try #require(g.mismatch)))["why"]?.string == "differs")
    #expect(g.match != nil)
    // someone else joining changes nothing
    let h = try await player(fake, "Member_H1")
    defer { h.close() }
    try await eventually { g.pitch.members.count == 3 }
    #expect(g.state == .versionMismatch)
  }

  /// Aim goes at most 15 times a second and only when it changes; the aim at a release
  /// and a shout reach every watcher (`all`).
  @Test func aimIsCastWhileItChangesAndTheLastAimReachesEveryone() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    let link = fake.links(of: "Native_Member").last!
    try p.castAim(JSONText(#"{"seq":0,"x":0}"#), now: 1_000)
    try p.castAim(JSONText(#"{"seq":0,"x":1}"#), now: 1_030)  // too soon
    try p.castAim(JSONText(#"{"seq":0,"x":0}"#), now: 1_100)  // unchanged
    try p.castAim(JSONText(#"{"seq":0,"x":2}"#), now: 1_166)
    try p.castAim(JSONText(#"{"seq":0,"x":2}"#), final: true, now: 1_170)
    #expect(p.shout("TOK!", now: 1_200) && !p.shout("TOK!", now: 1_500) && !p.shout("HELLO", now: 3_000))
    // a shout spent the slot: an aim 40 ms after it waits
    try p.castAim(JSONText(#"{"seq":0,"x":3}"#), now: 1_240)
    try await eventually { link.sent("cast").count == 4 }
    let casts = link.sent("cast")
    #expect(casts.map { $0["d"]?["s"]?["x"]?.int } == [0, 2, 2, nil])
    #expect(casts.map { $0["d"]?["k"]?.int } == [1, 2, 3, nil])
    #expect(casts.map { $0["d"]?["c"]?.int } == [1_000, 1_166, 1_170, nil])
    #expect(casts[0]["d"]?.members.map(\.key) == ["t", "s", "k", "c"])
    #expect(casts.map { $0["all"]?.bool } == [nil, nil, true, true])
    #expect(casts[3]["d"]?["w"]?.string == "TOK!")
    #expect(PitchController.aimEvery == 66)
  }

  /// The pitch hands the host on; nobody claims it, and the new host may START.
  @Test func theHostIsHandedOnByThePitch() async throws {
    let fake = FakePitch()
    let a = try await player(fake, "Member_A1")
    let b = try await player(fake, "Member_B1")
    defer {
      a.close()
      b.close()
    }
    try await b.joinTeam("A")
    fake.passHost(to: "Member_B1")
    try await eventually { b.pitch.isHost && !a.pitch.isHost }
    #expect(try await b.start(seed: 3, at: startAt))
    try await eventually { a.state == .match }
    for link in fake.links { #expect(link.sent("claim").isEmpty) }
  }
}
