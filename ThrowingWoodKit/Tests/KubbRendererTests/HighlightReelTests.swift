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
    /// The room's kept replay at each look (the last repeats); nil: no kept check.
    var kept: [KeptReplay?]?
    var looks = 0
    init(_ answers: [Result<ReelAnswer, Error>], kept: [KeptReplay?]? = nil) {
      self.answers = answers
      self.kept = kept
    }
  }

  private func reel(
    _ stub: Stub, every: Duration = .milliseconds(20), match: ReelMatch? = nil
  ) -> (HighlightReel, URL) {
    let cache = FileManager.default.temporaryDirectory.appending(path: "reel-tests-\(UUID())")
    let hooks = HighlightReel.Hooks(
      ask: {
        stub.asks += 1
        let next = stub.answers.count > 1 ? stub.answers.removeFirst() : stub.answers[0]
        return try next.get()
      },
      kept: stub.kept == nil
        ? nil
        : { @MainActor in
          stub.looks += 1
          let next = stub.kept!.count > 1 ? stub.kept!.removeFirst() : stub.kept![0]
          return next
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
        hooks: hooks, match: match, every: every, keptWait: .milliseconds(5)), cache
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
    try await settle(reel) { $0 == .making }
    try await settle(reel) { _ in reel.offline }  // said under the wait, and asked on
    #expect(reel.phase == .making)
    try await settle(reel) { $0 == .ready }
    #expect(stub.asks == 4)
    #expect(!reel.offline)
  }

  @Test func withNoNetworkWhileItRendersItSaysSoAndGoesOn() async throws {
    let stub = Stub([.success(.rendering(v: 4, tag: "r1-0.7"))])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .making }
    stub.online = false
    try await settle(reel) { _ in reel.offline }
    let asks = stub.asks
    try await Task.sleep(for: .milliseconds(100))
    #expect(stub.asks == asks)  // nothing sent while offline
    #expect(reel.phase == .making)
    stub.online = true
    stub.answers = [.success(.done(v: 4, tag: "r1-0.7", files: Self.files))]
    try await settle(reel) { $0 == .ready }
    #expect(!reel.offline)
  }

  @Test(arguments: [ReelAnswer.ReelFailure.render, .timedOut, .other("later")])
  func aFailedReelIsFinalWithNoTryAgain(_ why: ReelAnswer.ReelFailure) async throws {
    let stub = Stub([.success(.failed(v: 4, tag: "r1-0.7", why: why))])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.notThisTime) }
    #expect(ReelWords.problem(.notThisTime) == ("The reel could not be made. Not this time.", false))
    reel.tryAgain()
    #expect(stub.asks == 1)
  }

  @Test func aStartThatFailedIsTriedOnceMoreThenNotThisTime() async throws {
    let stub = Stub([.success(.notStarted)])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.failed) }
    #expect(ReelWords.problem(.failed) == ("The reel could not be made.", true))
    reel.tryAgain()
    try await settle(reel) { $0 == .problem(.notThisTime) }
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

  @Test func theRoomMustKeepThisMatchBeforeAReelIsAsked() async throws {
    let stub = Stub(
      [.success(.rendering(v: 7, tag: "r1-0.7"))], kept: [KeptReplay(v: 7, n: 2, hash: "\"h2\"")])
    let (reel, cache) = reel(stub, match: ReelMatch(n: 2, hash: "\"h2\""))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .making }
    #expect(stub.looks == 1 && stub.asks >= 1)
    reel.hide()
  }

  @Test func aKeepStillOnItsWayIsLookedForFourTimes() async throws {
    let stub = Stub(
      [.success(.rendering(v: 7, tag: "r1-0.7"))], kept: [nil, nil, KeptReplay(v: 7, n: 2, hash: nil)])
    let (reel, cache) = reel(stub, match: ReelMatch(n: 2, hash: "\"h2\""))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    #expect(ReelWords.button(reel.phase) == "MAKING YOUR REEL")
    try await settle(reel) { $0 == .making }
    #expect(stub.looks == 3)
    reel.hide()
    // never kept: four looks, then no replay, and no reel asked for
    let none = Stub([.success(.rendering(v: 7, tag: "r1-0.7"))], kept: [nil])
    let (reel2, cache2) = self.reel(none, match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache2) }
    reel2.show()
    try await settle(reel2) { $0 == .problem(.noReplay) }
    #expect(none.looks == HighlightReel.keptTries && none.asks == 0)
  }

  @Test func aRematchKeptSinceHasMovedOn() async throws {
    // the room keeps a newer match than the one on the card
    let newer = Stub([.success(.rendering(v: 9, tag: "r1-0.7"))], kept: [KeptReplay(v: 9, n: 3, hash: nil)])
    let (reel, cache) = reel(newer, match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.moved) }
    #expect(newer.asks == 0)
    #expect(ReelWords.problem(.moved) == ("This pitch has moved on to a newer match.", false))
    // the same number with another hash is not this match either
    let other = Stub([.success(.rendering(v: 9, tag: "r1-0.7"))], kept: [KeptReplay(v: 9, n: 2, hash: "\"b\"")])
    let (reel2, cache2) = self.reel(other, match: ReelMatch(n: 2, hash: "\"a\""))
    defer { try? FileManager.default.removeItem(at: cache2) }
    reel2.show()
    try await settle(reel2) { $0 == .problem(.noReplay) }
    #expect(other.asks == 0)
    // kept after the check: an answer about another version has moved on too
    let later = Stub(
      [.success(.rendering(v: 7, tag: "r1-0.7")), .success(.rendering(v: 9, tag: "r1-0.7"))],
      kept: [KeptReplay(v: 7, n: 2, hash: nil)])
    let (reel3, cache3) = self.reel(later, match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache3) }
    reel3.show()
    try await settle(reel3) { $0 == .problem(.moved) }
  }

  @Test func withOnlyACodeThereIsNothingToCompare() async throws {
    let stub = Stub([.success(.rendering(v: 9, tag: "r1-0.7"))], kept: [KeptReplay(v: 9, n: 5, hash: nil)])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .making }
    reel.hide()
  }

  @Test func withNoKeptCheckANoReplayAnswerIsAskedAgainFourTimes() async throws {
    let stub = Stub([
      .success(.none(v: 0, why: .replay)), .success(.none(v: 0, why: .replay)),
      .success(.rendering(v: 7, tag: "r1-0.7")),
    ])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .making }
    reel.hide()
    let never = Stub([.success(.none(v: 0, why: .replay))])
    let (reel2, cache2) = self.reel(never)
    defer { try? FileManager.default.removeItem(at: cache2) }
    reel2.show()
    try await settle(reel2) { $0 == .problem(.noReplay) }
    #expect(never.asks == HighlightReel.keptTries)
  }

  @Test func theWordsAreTheWebsOnes() {
    #expect(ReelWords.problem(.busy) == ("Reels are busy today.", false))
    #expect(ReelWords.problem(.unavailable) == ("Reels cannot be made right now.", false))
    #expect(ReelWords.problem(.tooMany) == ("Too many reels asked for at once. Try again later.", false))
    #expect(ReelWords.problem(.offline) == ("No connection.", true))
    #expect(ReelWords.fetching == "Your reel is ready. Getting the video.")
    #expect(ReelWords.copied == "Copied the link.")
    #expect(ReelWords.wait == "About a minute. You can keep watching.")
    let all: [HighlightReel.Problem] = [
      .offline, .failed, .notThisTime, .empty, .engine, .busy, .unavailable, .tooMany, .noReplay,
      .moved,
    ]
    for p in all {
      let text = ReelWords.problem(p).text
      #expect(!text.contains("\u{2014}") && !text.contains("phone") && !text.contains("iPad"))
    }
  }
}
