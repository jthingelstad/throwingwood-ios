import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// Names on a pitch (docs/ONLINE.md "Names", the web's docs/MULTIPLAYER.md "Names" and
/// PROTOCOL.md section 6a), as the controller speaks them: every name it shows, writes or
/// starts a match with is a generated name or a default.
@Suite @MainActor struct PitchNamesTests {
  /// A member with presence `me`, seated on `side` (nil: watching).
  func member(_ p: PitchController, _ fake: FakePitch, _ id: String, me: [(String, JS)], side: String?) async throws
    -> PitchClient
  {
    let guest = try makeClient(fake.factory, store: MemoryID(id))
    guest.setMe(me)
    guest.connect()
    try await guest.ready()
    try await eventually { p.pitch.members.contains { $0["id"]?.string == id } }
    if let side {
      _ = try await p.pitch.update { doc in
        try p.pitchCall("joinTeam", [("doc", .raw(doc)), ("id", .string(id)), ("side", .string(side))]).raw
      }
    }
    return guest
  }

  /// A typed name (an old build, or anyone sending their own messages) is shown as
  /// "Player n", n its place on its side (a watcher, its place on the pitch); two members
  /// with one name are told apart in the lobby ("II"), never renamed.
  @Test func aTypedNameIsShownAsPlayerNAndTwoAlikeApart() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try p.setMe(name: "Mighty Maple")
    try await p.joinTeam("A")
    let typed = try await member(p, fake, "Guest_Typed", me: [("name", .string("Ada"))], side: "A")
    let twin = try await member(p, fake, "Guest_Twin", me: [("name", .string("Mighty Maple"))], side: "B")
    let watcher = try await member(p, fake, "Guest_Watch", me: [("name", .string("Bad Words"))], side: nil)
    defer { [typed, twin, watcher].forEach { $0.close() } }
    try await eventually { p.pitch.members.count == 4 }
    let shown = p.shownNames()
    #expect(shown.plain["Guest_Typed"] == "Player 2")  // second on side A
    #expect(shown.plain["Guest_Watch"] == "Player 4")  // fourth on the pitch
    #expect(shown.plain["Native_Member"] == "Mighty Maple" && shown.plain["Guest_Twin"] == "Mighty Maple")
    #expect(shown.apart["Native_Member"] == "Mighty Maple" && shown.apart["Guest_Twin"] == "Mighty Maple II")
    #expect(p.nameOf("Guest_Typed") == "Player 2")
  }

  /// This member never sends a name the game did not make.
  @Test func aTypedNameIsNeverSent() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try p.setMe(name: "Ada")
    try p.setMe(name: "Lucky Larch")
    func sent() -> [String] {
      fake.links(of: "Native_Member").flatMap { $0.sent }.compactMap { $0["me"]?["name"]?.string }
    }
    try await eventually { !sent().isEmpty }
    #expect(sent() == ["Lucky Larch"])
  }

  /// A side of several plays under a team name the host rolls in the lobby, in the
  /// document's top-level `teamNames` (the web's setTeamName); only a generated team name
  /// is written.
  @Test func theHostRollsATeamNameForASideOfSeveral() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try p.setMe(name: "Mighty Maple")
    try await p.joinTeam("A")
    #expect(try await p.rollTeamNames() == nil)  // a side of one plays under its player
    let guest = try await member(p, fake, "Guest_A2", me: [("name", .string("Lucky Larch"))], side: "A")
    defer { guest.close() }
    let rolled = try #require(try await p.rollTeamNames())
    #expect(p.names.valid(.team, rolled).ok)
    let doc = try JSONNode.parse(p.pitch.document)
    #expect(doc["teamNames"]?["A"]?.string == rolled && doc["teamNames"]?["B"] == nil)
    #expect(p.teamNameOf("A") == rolled && p.teamNameOf("B") == "Team B")
    #expect(try await p.rollTeamNames() == nil)  // once
    #expect(try await p.setTeamName("A", "Ada's Team") == false)
    #expect(try await p.setTeamName("A", "Birch Batons"))
    #expect(p.teamNameOf("A") == "Birch Batons")
  }

  /// START takes only names that pass: a typed player name becomes "Player n", and a side
  /// of several plays under the lobby's team name, so the pitch server never refuses it.
  @Test func startTakesOnlyNamesThatPass() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try p.setMe(name: "Mighty Maple")
    try await p.joinTeam("A")
    let guest = try await member(
      p, fake, "Guest_Typed", me: [("name", .string("Ada")), ("engine", .string(Engine.newest))], side: "A")
    defer { guest.close() }
    #expect(try await p.setTeamName("A", "Birch Batons"))
    #expect(try await p.start(seed: 1001, at: startAt))
    let meta = try JSONNode.parse(try #require(fake.match).meta)
    let names = meta["players"]?["A"]?.items.compactMap { $0["name"]?.string }
    #expect(names == ["Mighty Maple", "Player 2"])
    #expect(meta["setup"]?["teams"]?["A"]?["name"]?.string == "Birch Batons")
    #expect(p.names.badNames(snapshot: fake.match!.snap).isEmpty)
    #expect(p.names.badNames(setup: meta["setup"]).isEmpty)
  }

  /// A match whose snapshot names a name the game did not make (a forged start) is never
  /// shown or played here.
  @Test func aMatchWithATypedNameIsRefused() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 5, at: startAt))
    let forged = try Engine(appVersion: "0.0-test")
    _ = try forged.call(
      "new",
      json:
        #"{"mode":"match","seed":3,"first":"A","teams":{"A":{"name":"Ada","players":[{"name":"Ada"}]},"B":{"name":"Computer","players":[{"name":"Computer"}]}},"cpu":"B"}"#)
    var presented = 0
    p.present = { _ in presented += 1 }
    fake.startAs("Member_X1", meta: fake.match!.meta, h: try forged.hash(), snap: try forged.call("snapshot"))
    try await eventually { p.state == .namesRefused }
    #expect(!p.mayAct && presented == 0)
  }
}
