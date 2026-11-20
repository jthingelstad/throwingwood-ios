import Foundation
import KubbRooms
import Testing

@testable import KubbRenderer

/// The reel card's state (HighlightReel): asking, waiting, the download, and every
/// answer in the words of docs/REEL.md.
@Suite @MainActor struct HighlightReelTests {
  static let code = "abcdefgh23"
  static let files = ReelFiles(
    tall: "/reels/abcdefgh23/4-r1-0.7/tall.mp4", wide: "/reels/abcdefgh23/4-r1-0.7/wide.mp4",
    room: code)!

  /// A stand-in server: each ask takes the next answer (the last repeats).
  final class Stub {
    var answers: [Result<ReelAnswer, Error>]
    var online = true
    var asks = 0
    var fetched: [URL] = []
    var fetchFails = false
    init(_ answers: [Result<ReelAnswer, Error>]) { self.answers = answers }
  }

  private func reel(_ stub: Stub, every: Duration = .milliseconds(20)) -> (HighlightReel, URL) {
    let cache = FileManager.default.temporaryDirectory.appending(path: "reel-tests-\(UUID())")
    let hooks = HighlightReel.Hooks(
      ask: {
        stub.asks += 1
        let next = stub.answers.count > 1 ? stub.answers.removeFirst() : stub.answers[0]
        return try next.get()
      },
      fetch: { from, to in
        if stub.fetchFails { throw URLError(.notConnectedToInternet) }
        stub.fetched.append(from)
        try Data("mp4".utf8).write(to: to)
      },
      reachable: { stub.online })
    return (
      HighlightReel(
        code: Self.code, site: URL(string: "https://throwingwood.com")!, cache: cache,
        hooks: hooks, every: every), cache
    )
  }

  private func settle(_ reel: HighlightReel, until: (HighlightReel.Phase) -> Bool) async throws {
    for _ in 0..<2000 {
      if until(reel.phase) { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("stuck at \(reel.phase)")
  }

  @Test func makingThenDoneDownloadsTheTallFileUnderItsSharedName() async throws {
    let stub = Stub([
      .success(.rendering(v: 4, tag: "r1-0.7")), .success(.rendering(v: 4, tag: "r1-0.7")),
      .success(.done(v: 4, tag: "r1-0.7", files: Self.files)),
    ])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    #expect(ReelWords.button(reel.phase) == "MAKE A HIGHLIGHT REEL")
    reel.show()
    try await settle(reel) { $0 == .making }
    #expect(ReelWords.button(reel.phase) == "MAKING YOUR REEL")
    try await settle(reel) { $0 == .ready }
    #expect(stub.asks == 3)
    #expect(stub.fetched.map(\.absoluteString) == ["https://throwingwood.com/reels/abcdefgh23/4-r1-0.7/tall.mp4"])
    #expect(reel.file(.tall)?.lastPathComponent == "throwing-wood-abcdefgh23-tall.mp4")
    #expect(reel.link.absoluteString == "https://throwingwood.com/p/abcdefgh23")
    #expect(ReelWords.button(reel.phase) == "WATCH THE REEL")
    // a wide window: the wide file too
    reel.want(.wide)
    try await settle(reel) { $0 == .ready && reel.file(.wide) != nil }
    #expect(reel.file(.wide)?.lastPathComponent == "throwing-wood-abcdefgh23-wide.mp4")
    // iOS emptied Caches: shown again, it is downloaded again
    try FileManager.default.removeItem(at: cache)
    #expect(reel.file(.tall) == nil)
    reel.show()
    try await settle(reel) { $0 == .ready && reel.file(.tall) != nil && reel.file(.wide) != nil }
    #expect(stub.asks == 3)  // the server is not asked again
  }

  @Test func closedItStopsAskingAndOpenedAgainItAsksOnceAndGoesOn() async throws {
    let stub = Stub([.success(.rendering(v: 4, tag: "r1-0.7"))])
    let (reel, cache) = reel(stub, every: .milliseconds(40))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .making }
    reel.hide()
    let asked = reel.asked
    try await Task.sleep(for: .milliseconds(200))
    #expect(reel.asked == asked)  // nothing in the background
    reel.show()
    #expect(reel.asked == asked + 1)  // once on return, at once
    for _ in 0..<2000 where reel.asked < asked + 2 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(reel.asked >= asked + 2)  // and on, every interval
    reel.hide()
  }

  @Test func offlineSendsNothingAndTryAgainAsks() async throws {
    let stub = Stub([.success(.rendering(v: 4, tag: "r1-0.7"))])
    stub.online = false
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    #expect(reel.phase == .problem(.offline))
    #expect(stub.asks == 0)
    #expect(ReelWords.problem(.offline) == ("No connection.", true))
    reel.tryAgain()
    #expect(stub.asks == 0)
    stub.online = true
    reel.tryAgain()
    try await settle(reel) { $0 == .making }
    #expect(stub.asks == 1)
    reel.hide()
  }

  @Test func anUnreachableServerIsNoConnectionAndAMissedPollIsAskedAgain() async throws {
    let stub = Stub([.failure(RoomError("closed"))])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.offline) }
    // while it renders, one lost answer is not the end
    stub.answers = [
      .success(.rendering(v: 4, tag: "r1-0.7")), .failure(RoomError("closed")),
      .success(.done(v: 4, tag: "r1-0.7", files: Self.files)),
    ]
    reel.tryAgain()
    try await settle(reel) { $0 == .ready }
    #expect(stub.asks == 4)
  }

  @Test func aFailedReelIsTriedOnceMoreThenNotThisTime() async throws {
    let stub = Stub([.success(.failed(v: 4, tag: "r1-0.7", why: .render))])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.failed) }
    #expect(ReelWords.problem(.failed) == ("The reel could not be made.", true))
    reel.tryAgain()
    try await settle(reel) { $0 == .problem(.notThisTime) }
    #expect(ReelWords.problem(.notThisTime).retry == false)
    reel.tryAgain()
    #expect(stub.asks == 2)
  }

  @Test func aStartThatFailedMayStartOnTryAgain() async throws {
    let stub = Stub([.success(.notStarted), .success(.rendering(v: 4, tag: "r1-0.7"))])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.failed) }
    reel.tryAgain()
    try await settle(reel) { $0 == .making }
    reel.hide()
  }

  @Test(arguments: [
    (ReelAnswer.failed(v: 4, tag: "r1-0.7", why: .empty), HighlightReel.Problem.empty),
    (.none(v: 3, why: .engine), .engine),
    (.none(v: 4, why: .busy), .busy),
    (.none(v: 0, why: .unavailable), .unavailable),
    (.none(v: 0, why: .other("later")), .unavailable),
    (.none(v: 0, why: .replay), .noReplay),
    (.tooMany, .tooMany),
  ])
  func everyOtherAnswerIsSaidPlainlyWithNoRetry(_ answer: ReelAnswer, _ problem: HighlightReel.Problem)
    async throws
  {
    let stub = Stub([.success(answer)])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(problem) }
    let words = ReelWords.problem(problem)
    #expect(!words.retry)
    reel.tryAgain()
    #expect(stub.asks == 1)
  }

  @Test func theWordsAreThePlainOnes() {
    #expect(ReelWords.problem(.busy).text.hasPrefix("Reels are busy today"))
    #expect(ReelWords.problem(.notThisTime).text.contains("Not this time"))
    #expect(ReelWords.wait == "About a minute. You can keep watching.")
    let all: [HighlightReel.Problem] = [
      .offline, .failed, .notThisTime, .empty, .engine, .busy, .unavailable, .tooMany, .noReplay,
    ]
    for p in all { #expect(!ReelWords.problem(p).text.contains("\u{2014}")) }
  }
}
