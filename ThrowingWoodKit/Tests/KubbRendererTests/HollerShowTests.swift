import Foundation
import KubbEngine
import Testing

@testable import KubbPitch
@testable import KubbRenderer

// HOLLER on the online screen against the in-process pitch server: what arrives is drawn
// only when it is on the list, a phrase as words and an emoji as an emoji.

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

@Suite @MainActor struct HollerShowTests {
  @Test func onlyTheListIsDrawn() async throws {
    let fake = FakePitch()
    let host = try PitchController(
      pitch: PitchClient(
        url: URL(string: "ws://127.0.0.1:1")!, pitch: fake.code, appVersion: "0.0-test",
        store: TestID("Host_Member"), timing: quick(), factory: fake.factory),
      engines: EngineShelf(appVersion: "0.0-test"))
    defer { host.close() }
    host.connect()
    try await host.pitch.ready()

    let online = try OnlinePitch(
      url: URL(string: "ws://127.0.0.1:1")!, link: try #require(PitchLink(fake.code)), create: false,
      name: "Brave Birch", appVersion: "0.0-test", store: TestID("Guest_Member"), timing: quick(),
      defaults: UserDefaults(suiteName: "holler-\(UUID().uuidString)")!, factory: fake.factory)
    defer { online.close() }
    online.connect()
    try await soon { host.pitch.members.count == 2 }

    // nothing off the list reaches the screen, however it is written
    for d in [
      #"{"t":"shout","w":"Typed by a player"}"#, #"{"t":"shout","e":"🐐"}"#,
      #"{"t":"shout","w":"🔥"}"#, #"{"t":"shout","e":"NICE!"}"#, #"{"t":"shout"}"#,
    ] {
      #expect(host.pitch.cast(JSONText(d), all: true))
    }
    #expect(host.pitch.cast(Holler.Piece.phrase("KNOCKERHEAD!").payload.json, all: true))
    #expect(host.pitch.cast(Holler.Piece.emoji("🪵").payload.json, all: true))
    try await soon { online.shouts.count == 2 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(online.shouts.map(\.piece) == [.phrase("KNOCKERHEAD!"), .emoji("🪵")])
    #expect(online.shouts.last?.piece.isEmoji == true)
    #expect(online.shouts[0].spoken.hasSuffix(": KNOCKERHEAD!"))
    #expect(online.shouts[1].spoken.hasSuffix(": Wood"))

    // its own holler shows at once on its own screen too
    online.shout(.emoji("👑"))
    #expect(online.shouts.count == 3 && online.shouts.last?.piece == .emoji("👑"))
  }
}
