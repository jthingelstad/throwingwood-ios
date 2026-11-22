import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// Several engines on one pitch (kubb-engine docs/ROOM.md "Engines in one match",
/// "The room's engine", "Speaking down"), as the controller speaks it.
@Suite @MainActor struct EnginesTests {
  func setup() async throws -> (PitchController, FakePitch) {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    return (p, fake)
  }

  /// A member with presence `me` (no controller of its own), seated on `side`.
  func seat(_ p: PitchController, _ fake: FakePitch, _ id: String, me: [(String, JS)], side: String) async throws
    -> PitchClient
  {
    let guest = try makeClient(fake.factory, store: MemoryID(id))
    guest.setMe(me)
    guest.connect()
    try await guest.ready()
    try await eventually { p.pitch.members.contains { $0["id"]?.string == id } }
    _ = try await p.pitch.update { doc in
      try p.pitchCall("joinTeam", [("doc", .raw(doc)), ("id", .string(id)), ("side", .string(side))]).raw
    }
    return guest
  }

  func lastMe(_ fake: FakePitch) -> [(String, JS)] { fake.members["Native_Member"]?.me ?? [] }
  func announced(_ fake: FakePitch) -> String? {
    guard case .raw(let text)? = lastMe(fake).first(where: { $0.0 == "engine" })?.1 else { return nil }
    return try? JSONNode.parse(text).string
  }

  /// The computer's level is a room option (in the document's `settings`, read with
  /// `optionsOf`). A seated tester on an engine this build no longer carries leaves the
  /// room with no engine: the options stay the newest's and nothing is dropped.
  @Test func theComputersLevelIsARoomOptionOnlyWhereTheMatchWouldTakeIt() async throws {
    let (p, fake) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    func ids() throws -> [String] { try p.optionRows().items.compactMap { $0.items.first?.string } }
    #expect(try ids().contains("computer"))
    #expect(try p.roomOptions(p.pitch.document)["computer"] == "club")
    _ = try await p.reduce("setOptions", fields: [("options", .object([("computer", .string("pro"))]))])
    let doc = try JSONNode.parse(p.pitch.document)
    #expect(doc["settings"]?["computer"]?.string == "pro" && doc["options"]?["computer"] == nil)
    #expect(try p.roomOptions(p.pitch.document)["computer"] == "pro")
    #expect(try p.roomOptions(p.pitch.document)["scene"] == "day")
    #expect(p.lobbyTakesScene())
    _ = try await p.reduce("setOptions", fields: [("options", .object([("scene", .string("night"))]))])
    #expect(try JSONNode.parse(p.pitch.document)["settings"]?["scene"]?.string == "night")

    // a tester on 0.8 takes a seat: no engine is carried by both, so no match is offered
    // on 0.8; the lobby keeps the newest's options and the host's setting
    let guest = try await seat(p, fake, "Guest_08", me: [("name", .string("Tester")), ("engine", .string("0.8.1"))], side: "B")
    defer { guest.close() }
    #expect(try p.roomEngine()["engine"]?.isNull == true)
    #expect(p.lobbyEngine() === p.engines.newest)
    #expect(try ids().contains("computer"))
    #expect(p.lobbyTakesScene())
    #expect(try p.roomOptions(p.pitch.document)["computer"] == "pro")
  }

  /// A new pitch the player hosts opens with what they last picked as a host (the web's
  /// `pitchOptions`), only what its engine takes; never a pitch with a document already.
  @Test func aNewPitchTheHostMakesOpensWithTheirLastOptions() async throws {
    let (p, pitch) = try await setup()
    defer { withExtendedLifetime(pitch) { p.close() } }  // the fake pitch lives as long as the test
    let kept = [
      "surface": "snow", "opening": "six", "raising": "auto", "wind": "light", "set": "sweden",
      "computer": "pro", "scene": "night", "first": "B", "wind2": "x",
    ]
    #expect(try p.takenOptions(kept).keys.sorted() == ["computer", "opening", "raising", "scene", "set", "surface", "wind"])
    #expect(try p.takenOptions(["wind": "gale", "computer": "legend"]).isEmpty)
    #expect(p.pitch.isHost && p.pitch.document == .null)
    #expect(try await p.prepareLobby(options: kept))
    let o = try p.roomOptions(p.pitch.document)
    #expect(o["surface"] == "snow" && o["opening"] == "six" && o["raising"] == "auto")
    #expect(o["wind"] == "light" && o["set"] == "sweden" && o["computer"] == "pro" && o["scene"] == "night")
    #expect(o["first"] == nil)
    #expect(try await p.prepareLobby(options: ["scene": "neon"]) == false)

  }

  @Test func aStartGivesTheComputerTheRoomsLevel() async throws {
    let (p, pitch) = try await setup()
    defer { withExtendedLifetime(pitch) { p.close() } }  // the fake pitch lives as long as the test
    try await p.joinTeam("A")
    _ = try await p.reduce("setOptions", fields: [("options", .object([("computer", .string("beginner"))]))])
    #expect(try await p.start(seed: 7, at: startAt))
    #expect(p.engine.minor == Engine.newest)
    #expect(try p.engine.call("snapshot").contains(#""computer":"beginner""#))
  }

  @Test func theJoinAnnouncesEveryEngineCarriedAndTheNewestAsThePitchsEngine() async throws {
    let (p, fake) = try await setup()
    defer { p.close() }
    let me = try #require(fake.links[0].sent.first { $0["t"]?.string == "join" }?["me"])
    #expect(me["engine"]?.string == Engine.newest + "+engines")
    #expect(me["engines"]?.items.compactMap(\.string) == Engine.carried)
    #expect(Engine.carried == [Engine.newest])  // the newest alone (docs/ENGINES.md)
    #expect(me["level"] == nil)  // a person has no level to send (engine 0.13)
    #expect(Engine.majorMinor(me["engine"]?.string) == Engine.newest)
  }

  /// An action names only its client (`c: "ios"`): nothing about the device.
  @Test func anActionNamesOnlyItsClient() async throws {
    let (p, fake) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    #expect(try await p.take(JSONText(#"{"type":"resign","side":"A"}"#)))
    let link = try #require(fake.links(of: "Native_Member").last)
    try await eventually { !link.sent("act").isEmpty }
    let act = try #require(link.sent("act").last)
    #expect(act.members.map(\.key) == ["t", "id", "n", "seq", "a", "h", "snap", "over", "c"])
    #expect(act["c"]?.string == "ios")
    let start = try #require(link.sent("start").last)
    #expect(try JSONNode.parse(start["meta"]!.raw)["client"] == nil)
  }

  @Test func aPlayerOnAnEngineThisBuildLacksStopsStartAndNothingIsWritten() async throws {
    let (p, fake) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    let guest = try await seat(p, fake, "Guest_01", me: [("name", .string("Old")), ("engine", .string("0.6"))], side: "B")
    defer { guest.close() }
    let chosen = try p.roomEngine()
    #expect(chosen["engine"]?.isNull == true)
    #expect(chosen["missing"]?.items.compactMap(\.string) == ["Guest_01"])
    let before = fake.v
    #expect(try await p.start(seed: 3, at: startAt) == false)
    #expect(p.state == .versionMismatch && p.match == nil && fake.match == nil && fake.v == before)
    let m = try JSONNode.parse(try #require(p.mismatch))
    #expect(m["differ"]?.items.compactMap(\.string) == ["Guest_01"])
    #expect(announced(fake) == Engine.newest + "+engines")
  }

  @Test func aStartOnAnEngineThisBuildLacksIsRefused() async throws {
    let (p, fake) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 5, at: startAt))
    let meta = try JSONNode.parse(fake.match!.meta)
    fake.startAs(
      "Member_X1", meta: PitchController.with(meta, [("engine", .string("0.6")), ("version", .string("0.6.0"))]).json, h: fake.match!.h,
      snap: fake.match!.snap)
    try await eventually { p.state == .versionMismatch }
    #expect(p.matchNumber == 2)
    #expect(try JSONNode.parse(try #require(p.mismatch))["why"]?.string == "differs")
  }

  /// A player on an engine this build no longer carries (an older iPhone build that
  /// announces several, or a web tab on 0.9 alone): the room has no engine, START is
  /// refused with nothing written, this member's engine and announcement stay the newest,
  /// and the player is the one named to update.
  @Test(arguments: ["older app", "older tab", "unnamed"])
  func aPlayerOnAnOlderEngineIsNamedAndNothingStarts(_ who: String) async throws {
    let engine: [(String, JS)] =
      switch who {
      case "older app":
        [("engine", .string("0.9+engines")), ("engines", .array([.string("0.9"), .string("0.8"), .string("0.7")]))]
      case "older tab": [("engine", .string("0.9.0"))]
      default: []  // a client from before engines were named
      }
    let (p, fake) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    let guest = try await seat(p, fake, "Guest_09", me: [("name", .string("Old"))] + engine, side: "B")
    defer { guest.close() }
    let chosen = try p.roomEngine()
    #expect(chosen["engine"]?.isNull == true)
    let named = ((chosen["missing"]?.items ?? []) + (chosen["unknown"]?.items ?? [])).compactMap(\.string)
    #expect(Set(named) == ["Guest_09"])
    let before = fake.v
    #expect(try await p.start(seed: 3, at: startAt) == false)
    #expect(p.state == .versionMismatch && p.match == nil && fake.match == nil && fake.v == before)
    #expect(p.engine.minor == Engine.newest && p.engines.loaded == [Engine.newest])
    #expect(announced(fake) == Engine.newest + "+engines")
  }

  /// A match a peer started on an engine this build no longer carries (0.9) is refused,
  /// never played: the version card's state, no seat, and the newest engine kept.
  @Test func aMatchOnAnOlderEngineIsNeverPlayedHere() async throws {
    let (p, fake) = try await setup()
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 5, at: startAt))
    let meta = try JSONNode.parse(fake.match!.meta)
    fake.startAs(
      "Member_X1", meta: PitchController.with(meta, [("engine", .string("0.9")), ("version", .string("0.9.0"))]).json,
      h: fake.match!.h, snap: fake.match!.snap)
    try await eventually { p.state == .versionMismatch }
    #expect(!p.mayAct && p.engine.minor == Engine.newest)
    let m = try JSONNode.parse(try #require(p.mismatch))
    #expect(m["why"]?.string == "differs" && m["match"]?.string == "0.9")
  }
}
