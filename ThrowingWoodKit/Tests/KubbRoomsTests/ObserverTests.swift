import Foundation
import KubbEngine
import Testing

@testable import KubbRooms

/// Observers (the web's docs/OBSERVER.md): a member with no seat that never acts, never
/// writes the document, never claims host, and steps back when first in line.
@Suite @MainActor struct ObserverTests {
  let at = JSONText(#"{"year":2026,"month":11,"day":17,"hour":12,"min":0}"#)

  /// The room as an observer joining finds it: a host that is away, this member, and
  /// another member connected after it (`others`), at document version `v`.
  static func joined(v: Int, doc: String = "null", hostConnected: Bool = false, others: Bool = true) -> String {
    var members = [
      #"{"id":"Host_0001","connected":\#(hostConnected),"joined":0,"me":{"name":"Host"}}"#,
      #"{"id":"Native_Member","connected":true,"joined":1,"me":{"name":"Watcher"}}"#,
    ]
    if others { members.append(#"{"id":"Other_001","connected":true,"joined":2,"me":{"name":"Other"}}"#) }
    return
      #"{"t":"joined","room":"abcdefghjk","host":"Host_0001","rev":1,"members":[\#(members.joined(separator: ","))],"v":\#(v),"doc":\#(doc),"by":"Host_0001","limits":{"frame":30000}}"#
  }

  /// An observer's controller on a room of `joined`, each socket a new mock.
  func observer(_ joined: String) async throws -> (PitchController, () -> [MockTransport]) {
    var transports: [MockTransport] = []
    let engine = try Engine(appVersion: "0.0-test")
    let room = try makeClient(
      { _ in
        let t = MockTransport()
        transports.append(t)
        t.onSend = { m in if m["t"]?.string == "join" { t.push(joined) } }
        return t
      }, engineVersion: engine.engineVersion)
    let p = try PitchController(room: room, engine: engine, observing: true)
    room.connect()  // the wire only: the test drives the clock (tick(now:))
    try await room.ready()
    return (p, { transports })
  }

  func sent(_ ts: [MockTransport], _ type: String) -> [JSONNode] {
    ts.flatMap(\.sent).filter { $0["t"]?.string == type }
  }

  @Test func stepBackWaitsDoubleFromTwentySecondsToFiveMinutes() {
    #expect(StepBack.delay(0) == 0)
    #expect(StepBack.delay(1) == 20_000)
    #expect(StepBack.delay(2) == 40_000)
    #expect(StepBack.delay(3) == 80_000)
    #expect(StepBack.delay(5) == 300_000)
    #expect(StepBack.delay(99) == 300_000)
  }

  @Test func theFirstStepBackIsAtOnceThenItBacksOff() {
    var s = StepBack()
    #expect(s.due(1000))
    s.took(1000)
    #expect(!s.due(1000 + 19_999))
    #expect(s.wait(at: 1000 + 15_000) == 5000)
    #expect(s.due(1000 + 20_000))
    s.took(21_000)
    #expect(!s.due(21_000 + 39_999))
    #expect(s.due(21_000 + 40_000))
    // a host connected: from the first again
    s.reset()
    #expect(s.due(21_001))
  }

  @Test func aMemberNeverSeenStartsItAgainButTheFirstLookAndOwnRejoinsDoNot() {
    var s = StepBack()
    let first = s.see(["Native_Member", "Other_001"])
    #expect(!first)  // the first look is not an arrival
    s.took(0)
    s.took(20_000)
    #expect(s.steps == 2)
    let again = s.see(["Native_Member", "Other_001"])
    #expect(!again)  // the same ids: its own rejoin
    #expect(s.steps == 2)
    let fresh = s.see(["Native_Member", "Newcomer_1"])
    #expect(fresh)
    #expect(s.steps == 0 && s.due(20_001))
  }

  @Test func anObserversSeatHasNoSideAndItNeverActsOrWrites() async throws {
    // a running match on the pitch, from a host on another device
    let host = try Engine(appVersion: "0.0-test")
    let room0 = try makeClient({ _ in MockTransport() }, engineVersion: host.engineVersion)
    let p0 = try PitchController(room: room0, engine: host)
    let lineup = JSONText(#"{"players":{"A":["Host_0001"],"B":[]},"cpu":"B"}"#)
    let opts = try p0.roomCall(
      "matchOptions",
      [("doc", .raw(p0.roomCall("lobbyOf", [("doc", .null)]).raw)), ("lineup", .raw(lineup)), ("seed", .int(7)), ("start", .raw(at))])
    _ = try host.call(
      "new", json: JS.object(opts.members.map { ($0.key, JS.raw($0.value.raw)) } + [("mode", .string("match"))]).ascii)
    let started = try p0.roomCall(
      "startMatch",
      [
        ("doc", .raw(p0.roomCall("lobbyOf", [("doc", .null)]).raw)), ("snap", .string(host.call("snapshot"))),
        ("hash", .string(host.hash())), ("players", .raw(JSONText(#"{"A":["Host_0001"],"B":[]}"#))),
        ("cpu", .string("B")), ("host", .string("Host_0001")), ("setup", .raw(opts.raw)),
        ("members", .raw(JSONText("[]"))),
      ])
    room0.close()
    let (p, transports) = try await observer(Self.joined(v: 4, doc: started.raw.text, hostConnected: true))
    defer { p.close() }
    try await eventually { p.state == .match }
    #expect(p.mayAct == false)
    #expect(try JSONNode.parse(p.control)["sides"]?.items.isEmpty == true)
    #expect(try JSONNode.parse(p.control)["cpu"]?.bool == false)
    #expect(p.playingSide == nil || p.observing)
    // nothing it may write: no action, no frame, no lobby, no options, no start, no shout
    #expect(try await p.take(JSONText(#"{"type":"resign","side":"A"}"#)) == false)
    #expect(try await p.frame(JSONText(#"{"dt":0.016}"#)) == nil)
    #expect(try await p.prepareLobby(options: ["scene": "night"]) == false)
    await #expect(throws: RoomError.self) { try await p.joinTeam("A") }
    await #expect(throws: RoomError.self) { try await p.reduce("setOptions", fields: []) }
    #expect(try await p.start(seed: 1, at: at) == false)
    #expect(p.shout("NICE!") == false)
    try p.castAim(now: 10_000)
    try await Task.sleep(for: .milliseconds(100))
    #expect(sent(transports(), "set").isEmpty)
    #expect(sent(transports(), "cast").isEmpty)
  }

  @Test func anObserverFirstInLineStepsBackAndNeverClaims() async throws {
    let (p, transports) = try await observer(Self.joined(v: 1))
    defer { p.close() }
    let t0 = 1_000_000
    p.tick(now: t0)  // the host is gone from here
    p.tick(now: t0 + 15_999)
    #expect(sent(transports(), "leave").isEmpty)
    p.tick(now: t0 + 16_000)  // first in line, someone else here: a step back at once
    try await eventually { sent(transports(), "leave").count == 1 }
    #expect(p.stepBacks == 1)
    #expect(sent(transports(), "claim").isEmpty)
    // and it joins again with the same member id, last in line
    try await eventually { transports().count == 2 && p.room.status == .open }
    let joins = sent(transports(), "join")
    #expect(joins.count == 2 && joins.allSatisfy { $0["member"]?.string == "Native_Member" })
    // still first in line (the server here answers as before): it waits 20 s
    p.tick(now: t0 + 17_000)
    p.tick(now: t0 + 16_000 + 19_999)
    #expect(p.stepBacks == 1)
    p.tick(now: t0 + 16_000 + 20_000)
    #expect(p.stepBacks == 2)
    #expect(sent(transports(), "claim").isEmpty)
  }

  @Test func aloneWithAnAwayHostItStaysAndClaimsNothing() async throws {
    let (p, transports) = try await observer(Self.joined(v: 1, others: false))
    defer { p.close() }
    p.tick(now: 0)
    p.tick(now: 60_000)
    try await Task.sleep(for: .milliseconds(100))
    #expect(sent(transports(), "leave").isEmpty)
    #expect(sent(transports(), "claim").isEmpty)
    #expect(p.stepBacks == 0)
  }

  @Test func aConnectedHostStartsTheWaitFromTheFirstAgain() async throws {
    let (p, transports) = try await observer(Self.joined(v: 1))
    defer { p.close() }
    p.tick(now: 0)
    p.tick(now: 16_000)
    #expect(p.stepBacks == 1 && p.stepping.steps == 1)
    try await eventually { transports().count == 2 && p.room.status == .open }
    p.room.receive(#"{"t":"member","rev":5,"member":{"id":"Host_0001","connected":true,"joined":0,"me":{}}}"#)
    p.tick(now: 17_000)
    #expect(p.stepping.steps == 0)
  }

  @Test func aPlayerFirstInLineClaimsAsBefore() async throws {
    var transports: [MockTransport] = []
    let engine = try Engine(appVersion: "0.0-test")
    let room = try makeClient(
      { _ in
        let t = MockTransport()
        transports.append(t)
        t.onSend = { m in if m["t"]?.string == "join" { t.push(Self.joined(v: 1)) } }
        return t
      }, engineVersion: engine.engineVersion)
    let p = try PitchController(room: room, engine: engine)
    defer { p.close() }
    room.connect()
    try await room.ready()
    p.tick(now: 0)
    p.tick(now: 16_000)
    try await eventually { sent(transports, "claim").count == 1 }
    #expect(sent(transports, "leave").isEmpty)
  }

  @Test func rejoinLeavesThenJoinsAgainWithTheSameMember() async throws {
    var transports: [MockTransport] = []
    let room = try makeClient { _ in
      let t = MockTransport()
      transports.append(t)
      t.onSend = { m in if m["t"]?.string == "join" { t.joined() } }
      return t
    }
    defer { room.close() }
    room.connect()
    try await room.ready()
    #expect(room.rejoin(settle: .milliseconds(5), again: .milliseconds(5)))
    #expect(room.status == .reconnecting)
    try await eventually { transports.count == 2 && room.status == .open }
    #expect(transports[0].sent.last?["t"]?.string == "leave")
    #expect(transports[0].closed)
    #expect(transports[1].sent.first?["t"]?.string == "join")
    #expect(transports[1].sent.first?["member"]?.string == room.you)
    room.close()
    #expect(room.rejoin() == false)
  }

  /// The web's review finding: a watcher joins with an id of its own, never the
  /// player's. The room gives a join with a known id that member's place, so a host who
  /// watched its own pitch under the player's id came back as a host that never acts.
  @Test func aWatcherJoinsWithAnIdOfItsOwnAndNeverTakesTheHostsPlace() async throws {
    let player = MemoryID("Host_0001")  // this device hosts the pitch
    let watcher = MemoryID(nil)
    let store = player.joining(observing: true, observer: watcher)
    #expect(player.joining(observing: false, observer: watcher).load() == "Host_0001")
    // the room: a known id gets its own place back, the host's among them
    var transports: [MockTransport] = []
    let engine = try Engine(appVersion: "0.0-test")
    let room = try makeClient(
      { _ in
        let t = MockTransport()
        transports.append(t)
        t.onSend = { m in
          guard m["t"]?.string == "join", let id = m["member"]?.string else { return }
          var members = [#"{"id":"Host_0001","connected":\#(id == "Host_0001"),"joined":0,"me":{"name":"Host"}}"#]
          if id != "Host_0001" { members.append(#"{"id":"\#(id)","connected":true,"joined":1,"me":{"name":"Watcher"}}"#) }
          t.push(
            #"{"t":"joined","room":"abcdefghjk","host":"Host_0001","rev":1,"members":[\#(members.joined(separator: ","))],"v":0,"doc":null,"by":"Host_0001","limits":{"frame":30000}}"#
          )
        }
        return t
      }, store: store, engineVersion: engine.engineVersion)
    defer { room.close() }
    let p = try PitchController(room: room, engine: engine, observing: true)
    room.connect()
    try await room.ready()
    #expect(room.you != "Host_0001")
    #expect(watcher.id == room.you)  // kept for the app's run, in the watcher's own store
    #expect(player.id == "Host_0001")  // the player's id is untouched
    #expect(transports[0].sent.first?["member"]?.string == room.you)
    #expect(!room.isHost && !p.mayAct)
    // stepping back keeps the watcher's id
    #expect(room.rejoin(settle: .milliseconds(5), again: .milliseconds(5)))
    try await eventually { transports.count == 2 && room.status == .open }
    #expect(transports[1].sent.first?["member"]?.string == room.you)
    #expect(!room.isHost)
    // a watcher's id that somehow matched the player's is never used
    #expect(MemoryID("Host_0001").joining(observing: true, observer: MemoryID("Host_0001")).load() == nil)
    #expect(ObserverMemberIDStore().load() == nil)
  }
}

/// The Open games list (the web's public/js/open-games.js): its decode, words and look.
@Suite @MainActor struct OpenGamesTests {
  let reply = #"{"t":"list","now":1000000,"games":[{"room":"abcdefghjk","made":760000,"players":3,"seats":12,"state":"playing"},{"room":"NOT-A-CODE","made":0,"players":1,"seats":12,"state":"lobby"},{"room":"mnpqrstuvw","made":999000,"players":1,"seats":12,"state":"lobby"}]}"#

  @Test func theListDecodesInOrderAndLeavesOutBadCodes() throws {
    let out = try #require(OpenGames.decode(JSONNode.parse(reply), fallback: 0))
    #expect(out.now == 1_000_000)
    #expect(out.games.map(\.room) == ["abcdefghjk", "mnpqrstuvw"])
    #expect(out.games[0] == OpenGame(room: "abcdefghjk", made: 760_000, players: 3, seats: 12, state: "playing"))
    #expect(OpenGames.decode(try JSONNode.parse(#"{"t":"error","code":"x"}"#), fallback: 0) == nil)
    let noClock = try #require(OpenGames.decode(JSONNode.parse(#"{"t":"list","games":[]}"#), fallback: 42))
    #expect(noClock.now == 42 && noClock.games.isEmpty)
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

  @Test func aLookSendsListAndReadsTheAnswer() async throws {
    let t = MockTransport()
    t.onSend = { [reply] m in if m["t"]?.string == "list" { t.push(reply) } }
    var timing = RoomsClient.Timing()
    timing.answer = .seconds(2)
    let out = try await OpenGames.look(transport: t, timing: timing)
    #expect(out.games.count == 2)
    #expect(t.sent.count == 1 && t.sent[0]["t"]?.string == "list" && t.sent[0]["id"]?.int == 1)
    #expect(t.sent[0]["member"] == nil)
    #expect(t.closed)
  }

  @Test func anErrorAnswerThrows() async throws {
    let t = MockTransport()
    t.onSend = { m in if m["t"]?.string == "list" { t.push(#"{"t":"error","code":"busy"}"#) } }
    await #expect(throws: RoomError.self) { _ = try await OpenGames.look(transport: t, timing: RoomsClient.Timing()) }
  }
}
