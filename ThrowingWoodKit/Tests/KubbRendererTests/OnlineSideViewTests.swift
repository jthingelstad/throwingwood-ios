import CoreGraphics
import Foundation
import KubbEngine
import Testing

@testable import KubbPitch
@testable import KubbRenderer

@MainActor private final class SideID: MemberIDStore {
  var id: String?
  init(_ id: String) { self.id = id }
  func load() -> String? { id }
  func save(_ id: String) { self.id = id }
}

/// Online, another member's throw is seen from this device's own end (the owner,
/// 2026-11-27: "when the other player was throwing I was watching from their POV, not mine
/// from the other baseline"): the paced board keeps its side view through the throw that
/// arrives as an action, the resync after it, and a move to another engine's Lua state.
@Suite @MainActor struct OnlineSideViewTests {
  private let size = CGSize(width: 402, height: 874), safe = ScreenInsets(top: 62, bottom: 34)

  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  /// An online screen (never connected) whose board shows `computer` (side B's throw next)
  /// for a member on side A, and side B's throw as the pitch would send it.
  private func setUp() throws -> (OnlinePitch, JSONText, JSONNode) {
    let fake = FakePitch()
    let online = try OnlinePitch(
      url: URL(string: "ws://127.0.0.1:1")!, link: try #require(PitchLink(fake.code)), create: false,
      name: "Brave Birch", appVersion: "0.0-test", store: SideID("Side_Member"),
      defaults: UserDefaults(suiteName: "side-\(UUID().uuidString)")!, factory: fake.factory)
    let start = try fixture("computer")
    try online.board.restore(start, save: nil)
    let reference = try Engine(appVersion: "test")
    _ = try reference.call("restore", json: start)
    _ = try reference.call("setControl", json: #"{"sides":["A"],"cpu":true}"#)
    for _ in 0..<4000 {
      let out = try JSONNode.parse(reference.call("frame", json: #"{"dt":0.05}"#))
      if let a = out["action"] {
        let m = JS.object([
          ("n", .int(1)), ("seq", .int(1)), ("hash", .string(try reference.hash())),
          ("snap", .string(try reference.call("snapshot"))),
        ]).json
        // this member plays side A; the pitch's other member throws for B
        online.board.playerSide = { "A" }
        online.board.watching = false
        online.board.dismissHandoff()
        return (online, JSONText(a.raw.text), try JSONNode.parse(m))
      }
    }
    Issue.record("no throw from side B")
    throw PitchError("no throw")
  }

  @Test func theOtherMembersThrowIsSeenFromThisEnd() throws {
    let (online, action, m) = try setUp()
    defer { online.close() }
    online.stage = .match
    online.board.sideView(size: size, safe: safe)
    #expect(online.board.sideViewOn && online.board.camera.kind == "end", "waiting on B: from A's end")
    try online.present(.apply(action: action, match: m))
    try #require(online.board.playing)
    var frames = 0, eyes = Set<String>()
    while online.board.playing && frames < 2000 {
      #expect(online.board.camera.kind == "end", "frame \(frames): from A's end")
      // a person's eyes on A's baseline (engine 1.4.1): low and just behind the line
      let c = online.board.camera
      #expect(c.py < 0 && c.py > -2 && c.pz > 1 && c.pz < 2.2, "frame \(frames): eye \(c.py), \(c.pz)")
      eyes.insert(String(format: "%.3f %.3f %.3f", c.fx, c.fy, c.fz))
      try online.tick(1.0 / 60)
      frames += 1
    }
    #expect(!online.board.playing)
    // the eyes follow the throw: the camera turns while the recording plays
    #expect(eyes.count > 5, "the view follows the throw")
    // the next need is still drawn from A's side
    #expect(online.board.sideViewOn)
  }

  /// A resync (the pitch's snapshot restored on the board) keeps the side view.
  @Test func aResyncKeepsTheSideView() throws {
    let (online, _, m) = try setUp()
    defer { online.close() }
    online.stage = .match
    online.board.sideView(size: size, safe: safe)
    try online.present(.restore(m))
    online.board.sideView(size: size, safe: safe)
    #expect(online.board.sideViewOn)
    #expect(online.board.need?.frame == "A")
  }
}
