import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// Observers (the web's docs/OBSERVER.md, PROTOCOL.md section 3): a member with the
/// `observer` role, no seat, that never acts, writes the document, casts or hosts. The
/// pitch decides the host; an observer has nothing to step back from.
@Suite @MainActor struct ObserverTests {
  @Test func anObserverJoinsAsOneAndNeverActsWritesOrCasts() async throws {
    let fake = FakePitch()
    let host = try await player(fake, "Host_0001")
    defer { host.close() }
    try await host.joinTeam("A")
    #expect(try await host.start(seed: 7, at: startAt))
    let p = try await player(fake, "Watcher_01", observing: true)
    defer { p.close() }
    try await eventually { p.state == .match }
    #expect(fake.links(of: "Watcher_01")[0].sent[0]["role"]?.string == "observer")
    #expect(fake.members["Watcher_01"]?.role == "observer")
    #expect(!p.mayAct && !p.pitch.isHost)
    #expect(try JSONNode.parse(p.control)["sides"]?.items.isEmpty == true)
    #expect(try JSONNode.parse(p.control)["cpu"]?.bool == false)
    #expect(try hash(p) == hash(host))
    // nothing it may write: no action, no frame, no lobby, no options, no start, no shout
    #expect(try await p.take(JSONText(#"{"type":"resign","side":"A"}"#)) == false)
    #expect(try await p.frame(JSONText(#"{"dt":0.016}"#)) == nil)
    #expect(try await p.prepareLobby(options: ["scene": "night"]) == false)
    await #expect(throws: PitchError.self) { try await p.joinTeam("A") }
    await #expect(throws: PitchError.self) { try await p.reduce("setOptions", fields: []) }
    #expect(try await p.start(seed: 1, at: startAt) == false)
    #expect(p.shout(.phrase("NICE!")) == false && p.shout(.emoji("🔥")) == false)
    try p.castAim(now: 10_000)
    #expect(!p.pitch.cast(JSONText("{}")))
    p.pitch.act(id: "never-1", n: 1, seq: 1, a: JSONText("{}"), h: "h", snap: "s", over: false)
    // the host away for a minute changes nothing: the pitch hands the host on, not it
    fake.links(of: "Host_0001").last!.swallow = true
    p.tick(now: 0)
    p.tick(now: 60_000)
    // it watches the host's play
    fake.links(of: "Host_0001").last!.swallow = false
    let action = try #require(try scriptedThrow(host))
    #expect(try await host.take(action))
    try await eventually { p.sequence == 1 }
    #expect(try hash(p) == hash(host))
    let sent = fake.links(of: "Watcher_01").flatMap(\.sent).compactMap { $0["t"]?.string }
    #expect(Set(sent).isSubset(of: ["join", "me", "ping"]))
  }

  /// Casts reach an observer; its own aim is shown 100 ms behind (OnlinePitch's buffer).
  @Test func anObserverGetsTheThrowersAim() async throws {
    let fake = FakePitch()
    let host = try await player(fake, "Host_0001")
    defer { host.close() }
    try await host.joinTeam("A")
    #expect(try await host.start(seed: 7, at: startAt))
    let p = try await player(fake, "Watcher_01", observing: true)
    defer { p.close() }
    try await eventually { p.state == .match }
    try host.castAim(JSONText(#"{"seq":0,"x":1}"#), final: true, now: 5_000)
    try await eventually { p.lastCast != nil }
    let cast = try JSONNode.parse(try #require(p.lastCast))
    #expect(cast["m"]?.string == "Host_0001" && cast["d"]?["s"]?["x"]?.int == 1 && cast["ts"]?.int != nil)
  }

  /// A watcher joins with an id of its own, never the player's: the pitch gives a join
  /// with a known id that member's place (and its role is fixed while it is on the
  /// pitch), so a host watching its own pitch under the player's id would stall it.
  @Test func aWatcherJoinsWithAnIdOfItsOwnAndNeverTakesTheHostsPlace() async throws {
    let fake = FakePitch()
    let host = try await player(fake, "Host_0001")
    defer { host.close() }
    let playerID = MemoryID("Host_0001")  // this device hosts the pitch
    let watcherID = MemoryID(nil)
    let store = playerID.joining(observing: true, observer: watcherID)
    #expect(playerID.joining(observing: false, observer: watcherID).load() == "Host_0001")
    let pitch = try makeClient(fake.factory, store: store, observing: true)
    defer { pitch.close() }
    pitch.connect()
    try await pitch.ready()
    #expect(pitch.you != "Host_0001" && watcherID.id == pitch.you && playerID.id == "Host_0001")
    #expect(!pitch.isHost && fake.host == "Host_0001" && host.pitch.status == .open)
    // a watcher's id that somehow matched the player's is never used
    #expect(MemoryID("Host_0001").joining(observing: true, observer: MemoryID("Host_0001")).load() == nil)
    #expect(ObserverMemberIDStore().load() == nil)
  }
}

/// The Open games list (the web's public/js/open-games.js, the pitch server's `GET /open`).
@Suite @MainActor struct OpenGamesTests {
  let reply = #"{"now":1000000,"games":[{"pitch":"abcdefghjk","made":760000,"age":240000,"players":3,"watchers":1,"seats":12,"state":"playing"},{"pitch":"NOT-A-CODE","made":0,"players":1,"seats":12,"state":"waiting"},{"pitch":"mnpqrstuvw","made":999000,"age":1000,"players":1,"watchers":0,"seats":12,"state":"waiting"}]}"#

  @Test func theListDecodesInOrderAndLeavesOutBadCodes() throws {
    let out = try #require(OpenGames.decode(JSONNode.parse(reply), fallback: 0))
    #expect(out.now == 1_000_000)
    #expect(out.games.map(\.pitch) == ["abcdefghjk", "mnpqrstuvw"])
    #expect(out.games[0] == OpenGame(pitch: "abcdefghjk", made: 760_000, players: 3, seats: 12, state: "playing"))
    #expect(try OpenGames.decode(JSONNode.parse(#"{"error":"x"}"#), fallback: 0) == nil)
    let noClock = try #require(OpenGames.decode(JSONNode.parse(#"{"games":[]}"#), fallback: 42))
    #expect(noClock.now == 42 && noClock.games.isEmpty)
  }

  /// PROTOCOL.md section 5's example answer.
  @Test func theProtocolsExampleDecodes() throws {
    let example = #"{"now":1795280938959,"games":[{"pitch":"k7mpq2rstw","made":1795280000000,"age":938959,"players":3,"watchers":1,"seats":12,"state":"waiting"}]}"#
    let out = try #require(OpenGames.decode(JSONNode.parse(example), fallback: 0))
    #expect(out.games == [OpenGame(pitch: "k7mpq2rstw", made: 1_795_280_000_000, players: 3, seats: 12, state: "waiting")])
  }

  @Test func aRowSaysHowManyWhetherItPlaysAndWhenItWasMade() throws {
    let out = try #require(OpenGames.decode(JSONNode.parse(reply), fallback: 0))
    #expect(OpenGames.line(out.games[0], now: out.now) == "3 of 12 on the pitch · in play · made 4 min ago")
    #expect(OpenGames.line(out.games[1], now: out.now) == "1 of 12 on the pitch · waiting to start · made just now")
    #expect(OpenGames.ago(60 * 60_000) == "made 1 hour ago")
    #expect(OpenGames.ago(3 * 60 * 60_000 + 5) == "made 3 hours ago")
    #expect(OpenGames.ago(-5) == "made just now")
    #expect(OpenGames.intro.contains("Join one and pick a side, or watch a match."))
  }

  @Test func theListIsThePitchServersOpenOverHTTPS() {
    #expect(OpenGames.listURL(URL(string: "wss://pitches.example.test")!).absoluteString == "https://pitches.example.test/open")
    #expect(OpenGames.listURL(URL(string: "ws://127.0.0.1:8797")!).absoluteString == "http://127.0.0.1:8797/open")
  }

  @Test func aLookIsOneGetAndAnErrorThrows() async throws {
    let reply = reply
    let seen = Box<URLRequest>()
    let out = try await PitchAPI.openGames(
      server: URL(string: "ws://127.0.0.1:8797")!, appVersion: "0.0-test",
      fetch: { request in
        await seen.set(request)
        return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      })
    #expect(out.games.count == 2)
    let request = try #require(await seen.value)
    #expect(request.httpMethod ?? "GET" == "GET" && request.url?.absoluteString == "http://127.0.0.1:8797/open")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ThrowingWood/0.0-test (ios)")
    await #expect(throws: PitchError.self) {
      _ = try await PitchAPI.openGames(
        server: URL(string: "ws://127.0.0.1:8797")!, appVersion: "0.0-test",
        fetch: { request in
          (Data(#"{"error":"busy","message":"Busy."}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
    }
  }
}

/// A value a `@Sendable` fetch hands back to the test.
actor Box<T: Sendable> {
  var value: T?
  func set(_ v: T) { value = v }
}
