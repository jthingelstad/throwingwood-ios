import Foundation
import KubbEngine
import Testing

@testable import KubbPitch
@testable import KubbRenderer

@MainActor private final class TestID: MemberIDStore {
  var id: String?
  init(_ id: String) { self.id = id }
  func load() -> String? { id }
  func save(_ id: String) { self.id = id }
}

/// Another member's raises watched online, and the actions waiting behind them (Codex on
/// PR #46): however a watched raise ends (its own time, a tap's skip, a resync), the
/// queue behind it drains and the seat is updated, so no action is left unapplied.
@Suite @MainActor struct OnlineRaiseTests {
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  /// An online screen (never connected) whose board shows `raise-many` (two raises for
  /// side A), and the actions that follow it as the pitch would send them: both raises by
  /// the engine's choice, then the computer's throw, each with the hash and snapshot after
  /// it from a second engine.
  private func setUp() throws -> (OnlinePitch, [(JSONText, JSONNode)], Engine) {
    let fake = FakePitch()
    let online = try OnlinePitch(
      url: URL(string: "ws://127.0.0.1:1")!, link: try #require(PitchLink(fake.code)), create: false,
      name: "Brave Birch", appVersion: "0.0-test", store: TestID("Watch_Member"),
      defaults: UserDefaults(suiteName: "raise-\(UUID().uuidString)")!, factory: fake.factory)
    let start = try fixture("raise-many")
    try online.board.restore(start, save: nil)
    let reference = try Engine(appVersion: "test")
    _ = try reference.call("restore", json: start)
    var actions: [(JSONText, JSONNode)] = []
    func after(_ action: String, seq: Int) throws -> (JSONText, JSONNode) {
      let m = JS.object([
        ("n", .int(1)), ("seq", .int(seq)), ("hash", .string(try reference.hash())),
        ("snap", .string(try reference.call("snapshot"))),
      ]).json
      return (JSONText(action), try JSONNode.parse(m))
    }
    for seq in 1...2 {
      _ = try reference.call("apply", json: #"{"type":"raise"}"#)
      actions.append(try after(#"{"type":"raise"}"#, seq: seq))
    }
    // the computer's throw that follows, as its seat sends it
    _ = try reference.call("setControl", json: #"{"sides":["A"],"cpu":true}"#)
    for _ in 0..<4000 {
      let out = try JSONNode.parse(reference.call("frame", json: #"{"dt":0.05}"#))
      if let a = out["action"] {
        actions.append(try after(a.raw.text, seq: 3))
        break
      }
    }
    try #require(actions.count == 3)
    return (online, actions, reference)
  }

  private func deliver(_ online: OnlinePitch, _ actions: [(JSONText, JSONNode)]) throws {
    for (a, m) in actions { try online.present(.apply(action: a, match: m)) }
  }

  /// Two raises delivered together, a tap during the first: both stand at once and the
  /// board is the pitch's.
  @Test func twoRaisesTogetherSkippedByATap() throws {
    let (online, actions, _) = try setUp()
    defer { online.close() }
    try deliver(online, Array(actions[0..<2]))
    #expect(online.board.raiseShowing)
    #expect(online.displayedSeqForProbe == 1)
    try online.skipRaise()
    #expect(!online.board.raiseShowing)
    #expect(online.displayedSeqForProbe == 2)
    #expect(online.displayedHash == actions[1].1["hash"]?.string)
  }

  /// Three actions delivered together (both raises and the computer's throw behind them),
  /// a tap during the first raise: both raises stand and the throw starts playing.
  @Test func aRaiseSkippedWithAThrowQueuedBehindIt() throws {
    let (online, actions, _) = try setUp()
    defer { online.close() }
    try deliver(online, actions)
    #expect(online.board.raiseShowing)
    try online.skipRaise()
    #expect(online.displayedSeqForProbe == 3)
    #expect(online.board.playing)
    #expect(online.displayedHash == actions[2].1["hash"]?.string)
  }

  /// Left alone, each raise plays out at its pace and the next follows on the frames, the
  /// throw last.
  @Test func raisesPlayOutAndTheQueueFollows() throws {
    let (online, actions, _) = try setUp()
    defer { online.close() }
    try deliver(online, actions)
    for _ in 0..<600 where online.displayedSeqForProbe < 3 { try online.tick(1.0 / 60) }
    #expect(online.displayedSeqForProbe == 3)
    #expect(online.displayedHash == actions[2].1["hash"]?.string)
  }

  /// A watched raise ended outside the frame (the board's own skip, called directly, and a
  /// resync clearing the presentation): the next frame drains the queue all the same,
  /// from the state rather than from catching the moment it ended.
  @Test func aRaiseEndedOutsideTheFrameStillLetsTheQueueThrough() throws {
    for ending in ["board skip", "presentation reset"] {
      let (online, actions, _) = try setUp()
      defer { online.close() }
      try deliver(online, Array(actions[0..<2]))
      try online.tick(1.0 / 60)
      #expect(online.board.raiseShowing, "\(ending)")
      if ending == "board skip" {
        try online.board.skipRaise()
      } else {
        // as a resync does before it adopts a snapshot: the raise is gone mid-way; the
        // first raise is applied already, so the board shows the second kubb's need
        online.board.resetPresentation()
        try online.board.adopt(online.board.read("view"))
      }
      #expect(!online.board.raiseShowing, "\(ending)")
      for _ in 0..<120 where online.displayedSeqForProbe < 2 { try online.tick(1.0 / 60) }
      #expect(online.displayedSeqForProbe == 2, "\(ending)")
      #expect(online.displayedHash == actions[1].1["hash"]?.string, "\(ending)")
    }
  }

  /// Codex on PR #46: a member stands the last kubb and at once aims. While this board
  /// watches that raise (its engine already at the throw), the incoming aim is held: the
  /// raise view keeps its camera, and the newest aim shows on the first frame after it.
  @Test func aRemoteAimWaitsForAWatchedRaise() throws {
    let (online, actions, _) = try setUp()
    defer { online.close() }
    online.stage = .match
    // the aim at the throw after the raises, as the thrower would cast it
    let second = try Engine(appVersion: "test")
    _ = try second.call("restore", json: try fixture("raise-many"))
    for _ in 0..<2 { _ = try second.call("apply", json: #"{"type":"raise"}"#) }
    let aim = try JSONNode.parse(second.call("aimState"))
    try deliver(online, Array(actions[0..<2]))
    for _ in 0..<600 where online.displayedSeqForProbe < 2 { try online.tick(1.0 / 60) }
    #expect(online.displayedSeqForProbe == 2 && online.board.raiseShowing)
    online.aims.add(aim, from: "Thrower", ts: OnlinePitch.now() - 1000, k: 1, now: OnlinePitch.now())
    let shown = online.shownAims
    var frames = 0
    while online.board.raiseShowing && frames < 120 {
      try online.tick(1.0 / 60)
      frames += 1
      if online.board.raiseShowing {
        // the raise view, its camera and no aim over it
        #expect(online.shownAims == shown)
        #expect(online.board.scene.stillZoom != nil)
        #expect(online.board.scene.marker == nil)
      }
    }
    #expect(!online.board.raiseShowing)
    // the frame after: the held aim is shown, so the watcher is not behind
    try online.tick(1.0 / 60)
    #expect(online.shownAims == shown + 1)
  }

  /// The app going to the background during this device's own lead-in: the unsent raise is
  /// dropped before it is applied (nothing reaches the pitch, the engine untouched), so no
  /// refused submit stops the board.
  @Test func theBackgroundDropsAnUnsentRaise() throws {
    let (online, _, _) = try setUp()
    defer { online.close() }
    let hash = online.displayedHash
    online.board.acceptsInput = true
    online.board.raiseRest()
    try online.board.tick(0.02)
    #expect(online.board.raiseWatch == .ownLeadIn)
    online.background()
    #expect(online.board.raiseWatch == .none && !online.board.acceptsInput)
    for _ in 0..<60 { try online.tick(1.0 / 60) }
    #expect(online.displayedHash == hash)
  }
}
