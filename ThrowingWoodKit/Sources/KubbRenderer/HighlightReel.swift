import Foundation
import KubbRooms

/// A finished pitch's highlight reel on this device (the web's docs/REEL.md "The
/// iPhone"): it asks the rooms server, asks again every 5 s while the card is on
/// screen and the reel renders, downloads the finished video to Caches and keeps it
/// there. It knows a pitch code and nothing else, so a match against the computer,
/// once shared and given a code, uses the same card.
///
/// The state is the server's: closing the card, or the app going to the background,
/// only stops the asking (`hide`); showing it again asks once and goes on (`show`).
@Observable @MainActor public final class HighlightReel {
  public enum Format: String, Sendable { case tall, wide }

  /// What the card says when there is no video to show.
  public enum Problem: Equatable, Sendable {
    /// No network (nothing was sent), or the server could not be reached.
    case offline
    /// The reel was not made; TRY AGAIN asks once more.
    case failed
    /// Not made after TRY AGAIN.
    case notThisTime
    /// The match had nothing to show.
    case empty
    /// Played on an engine the renderer does not carry.
    case engine
    /// Today's renders have all started.
    case busy
    /// This server makes no reels.
    case unavailable
    /// This connection started as many renders as it may.
    case tooMany
    /// The pitch has no kept replay.
    case noReplay
  }

  public enum Phase: Equatable, Sendable {
    case idle, asking, making, fetching, ready
    case problem(Problem)
  }

  /// The ways out to the network, so tests and review pictures stand in for them.
  public struct Hooks {
    /// One `reel` request for the pitch.
    public var ask: @MainActor () async throws -> ReelAnswer
    /// Download `from` (a site URL) to the file `to`.
    public var fetch: @MainActor (_ from: URL, _ to: URL) async throws -> Void
    /// Whether the device has a network path now (offline sends nothing).
    public var reachable: @MainActor () -> Bool
    public init(
      ask: @escaping @MainActor () async throws -> ReelAnswer,
      fetch: @escaping @MainActor (_ from: URL, _ to: URL) async throws -> Void,
      reachable: @escaping @MainActor () -> Bool
    ) {
      self.ask = ask
      self.fetch = fetch
      self.reachable = reachable
    }
  }

  public let code: String
  /// The pitch's page, `https://throwingwood.com/p/<code>`: COPY LINK.
  public let link: URL
  public private(set) var phase = Phase.idle
  /// TRY AGAIN was pressed after a failure: the next failure is final.
  public private(set) var retried = false
  /// The format the card shows (`want`).
  public private(set) var wanted = Format.tall
  /// Requests sent, for tests.
  public private(set) var asked = 0

  private let site: URL
  private let cache: URL
  private let hooks: Hooks
  private let every: Duration
  private var onScreen = false
  private var inFlight = false
  private var misses = 0
  private var poll: Task<Void, Never>?
  private var done: (v: Int, tag: String, files: ReelFiles)?

  /// `site`: where the reel paths are served (https://throwingwood.com). `cache`: a
  /// directory under Caches, which iOS may empty; the video is downloaded again then.
  public init(
    code: String, site: URL, cache: URL, hooks: Hooks, every: Duration = .seconds(5)
  ) {
    self.code = code
    link = URL(string: "https://throwingwood.com/p/" + code)!
    self.site = site
    self.cache = cache
    self.hooks = hooks
    self.every = every
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
    case .idle: ask()
    case .making: ask()
    case .ready: if missing() { fetch() }
    case .asking, .fetching, .problem: break
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

  /// TRY AGAIN, after a failure (once) or with no connection.
  public func tryAgain() {
    switch phase {
    case .problem(.failed):
      retried = true
      ask()
    case .problem(.offline):
      misses = 0
      if done != nil { fetch() } else { ask() }
    default: break
    }
  }

  private func ask() {
    guard !inFlight else { return }
    guard hooks.reachable() else {
      poll?.cancel()
      phase = .problem(.offline)  // nothing is sent
      return
    }
    if phase != .making { phase = .asking }
    inFlight = true
    asked += 1
    Task { [weak self, hooks] in
      let answer: Result<ReelAnswer, Error>
      do { answer = .success(try await hooks.ask()) } catch { answer = .failure(error) }
      self?.answered(answer)
    }
  }

  private func answered(_ result: Result<ReelAnswer, Error>) {
    inFlight = false
    switch result {
    case .failure(let error):
      // A poll that is not answered is asked again; three in a row, or a first ask,
      // is no connection. An answer this build cannot read (a throttle, a reply it
      // does not know) is a failure TRY AGAIN may ask about once more.
      misses += 1
      if phase == .making, misses < 3 {
        schedule()
      } else if let room = error as? RoomError, room.code != "closed" {
        phase = .problem(retried ? .notThisTime : .failed)
      } else {
        phase = .problem(.offline)
      }
    case .success(let answer):
      misses = 0
      take(answer)
    }
  }

  private func take(_ answer: ReelAnswer) {
    switch answer {
    case .rendering:
      phase = .making
      schedule()
    case .done(let v, let tag, let files):
      done = (v, tag, files)
      fetch()
    case .failed(_, _, .empty): phase = .problem(.empty)
    case .failed, .notStarted: phase = .problem(retried ? .notThisTime : .failed)
    case .none(_, .engine): phase = .problem(.engine)
    case .none(_, .busy): phase = .problem(.busy)
    case .none(_, .replay): phase = .problem(.noReplay)
    case .none(_, .unavailable), .none(_, .other): phase = .problem(.unavailable)
    case .tooMany: phase = .problem(.tooMany)
    }
  }

  private func schedule() {
    poll?.cancel()
    guard onScreen else { return }
    poll = Task { [weak self, every] in
      do { try await Task.sleep(for: every) } catch { return }
      guard let self, self.onScreen, self.phase == .making else { return }
      self.ask()
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
        format = self.firstMissing()
      }
      guard let self else { return }
      self.inFlight = false
      self.phase = failed ? .problem(.offline) : .ready
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
  public static let fetching = "Your reel is ready. Bringing it to this phone."
  public static let share = "SHARE"
  public static let copyLink = "COPY LINK"
  public static let copied = "COPIED"
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
    case .busy: ("Reels are busy today. Try again tomorrow.", false)
    case .unavailable: ("Highlight reels cannot be made right now.", false)
    case .tooMany: ("That is as many reels as can be asked for at once. Try again later.", false)
    case .noReplay: ("This match has no replay, so it cannot have a reel.", false)
    }
  }

  /// The winner card's button for a reel as it stands.
  public static func button(_ phase: HighlightReel.Phase?) -> String {
    switch phase {
    case .asking, .making: making
    case .fetching, .ready: watch
    default: make
    }
  }
}
