import Foundation

/// A finished pitch's highlight reel as the API answers `POST reel` (the web's
/// backend/api/API.md "reel", docs/ROOMS.md section 12). Every
/// state and every why code has its own case; anything newer than this build knows
/// is kept in an `other` case, never guessed into a known one.
public enum ReelAnswer: Equatable, Sendable {
  /// Started (by this request or an earlier one): ask again a few seconds apart.
  case rendering(v: Int, tag: String)
  /// The files are on the site for good (a year), as site paths.
  case done(v: Int, tag: String, files: ReelFiles)
  /// Tried and not made. Final for this version of the match and this look.
  case failed(v: Int, tag: String, why: ReelFailure)
  /// No reel and none started (`reel: null`), and why.
  case none(v: Int, why: ReelWhy)
  /// This many renders started from here (the old rooms server's per-connection cap;
  /// the API has only the day's, answered `busy`). Kept for the card's words.
  case tooMany
  /// The error `failed`: the server could not read, ask for or start the reel. Nothing
  /// was kept, so asking again may start it.
  case notStarted

  /// Why there is no reel: the server's `why` codes when `reel` is null.
  public enum ReelWhy: Equatable, Sendable {
    /// This server has no renderer.
    case unavailable
    /// The pitch has no kept replay.
    case replay
    /// The match was played on an engine the renderer does not carry.
    case engine
    /// Today's renders have all started.
    case busy
    /// The pitch keeps another version than the request named (`v`): a newer match.
    /// Nothing was started or counted; the answer's `v` is the version kept now.
    case moved
    case other(String)
    init(_ code: String?) {
      switch code {
      case "unavailable": self = .unavailable
      case "replay": self = .replay
      case "engine": self = .engine
      case "busy": self = .busy
      case "moved": self = .moved
      default: self = .other(code ?? "")
      }
    }
  }

  /// Why a reel failed (`reel.why`).
  public enum ReelFailure: Equatable, Sendable {
    /// Tried twice and did not render.
    case render
    /// The match had nothing to show: no throw, or no moment picked.
    case empty
    /// Timed out on every try (the server names no why).
    case timedOut
    case other(String)
    init(_ code: String?) {
      switch code {
      case "render": self = .render
      case "empty": self = .empty
      case nil: self = .timedOut
      default: self = .other(code!)
      }
    }
  }

  /// One answer, read: `{ pitch, v, reel, why? }`, or a refusal `{ error, message }`
  /// (`failed`: nothing was started; any other code is thrown).
  public static func read(_ reply: JSONNode, pitch code: String) throws -> ReelAnswer {
    if let code = reply["error"]?.string {
      if code == "failed" { return .notStarted }
      throw PitchError(code, reply["message"]?.string ?? "")
    }
    guard reply["pitch"]?.string == code else { throw PitchError("unexpected-reply") }
    let v = reply["v"]?.int ?? 0
    guard let reel = reply["reel"], !reel.isNull else {
      return .none(v: v, why: ReelWhy(reply["why"]?.string))
    }
    let tag = reel["tag"]?.string ?? ""
    switch reel["state"]?.string {
    case "rendering": return .rendering(v: v, tag: tag)
    case "done":
      guard let files = ReelFiles(reel, pitch: code) else { throw PitchError("bad-reel") }
      return .done(v: v, tag: tag, files: files)
    case "failed": return .failed(v: v, tag: tag, why: ReelFailure(reel["why"]?.string))
    default: throw PitchError("bad-reel")
    }
  }
}

extension ReelAnswer {
  /// The kept replay's version the answer is about, when it names one.
  public var version: Int? {
    switch self {
    case .rendering(let v, _), .done(let v, _, _), .failed(let v, _, _): v
    case .none(let v, _): v == 0 ? nil : v
    case .tooMany, .notStarted: nil
    }
  }
}

/// What identifies a finished match on a pitch: its number and, when it has one, its
/// final hash as raw JSON (the engine's `pitch.replayOf`). A pitch that has had a
/// rematch keeps a newer match under the same code.
public struct ReelMatch: Equatable, Sendable {
  public let n: Int
  public let hash: String?
  public init(n: Int, hash: String?) {
    self.n = n
    self.hash = hash
  }
}

/// The pitch's kept replay as `GET replay` gives it (the web's `askKept`): its
/// version, the match it is of, and whether the pitch is sealed.
public struct KeptReplay: Equatable, Sendable {
  public let v: Int
  public let n: Int?
  public let hash: String?
  /// The finished match's last snapshot (`snap`), when the replay carries one: a sealed
  /// pitch (a shared match) is shown from it.
  public let snap: String?
  /// The engine the match was played on (`engine`, `pitch.replayOf`'s copy of
  /// `match.engine`), when the replay names one.
  public let engine: String?
  /// A shared match against the computer: the pitch never plays again (API.md "replay").
  public let sealed: Bool
  public init(
    v: Int, n: Int?, hash: String?, snap: String? = nil, engine: String? = nil, sealed: Bool = false
  ) {
    self.sealed = sealed
    self.v = v
    self.n = n
    self.hash = hash
    self.snap = snap
    self.engine = engine
  }

  /// Whether this kept replay is `match` (always, with nothing to compare): the same
  /// number, and the same hash when both have one.
  public func isMatch(_ match: ReelMatch?) -> Bool {
    guard let match else { return true }
    return n == match.n && (match.hash == nil || hash == nil || hash == match.hash)
  }

  /// A replay's hash as text: a string as itself, anything else as its JSON.
  public static func hashText(_ node: JSONNode?) -> String? {
    guard let node, !node.isNull else { return nil }
    return node.string ?? node.raw.text
  }

  /// One answer: `{ pitch, v, at, sealed, replay }`. Nil when the pitch keeps none.
  /// Throws for a refusal.
  public static func read(_ reply: JSONNode, pitch code: String) throws -> KeptReplay? {
    if let code = reply["error"]?.string {
      throw PitchError(code, reply["message"]?.string ?? "")
    }
    guard reply["pitch"]?.string == code else { throw PitchError("unexpected-reply") }
    guard let v = reply["v"]?.int, v > 0, let r = reply["replay"], !r.isNull else { return nil }
    return KeptReplay(v: v, n: r["n"]?.int, hash: hashText(r["hash"]), snap: r["snap"]?.string,
      engine: r["engine"]?.string, sealed: reply["sealed"]?.bool == true)
  }
}

/// A done reel's files, as site paths under `/reels/<code>/`.
public struct ReelFiles: Equatable, Sendable {
  public let tall: String
  public let wide: String
  public let seconds: Double?
  public init?(tall: String, wide: String, seconds: Double? = nil, pitch room: String) {
    // Only the site's own reel paths are taken: nothing else is ever downloaded.
    let ok = { (p: String) in
      p.hasPrefix("/reels/\(room)/") && p.hasSuffix(".mp4") && !p.contains("..")
        && !p.contains("?") && !p.contains("#") && !p.contains("//")
    }
    guard ok(tall), ok(wide) else { return nil }
    self.tall = tall
    self.wide = wide
    self.seconds = seconds
  }
  init?(_ reel: JSONNode, pitch room: String) {
    guard let tall = reel["tall"]?.string, let wide = reel["wide"]?.string else { return nil }
    self.init(tall: tall, wide: wide, seconds: reel["seconds"]?.double, pitch: room)
  }
}
