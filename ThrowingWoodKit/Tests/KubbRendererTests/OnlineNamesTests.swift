import Foundation
import KubbEngine
import Testing

@testable import KubbPitch
@testable import KubbRenderer

// The app's online screen on the in-process pitch server (Pitch/FakePitch.swift, the
// KubbPitch tests' own, linked here).

@MainActor private final class TestID: MemberIDStore {
  var id: String?
  init(_ id: String) { self.id = id }
  func load() -> String? { id }
  func save(_ id: String) { self.id = id }
}

@MainActor private func soon(_ test: () -> Bool) async throws {
  for _ in 0..<3000 {
    if test() { return }
    try await Task.sleep(for: .milliseconds(2))
  }
  throw PitchError("test-timeout")
}

private func quick() -> PitchClient.Timing {
  var t = PitchClient.Timing()
  t.firstRetry = .milliseconds(2)
  t.retry = .milliseconds(2)
  t.retryMax = .milliseconds(5)
  t.answer = .seconds(600)
  t.ping = .seconds(600)
  return t
}

@Suite @MainActor struct OnlineNamesTests {
  /// Codex's sequence: a watch-only match on an engine this build does not carry, whose
  /// snapshot is the forgery (`save.game.teams.A.name` typed), is refused by the board's
  /// strict door; a later refresh of the pitch (someone joins) keeps "Cannot show this
  /// match" for that match, and the lobby lets it go.
  @Test func aWatchOnlyForgedMatchStaysRefusedThroughARefresh() async throws {
    let fake = FakePitch()
    let host = try PitchController(
      pitch: PitchClient(
        url: URL(string: "ws://127.0.0.1:1")!, pitch: fake.code, appVersion: "0.0-test",
        store: TestID("Host_Member"), timing: quick(), factory: fake.factory),
      engines: EngineShelf(appVersion: "0.0-test"))
    defer { host.close() }
    host.connect()
    try await host.pitch.ready()
    try await host.joinTeam("A")
    #expect(try await host.start(seed: 5, at: JSONText(#"{"year":2026,"month":11,"day":17,"hour":12,"min":0}"#)))

    let online = try OnlinePitch(
      url: URL(string: "ws://127.0.0.1:1")!, link: try #require(PitchLink(fake.code)), create: false,
      name: "Brave Birch", appVersion: "0.0-test", store: TestID("Watch_Member"), timing: quick(),
      defaults: UserDefaults(suiteName: "online-\(UUID().uuidString)")!, factory: fake.factory)
    defer { online.close() }
    online.connect()
    try await soon { online.stage == .match }

    // the next match: on 0.9 (not carried here), its snapshot the forgery
    var d = try JSONSerialization.jsonObject(with: Data(fake.match!.snap.utf8)) as! [String: Any]
    var save = d["save"] as! [String: Any], game = save["game"] as! [String: Any]
    var teams = game["teams"] as! [String: Any], a = teams["A"] as! [String: Any]
    a["name"] = "Typed Team"
    teams["A"] = a
    game["teams"] = teams
    save["game"] = game
    d["save"] = save
    let forged = String(decoding: try JSONSerialization.data(withJSONObject: d), as: UTF8.self)
    let meta = PitchController.with(
      try JSONNode.parse(fake.match!.meta), [("engine", .string("0.9")), ("version", .string("0.9.0"))]
    ).json
    fake.startAs("Member_X1", meta: meta, h: fake.match!.h, snap: forged)
    try await soon { online.controller.state == .versionMismatch && online.stage == .namesRefused }

    // a refresh of the pitch: another member joins
    let guest = try PitchClient(
      url: URL(string: "ws://127.0.0.1:1")!, pitch: fake.code, appVersion: "0.0-test",
      store: TestID("Guest_Member"), timing: quick(), factory: fake.factory)
    defer { guest.close() }
    guest.connect()
    try await guest.ready()
    try await soon { online.pitch.members.count == 3 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(online.stage == .namesRefused)
    // back to the lobby: the refusal was that match's alone
    let n = try #require(try JSONNode.parse(host.pitch.document)["match"]?["n"]?.int)
    #expect(try await host.reduce("backToLobby", fields: [("n", .int(n))]))
    try await soon { online.stage == .lobby }
  }
}

/// The lobby's rows are the engine's card for the room's scene (engine 0.14,
/// `optionRows`): Scene first, Surface only where the scene leaves one, no Kubbs row (the
/// scene decides the set; the web's HIDDEN_ROWS). Every write names the scene, so the
/// pitch holds the ground and the set to it.
@Suite @MainActor struct LobbyRowsTests {
  @Test func theLobbyIsTheScenesCard() async throws {
    let fake = FakePitch()
    let online = try OnlinePitch(
      url: URL(string: "ws://127.0.0.1:1")!, link: try #require(PitchLink(fake.code)), create: true,
      name: "Brave Birch", appVersion: "0.0-test", store: TestID("Host_Member"), timing: quick(),
      defaults: UserDefaults(suiteName: "lobby-\(UUID().uuidString)")!, factory: fake.factory)
    defer { online.close() }
    online.connect()
    try await soon { online.stage == .lobby && online.isHost && !online.optionRows.isEmpty }
    #expect(online.optionRows.map(\.id) == ["scene", "computer", "opening", "raising", "wind"])
    #expect(online.optionRows.first { $0.id == "computer" }?.choices.first?.first == "kid")
    #expect(OnlinePitch.hiddenRows == ["set"])
    #expect(online.options["set"] == "classic")
    // a set the scene does not allow is held to the scene's
    try await online.option("set", "usa")
    try await Task.sleep(for: .milliseconds(50))
    #expect(online.options["set"] == "classic")
    // the Tournament brings the USA set, Black & White a Surface row
    try await online.option("scene", "tournament")
    try await soon { online.options["scene"] == "tournament" }
    #expect(online.options["set"] == "usa" && online.options["surface"] == "grass")
    try await online.option("scene", "bw")
    try await soon { online.optionRows.map(\.id).contains("surface") }
    #expect(online.optionRows.map(\.id) == ["scene", "surface", "computer", "opening", "raising", "wind"])
    try await online.option("surface", "snow")
    try await soon { online.options["surface"] == "snow" }
    #expect(online.options["scene"] == "bw" && online.options["set"] == "classic")
    #expect(!online.optionRows.map(\.id).contains("set"))
  }
}
