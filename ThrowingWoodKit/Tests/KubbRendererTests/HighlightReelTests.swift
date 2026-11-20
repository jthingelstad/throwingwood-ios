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
    /// The kept version each reel ask named (nil: left out).
    var sentV: [Int?] = []
    var fetched: [URL] = []
    var fetchFails = false
    /// Run as each download comes back (a card closed mid-download).
    var onFetch: (() -> Void)?
    /// The room's kept replay at each look (the last repeats); nil: no kept check.
    var kept: [KeptReplay?]?
    var looks = 0
    /// How long each kept read and each reel ask takes to come back.
    var keptDelay: Duration?
    var askDelay: Duration?
    /// Kept reads and reel asks that have come back.
    var keptBack = 0
    var askBack = 0
    init(_ answers: [Result<ReelAnswer, Error>], kept: [KeptReplay?]? = nil) {
      self.answers = answers
      self.kept = kept
    }
  }

  private func reel(
    _ stub: Stub, every: Duration = .milliseconds(20), match: ReelMatch? = nil
  ) -> (HighlightReel, URL) {
    let cache = FileManager.default.temporaryDirectory.appending(path: "reel-tests-\(UUID())")
    let look: @MainActor () async throws -> KeptReplay? = {
      stub.looks += 1
      if let d = stub.keptDelay { try await Task.sleep(for: d) }
      stub.keptBack += 1
      return stub.kept!.count > 1 ? stub.kept!.removeFirst() : stub.kept![0]
    }
    let hooks = HighlightReel.Hooks(
      ask: { @MainActor (v: Int?) async throws -> ReelAnswer in
        stub.asks += 1
        stub.sentV.append(v)
        if let d = stub.askDelay { try await Task.sleep(for: d) }
        stub.askBack += 1
        let next = stub.answers.count > 1 ? stub.answers.removeFirst() : stub.answers[0]
        return try next.get()
      },
      kept: stub.kept == nil ? nil : look,
      fetch: { from, to in
        if stub.fetchFails { throw URLError(.notConnectedToInternet) }
        stub.fetched.append(from)
        try Data("mp4".utf8).write(to: to)
        stub.onFetch?()
      },
      reachable: { stub.online })
    return (
      HighlightReel(
        code: Self.code, site: URL(string: "https://throwingwood.com")!, cache: cache,
        hooks: hooks, match: match, every: every, keptWait: .milliseconds(5)), cache
    )
  }

  /// Wait until `cond` holds (the suite may run under load), then a little more, so
  /// whatever the reply leads to has had its chance to be sent.
  private func landed(_ cond: () -> Bool) async throws {
    for _ in 0..<5000 where !cond() { try await Task.sleep(for: .milliseconds(2)) }
    #expect(cond())
    try await Task.sleep(for: .milliseconds(60))
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

  @Test func everyReelAskAfterTheKeptReadNamesItsVersion() async throws {
    // the first ask, a reopened card, and TRY AGAIN
    let stub = Stub(
      [
        .success(.rendering(v: 7, tag: "r1-0.7")), .success(.notStarted),
        .success(.rendering(v: 7, tag: "r1-0.7")),
      ], kept: [KeptReplay(v: 7, n: 2, hash: nil)])
    let (reel, cache) = reel(stub, every: .seconds(60), match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .making }
    reel.hide()
    reel.show()  // reopened mid-render: asks once
    try await settle(reel) { $0 == .problem(.failed) }
    reel.tryAgain()
    try await settle(reel) { $0 == .making }
    reel.hide()
    #expect(stub.looks == 1)
    #expect(stub.sentV == [7, 7, 7])
    // each poll while it renders
    let polls = Stub([.success(.rendering(v: 7, tag: "r1-0.7"))], kept: [KeptReplay(v: 7, n: 2, hash: nil)])
    let (reel2, cache2) = self.reel(polls, match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache2) }
    reel2.show()
    for _ in 0..<2000 where polls.asks < 3 { try await Task.sleep(for: .milliseconds(2)) }
    reel2.hide()
    #expect(polls.asks >= 3 && polls.sentV.allSatisfy { $0 == 7 })
    // a code alone: the kept read's version is named all the same
    let code = Stub([.success(.rendering(v: 9, tag: "r1-0.7"))], kept: [KeptReplay(v: 9, n: 5, hash: nil)])
    let (reel3, cache3) = self.reel(code, every: .seconds(60))
    defer { try? FileManager.default.removeItem(at: cache3) }
    reel3.show()
    try await settle(reel3) { $0 == .making }
    reel3.hide()
    #expect(code.sentV == [9])
    // with no kept read there is no version, and it is left out (never null on the wire)
    let none = Stub([.success(.rendering(v: 9, tag: "r1-0.7"))])
    let (reel4, cache4) = self.reel(none, every: .seconds(60))
    defer { try? FileManager.default.removeItem(at: cache4) }
    reel4.show()
    try await settle(reel4) { $0 == .making }
    reel4.hide()
    #expect(none.sentV == [nil])
  }

  @Test func aMovedAnswerSaysSoAndStopsAsking() async throws {
    let stub = Stub([.success(.none(v: 9, why: .moved))], kept: [KeptReplay(v: 7, n: 2, hash: nil)])
    let (reel, cache) = reel(stub, match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.moved) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(stub.asks == 1 && reel.phase == .problem(.moved))
    reel.tryAgain()
    #expect(stub.asks == 1)
    #expect(ReelWords.problem(.moved) == ("This pitch has moved on to a newer match.", false))
    reel.hide()
    // with a code alone and no kept read, the server's word is enough
    let alone = Stub([.success(.none(v: 9, why: .moved))])
    let (reel2, cache2) = self.reel(alone)
    defer { try? FileManager.default.removeItem(at: cache2) }
    reel2.show()
    try await settle(reel2) { $0 == .problem(.moved) }
    reel2.hide()
  }

  @Test func aServerThatIgnoresTheVersionStillEndsInMoved() async throws {
    // the deployed server predates `v`: it answers about the newer match it keeps
    let stub = Stub([.success(.rendering(v: 9, tag: "r1-0.7"))], kept: [KeptReplay(v: 7, n: 2, hash: nil)])
    let (reel, cache) = reel(stub, match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .problem(.moved) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(stub.asks == 1 && stub.sentV == [7])
    reel.hide()
  }

  @Test func aKeptReplyAfterTheCardClosedSendsNothingUntilItShows() async throws {
    let stub = Stub([.success(.rendering(v: 7, tag: "r1-0.7"))], kept: [KeptReplay(v: 7, n: 2, hash: nil)])
    stub.keptDelay = .milliseconds(40)
    let (reel, cache) = reel(stub, every: .seconds(60), match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    reel.hide()  // BACK while the kept read is on its way
    try await landed { stub.keptBack == 1 }
    #expect(stub.looks == 1 && stub.asks == 0 && reel.phase == .asking)
    reel.show()  // the checked version is kept: no second look, the ask names it
    try await settle(reel) { $0 == .making }
    #expect(stub.looks == 1 && stub.sentV == [7])
    reel.hide()
  }

  @Test func offScreenNothingARepliesLeadsToIsSent() async throws {
    // a keep still on its way: no look again until the card shows
    let looks = Stub(
      [.success(.rendering(v: 7, tag: "r1-0.7"))], kept: [nil, KeptReplay(v: 7, n: 2, hash: nil)])
    looks.keptDelay = .milliseconds(40)
    let (reel, cache) = reel(looks, every: .seconds(60), match: ReelMatch(n: 2, hash: nil))
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    reel.hide()
    try await landed { looks.keptBack == 1 }
    #expect(looks.looks == 1 && looks.asks == 0 && reel.phase == .checking)
    reel.show()
    try await settle(reel) { $0 == .making }
    #expect(looks.looks == 2)
    reel.hide()
    // a rendering answer after the card closed: no poll follows
    let polls = Stub([.success(.rendering(v: 7, tag: "r1-0.7"))])
    polls.askDelay = .milliseconds(40)
    let (reel2, cache2) = self.reel(polls)
    defer { try? FileManager.default.removeItem(at: cache2) }
    reel2.show()
    reel2.hide()
    try await landed { polls.askBack == 1 }
    #expect(polls.asks == 1 && reel2.phase == .making)
    // a done answer after the card closed: the download waits for the card
    let done = Stub([.success(.done(v: 4, tag: "r1-0.7", files: Self.files))])
    done.askDelay = .milliseconds(40)
    let (reel3, cache3) = self.reel(done)
    defer { try? FileManager.default.removeItem(at: cache3) }
    reel3.show()
    reel3.hide()
    try await landed { done.askBack == 1 }
    #expect(done.fetched.isEmpty && reel3.phase == .ready)
    #expect(ReelWords.button(reel3.phase) == "WATCH THE REEL")
    reel3.show()
    for _ in 0..<2000 where done.fetched.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    try await settle(reel3) { $0 == .ready }
    #expect(done.fetched.count == 1 && reel3.file(.tall) != nil)
  }

  @Test func closedWhileTheTallFileDownloadsTheWideOneWaitsForTheCard() async throws {
    let stub = Stub([.success(.done(v: 4, tag: "r1-0.7", files: Self.files))])
    let (reel, cache) = reel(stub)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.want(.wide)
    stub.onFetch = { reel.hide() }
    reel.show()
    try await landed { stub.fetched.count == 1 && reel.phase == .ready }
    #expect(stub.fetched.count == 1 && reel.file(.tall) != nil && reel.file(.wide) == nil)
    #expect(ReelWords.button(reel.phase) == "WATCH THE REEL")
    // shown again, the wide file is downloaded
    stub.onFetch = nil
    reel.show()
    try await settle(reel) { $0 == .ready && reel.file(.wide) != nil }
    #expect(stub.fetched.count == 2)
  }

  @Test func backgroundAndReturnWhileItRendersKeepsTheCardAndAsksOn() async throws {
    let match = ReelMatch(n: 2, hash: "\"h\"")
    let stub = Stub([.success(.rendering(v: 7, tag: "r1-0.7"))], kept: [KeptReplay(v: 7, n: 2, hash: "\"h\"")])
    let (reel, cache) = reel(stub, every: .seconds(60), match: match)
    defer { try? FileManager.default.removeItem(at: cache) }
    reel.show()
    try await settle(reel) { $0 == .making }
    reel.hide()  // the app goes to the background
    let before = stub.asks
    // coming back, the pitch reconnects before it is on its match again: the card stays
    for stage in [OnlinePitch.Stage.connecting, .reconnecting, .match] {
      #expect(reel.staysOpen(on: stage, finished: match))
    }
    reel.show()
    for _ in 0..<2000 where stub.asks == before { try await Task.sleep(for: .milliseconds(2)) }
    #expect(stub.asks == before + 1 && stub.sentV.last == 7 && reel.phase == .making)
    reel.hide()
  }

  @Test func theCardClosesWhenAMatchStartsOrThePitchIsGone() {
    let match = ReelMatch(n: 2, hash: nil)
    let (reel, cache) = reel(Stub([.success(.rendering(v: 7, tag: "r1-0.7"))]), match: match)
    defer { try? FileManager.default.removeItem(at: cache) }
    // a rematch being set up: the reel is still this match's
    #expect(reel.staysOpen(on: .lobby, finished: nil))
    // the rematch has started (no finished match), or a newer one has finished
    #expect(!reel.staysOpen(on: .match, finished: nil))
    #expect(!reel.staysOpen(on: .match, finished: ReelMatch(n: 3, hash: nil)))
    // a sealed pitch (a shared match) shows its own card under the reel
    for stage in [OnlinePitch.Stage.notFound, .full, .unreachable, .replaced, .sealed] {
      #expect(!reel.staysOpen(on: stage, finished: match))
    }
    // a reel is a shared match's only when the share made it
    #expect(!reel.linked)
    let shared = HighlightReel(
      code: Self.code, site: URL(string: "https://throwingwood.com")!, cache: cache,
      hooks: .init(ask: { _ in .none(v: 0, why: .unavailable) }, fetch: { _, _ in }, reachable: { false }), linked: true)
    #expect(shared.linked && shared.link.absoluteString == "https://throwingwood.com/p/" + Self.code)
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
