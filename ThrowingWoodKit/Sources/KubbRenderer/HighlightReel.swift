import Foundation
import KubbPitch

/// A finished pitch's highlight reel on this device (the web's docs/REEL.md "The
/// iPhone"): it checks the room still keeps this match, asks the rooms server, asks
/// again every 5 s while the card is on screen and the reel renders, downloads the
/// finished video to Caches and keeps it there. It knows a pitch code and, when the
/// card was opened from a finished match, what identifies that match; a match against
/// the computer, once shared and given a code, uses the same card with the code alone.
///
/// The state is the server's: closing the card, or the app going to the background,
/// only stops the asking (`hide`); showing it again asks once and goes on (`show`).
/// One rule holds off screen: a request already sent is read when it comes back, but
/// nothing it leads to is sent (a reel ask, a look again, a poll, the download). The
/// phase keeps where it got to, and `show` sends that next request.
@Observable @MainActor public final class HighlightReel {
  public enum Format: String, Sendable { case tall, wide }

  /// What the card says when there is no video to show.
  public enum Problem: Equatable, Sendable {
    /// No network (nothing was sent), or the server could not be reached.
    case offline
    /// The request could not start a render; TRY AGAIN asks once more.
    case failed
    /// The server tried and could not, or TRY AGAIN did not mend it. Final.
    case notThisTime
    /// The match had nothing to show.
    case empty
    /// Played on an engine the renderer does not carry.
    case engine
    /// Today's renders have all started.
    case busy
    /// This server makes no reels, or answered a why this build does not know.
    case unavailable
    /// This connection started as many renders as it may.
    case tooMany
    /// The pitch has no kept replay.
    case noReplay
    /// The pitch keeps a newer match now (a rematch): this one's reel cannot be asked.
    case moved
  }

  public enum Phase: Equatable, Sendable {
    case idle, checking, asking, making, fetching, ready
    case problem(Problem)
  }

  /// The ways out to the network, so tests and review pictures stand in for them.
  public struct Hooks {
    /// One `reel` request for the pitch, naming the kept replay version the card is
    /// for (`v`), or nil only while no kept read has given one (a code alone).
    public var ask: @MainActor (_ v: Int?) async throws -> ReelAnswer
    /// The room's kept replay (the read-only `replay` fetch), or nil to skip the check.
    public var kept: (@MainActor () async throws -> KeptReplay?)?
    /// Download `from` (a site URL) to the file `to`.
    public var fetch: @MainActor (_ from: URL, _ to: URL) async throws -> Void
    /// Whether the device has a network path now (offline sends nothing).
    public var reachable: @MainActor () -> Bool
    public init(
      ask: @escaping @MainActor (_ v: Int?) async throws -> ReelAnswer,
      kept: (@MainActor () async throws -> KeptReplay?)? = nil,
      fetch: @escaping @MainActor (_ from: URL, _ to: URL) async throws -> Void,
      reachable: @escaping @MainActor () -> Bool
    ) {
      self.ask = ask
      self.kept = kept
      self.fetch = fetch
      self.reachable = reachable
    }
  }

  /// How often a just-ended match's keep is looked for, and how far apart (the web's
  /// reelTune keptTries and keptWaitMs): the winner card can show before the server
  /// has kept the replay.
  public static let keptTries = 4

  public let code: String
  /// The match the card was opened for, when known: the kept replay must be this one.
  public let match: ReelMatch?
  /// The pitch's page, `https://throwingwood.com/p/<code>`: COPY LINK.
  public let link: URL
  /// A match just shared: the card says "The link:" before it (the web's `link`).
  public let linked: Bool
  public private(set) var phase = Phase.idle
  /// TRY AGAIN was pressed after a failure: the next failure is final.
  public private(set) var retried = false
  /// The format the card shows (`want`).
  public private(set) var wanted = Format.tall
  /// Requests sent (kept checks and reel asks), for tests.
  public private(set) var asked = 0
  /// When this device first asked: the card's slow bar runs from it.
  public private(set) var since: Date?
  /// While it renders, the last ask went unanswered: the card says No connection under
  /// the wait and goes on asking.
  public private(set) var offline = false

  private let site: URL
  private let cache: URL
  private let hooks: Hooks
  private let every: Duration
  private let keptWait: Duration
  private var onScreen = false
  private var inFlight = false
  private var looks = 0
  private var keptV: Int?
  private var poll: Task<Void, Never>?
  private var done: (v: Int, tag: String, files: ReelFiles)?

  /// `site`: where the reel paths are served (https://throwingwood.com). `cache`: a
  /// directory under Caches, which iOS may empty; the video is downloaded again then.
  /// `match`: the finished match on the screen, or nil with only a code.
  public init(
    code: String, site: URL, cache: URL, hooks: Hooks, match: ReelMatch? = nil,
    linked: Bool = false, every: Duration = .seconds(5), keptWait: Duration = .milliseconds(2500)
  ) {
    self.code = code
    self.linked = linked
    self.match = match
    link = URL(string: "https://throwingwood.com/p/" + code)!
    self.site = site
    self.cache = cache
    self.hooks = hooks
    self.every = every
    self.keptWait = keptWait
  }

  /// The downloaded file of a format, while it is on the device.
  public func file(_ format: Format) -> URL? {
    guard let done else { return nil }
    let url = local(format, done.v, done.tag)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// The card is on screen: start, or ask once how it stands and go on asking.
  public func show() {
    onScreen = true
    switch phase {
    case .idle: begin()
    case .checking: check()
    case .asking, .making: ask()
    case .ready: if missing() { fetch() }
    case .fetching, .problem: break
    }
  }

  /// The card is closed or the app went to the background: stop asking. A request
  /// already sent is still read when it comes back.
  public func hide() {
    onScreen = false
    poll?.cancel()
    poll = nil
  }

  /// The card shows this format (wide when its window is wider than tall).
  public func want(_ format: Format) {
    wanted = format
    if phase == .ready, missing() { fetch() }
  }

  /// TRY AGAIN: once after a request that could not start a render, and as often as
  /// pressed with no connection.
  public func tryAgain() {
    switch phase {
    case .problem(.failed):
      retried = true
      looks = 0
      begin()
    case .problem(.offline):
      looks = 0
      if done != nil { fetch() } else { begin() }
    default: break
    }
  }

  private func begin() {
    if keptV == nil, hooks.kept != nil { check() } else { ask() }
  }

  private func sendable() -> Bool {
    guard hooks.reachable() else {
      poll?.cancel()
      phase = .problem(.offline)  // nothing is sent
      return false
    }
    if since == nil { since = Date() }
    inFlight = true
    asked += 1
    return true
  }

  /// The kept replay, read without starting anything: it must be the match shown.
  private func check() {
    guard !inFlight, let kept = hooks.kept else { return }
    phase = .checking
    guard onScreen, sendable() else { return }  // off screen: `show` looks
    Task { [weak self] in
      let result: Result<KeptReplay?, Error>
      do { result = .success(try await kept()) } catch { result = .failure(error) }
      self?.checked(result)
    }
  }

  private func checked(_ result: Result<KeptReplay?, Error>) {
    inFlight = false
    switch result {
    case .failure(let error): failed(error)
    case .success(let k):
      guard let k, k.isMatch(match) else {
        if let k, let match, let n = k.n, n > match.n {
          phase = .problem(.moved)
          return
        }
        looks += 1
        if looks < Self.keptTries {
          schedule(keptWait) { $0.phase == .checking ? $0.check() : () }
        } else {
          phase = .problem(.noReplay)
        }
        return
      }
      keptV = k.v
      phase = .asking
      ask()
    }
  }

  private func ask() {
    guard !inFlight else { return }
    guard onScreen else {
      // off screen: `show` asks, naming the kept version already read, so a rematch
      // kept meanwhile is answered "moved" and nothing of it is started
      if phase != .making { phase = .asking }
      return
    }
    if phase == .making, !hooks.reachable() {
      offline = true  // nothing is sent; the render goes on without us
      schedule(every) { $0.phase == .making ? $0.ask() : () }
      return
    }
    if phase != .making { phase = .asking }
    guard sendable() else { return }
    // every ask names the match the card is for, so the server starts no other's
    Task { [weak self, hooks, keptV] in
      let answer: Result<ReelAnswer, Error>
      do { answer = .success(try await hooks.ask(keptV)) } catch { answer = .failure(error) }
      self?.answered(answer)
    }
  }

  private func answered(_ result: Result<ReelAnswer, Error>) {
    inFlight = false
    switch result {
    case .failure(let error):
      if phase == .making {
        // a lost poll is said and the next one tried: the render goes on without us
        offline = true
        schedule(every) { $0.phase == .making ? $0.ask() : () }
      } else {
        failed(error)
      }
    case .success(let answer):
      offline = false
      take(answer)
    }
  }

  /// A request that went wrong before the reel was rendering: no connection, or an
  /// answer this build cannot read (a throttle), which TRY AGAIN may ask about once.
  private func failed(_ error: Error) {
    if let room = error as? PitchError, room.code != "closed" {
      phase = .problem(retried ? .notThisTime : .failed)
    } else {
      phase = .problem(.offline)
    }
  }

  private func take(_ answer: ReelAnswer) {
    // the room keeps a newer match now: the server says so (`why: "moved"`, below),
    // and a server that ignores `v` answers about that one, which its version shows
    if let keptV, let v = answer.version, v != keptV {
      phase = .problem(.moved)
      return
    }
    switch answer {
    case .rendering:
      phase = .making
      schedule(every) { $0.phase == .making ? $0.ask() : () }
    case .done(let v, let tag, let files):
      done = (v, tag, files)
      fetch()
    case .failed(_, _, .empty): phase = .problem(.empty)
    case .failed: phase = .problem(.notThisTime)  // final: the server tried twice
    case .notStarted: phase = .problem(retried ? .notThisTime : .failed)
    case .none(_, .replay):
      // with no kept check, a just-ended match's keep may still be on its way
      looks += 1
      if hooks.kept == nil, looks < Self.keptTries {
        schedule(keptWait) { $0.phase == .asking ? $0.ask() : () }
      } else {
        phase = .problem(.noReplay)
      }
    case .none(_, .engine): phase = .problem(.engine)
    case .none(_, .busy): phase = .problem(.busy)
    case .none(_, .moved): phase = .problem(.moved)  // nothing was started or counted
    case .none(_, .unavailable), .none(_, .other): phase = .problem(.unavailable)
    case .tooMany: phase = .problem(.tooMany)
    }
  }

  private func schedule(_ wait: Duration, _ step: @escaping @MainActor (HighlightReel) -> Void) {
    poll?.cancel()
    guard onScreen else { return }
    poll = Task { [weak self] in
      do { try await Task.sleep(for: wait) } catch { return }
      guard let self, self.onScreen else { return }
      step(self)
    }
  }

  private func local(_ format: Format, _ v: Int, _ tag: String) -> URL {
    // the name the share sheet gives the file: throwing-wood-<code>-tall.mp4
    cache.appending(path: code).appending(path: "\(v)-\(tag)")
      .appending(path: "throwing-wood-\(code)-\(format.rawValue).mp4")
  }

  /// The tall file (SHARE's) and the one shown.
  private var needed: [Format] { wanted == .tall ? [.tall] : [.tall, .wide] }
  private func firstMissing() -> Format? { needed.first { file($0) == nil } }
  private func missing() -> Bool { firstMissing() != nil }

  private func fetch() {
    guard let done, !inFlight else { return }
    guard onScreen else {
      phase = .ready  // the reel is done; `show` downloads what is missing
      return
    }
    guard hooks.reachable() else {
      phase = .problem(.offline)
      return
    }
    phase = .fetching
    inFlight = true
    Task { [weak self, hooks, site] in
      var failed = false
      var format = self?.firstMissing()
      while let f = format, let self {
        let to = self.local(f, done.v, done.tag)
        let path = f == .tall ? done.files.tall : done.files.wide
        do {
          try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
          try await hooks.fetch(URL(string: path, relativeTo: site)!.absoluteURL, to)
        } catch {
          failed = true
          break
        }
        // the card closed meanwhile: what is still missing waits for `show`
        format = self.onScreen ? self.firstMissing() : nil
      }
      guard let self else { return }
      self.inFlight = false
      self.phase = failed ? .problem(.offline) : .ready
    }
  }
}

extension HighlightReel {
  /// Whether the card stays open as the pitch behind it changes (`OnlinePitch.changed`).
  /// It stays through the pitch's own comings and goings (connecting, reconnecting:
  /// coming back from the background is one), while the room sets up a rematch (the
  /// reel is still this match's, and BACK goes to the lobby), and while the pitch is
  /// still on the finished match it is for. It closes when a match starts on the pitch
  /// (a player there may be the next to throw) and when the pitch is gone (unreachable,
  /// not found, full, replaced), so the pitch's own card shows.
  public func staysOpen(on stage: OnlinePitch.Stage, finished: ReelMatch?) -> Bool {
    switch stage {
    case .connecting, .reconnecting, .lobby: true
    case .match: finished != nil && (match == nil || finished == match)
    case .notFound, .full, .unreachable, .replaced, .sealed, .noGame, .namesRefused: false
    }
  }
}

/// The words of the reel's button and card, the same as the web's (docs/REEL.md).
public enum ReelWords {
  public static let make = "MAKE A HIGHLIGHT REEL"
  public static let making = "MAKING YOUR REEL"
  public static let watch = "WATCH THE REEL"
  public static let title = "Highlight reel"
  public static let wait = "About a minute. You can keep watching."
  public static let fetching = "Your reel is ready. Getting the video."
  public static let share = "SHARE"
  public static let copyLink = "COPY LINK"
  public static let copied = "Copied the link."
  public static let tryAgain = "TRY AGAIN"
  public static let back = "BACK"

  /// The card's words for a problem, and whether TRY AGAIN is offered.
  public static func problem(_ p: HighlightReel.Problem) -> (text: String, retry: Bool) {
    switch p {
    case .offline: ("No connection.", true)
    case .failed: ("The reel could not be made.", true)
    case .notThisTime: ("The reel could not be made. Not this time.", false)
    case .empty: ("There are no highlights to show in this match.", false)
    case .engine: ("This match was played on another version of the game, so it cannot have a reel.", false)
    case .busy: ("Reels are busy today.", false)
    case .unavailable: ("Reels cannot be made right now.", false)
    case .tooMany: ("Too many reels asked for at once. Try again later.", false)
    case .noReplay: ("This match has no replay, so it cannot have a reel.", false)
    case .moved: ("This pitch has moved on to a newer match.", false)
    }
  }

  /// The winner card's button for a reel as it stands.
  public static func button(_ phase: HighlightReel.Phase?) -> String {
    switch phase {
    case .checking, .asking, .making: making
    case .fetching, .ready: watch
    default: make
    }
  }
}
