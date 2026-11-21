import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// The real client and controllers over real sockets against the pitch server's own
/// `wrangler dev` on this machine (the web repository's backend/pitch-server, `npm run
/// dev`). Off unless `PITCH_LOCAL_URL` names it, and only ever on 127.0.0.1: never a
/// deployed pitch server. Invented member ids and a random code each run.
/// The local pitch server's address, or nil: only a `ws:` address on 127.0.0.1.
let localPitchServer: URL? = {
  guard let text = ProcessInfo.processInfo.environment["PITCH_LOCAL_URL"], let url = URL(string: text),
    url.scheme == "ws", url.host == "127.0.0.1"
  else { return nil }
  return url
}()

@Suite(.enabled(if: localPitchServer != nil), .serialized) @MainActor
struct LocalPitchServerTests {
  static func code() -> String {
    String((0..<10).map { _ in "23456789abcdefghjkmnpqrstuvwxyz".randomElement()! })
  }

  func member(_ code: String, _ id: String, observing: Bool = false, create: Bool = false) async throws
    -> PitchController
  {
    var timing = PitchClient.Timing()
    timing.answer = .seconds(20)
    let pitch = try PitchClient(
      url: localPitchServer!, pitch: code, appVersion: "0.0-test", me: [("name", .string(id))],
      store: MemoryID(id), observing: observing, create: create, timing: timing)
    let p = try PitchController(pitch: pitch, engines: EngineShelf(appVersion: "0.0-test"))
    p.connect()
    try await pitch.ready()
    return p
  }

  func patiently(_ test: () throws -> Bool) async throws {
    for _ in 0..<1500 {
      if (try? test()) == true { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw PitchError("test-timeout")
  }

  /// Two players on opposite teams, a watcher arriving mid-match and a player away for
  /// two actions: every action applied (not adopted) and every hash the same; the match
  /// ends with `over` and everyone holds the same finished replay.
  @Test func twoPlayersAndAWatcherPlayInStep() async throws {
    let code = Self.code()
    let a = try await member(code, "Local_Host_0001", create: true)
    defer { a.close() }
    #expect(a.pitch.isHost)
    #expect(try await a.prepareLobby(options: [:]))
    try await a.joinTeam("A")
    let b = try await member(code, "Local_Guest_002")
    defer { b.close() }
    try await b.joinTeam("B")
    try await patiently { try a.roomEngine()["engine"]?.string != nil && b.pitch.version == a.pitch.version }
    #expect(try await a.start(seed: 1001, at: startAt))
    try await patiently { b.state == .match }
    #expect(try hash(a) == hash(b))
    let header = try JSONNode.parse(b.pitch.document)["match"]
    #expect(header?.members.map(\.key) == ["n", "players", "cpu", "host", "engine"])

    var made = 0
    var awayAt: Int?
    var watcher: PitchController?
    defer { watcher?.close() }
    while made < 10 {
      let actor = a.mayAct ? a : b
      guard actor.mayAct, let action = try scriptedThrow(actor) else { break }
      // the guest goes away (as the app does in the background) while the host acts
      if awayAt == nil, made >= 2, actor === a {
        b.pitch.close()
        awayAt = made
      }
      #expect(try await actor.take(action))
      made += 1
      // back after two actions, or when it is the guest's turn: it resumes by sequence
      if let at = awayAt, b.pitch.status == .closed, made - at >= 2 || !a.mayAct { b.connect() }
      if made == 5 { watcher = try await member(code, "Local_Watch_003", observing: true) }
      let away = b.pitch.status == .closed
      try await patiently {
        a.outstanding.isEmpty && a.sequence == made
          && (away || (b.pitch.status == .open && b.outstanding.isEmpty && b.sequence == made))
      }
      if !away { #expect(try hash(a) == hash(b)) }
    }
    #expect(awayAt != nil)
    #expect(made >= 6)
    #expect(a.corrections + b.corrections == 0 && a.adoptions + b.adoptions == 0)
    let w = try #require(watcher)
    try await patiently { w.state == .match && w.sequence == made }
    #expect(try hash(w) == hash(a) && !w.mayAct && !w.pitch.isHost)

    // the side to act resigns: the final act carries `over`, and everyone sees it end
    let side = try JSONNode.parse(a.need)["side"]?.string ?? "A"
    let last = a.mayAct ? a : b
    #expect(try await last.take(JSONText(#"{"type":"resign","side":"\#(side)"}"#)))
    try await patiently { a.finishedReplay != nil && b.finishedReplay != nil && w.finishedReplay != nil }
    #expect(a.finishedReplay == b.finishedReplay)
  }
}
