import Foundation

/// A finished pitch's highlight reel as the rooms server answers a `reel` request
/// (the web's docs/ROOMS.md section 12, `backend/rooms/core.mjs` `reel`). Every
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
  /// The error `too-many`: this connection has started as many renders as it may.
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
    /// The room keeps another version than the request named (`v`): a newer match.
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

  /// One reply on the wire, read: `{ t: "reel", id, room, v, reel, why? }` or an
  /// `error`. Throws for an error code that is not a reel's (`bad-room`, a throttle).
  public static func read(_ reply: JSONNode, room: String) throws -> ReelAnswer {
    if reply["t"]?.string == "error" {
      switch reply["code"]?.string {
      case "too-many": return .tooMany
      case "failed": return .notStarted
      case let code: throw RoomError(code ?? "bad-message", reply["message"]?.string ?? "")
      }
    }
    guard reply["t"]?.string == "reel", reply["room"]?.string == room else {
      throw RoomError("unexpected-reply")
    }
    let v = reply["v"]?.int ?? 0
    guard let reel = reply["reel"], !reel.isNull else {
      return .none(v: v, why: ReelWhy(reply["why"]?.string))
    }
    let tag = reel["tag"]?.string ?? ""
    switch reel["state"]?.string {
    case "rendering": return .rendering(v: v, tag: tag)
    case "done":
      guard let files = ReelFiles(reel, room: room) else { throw RoomError("bad-reel") }
      return .done(v: v, tag: tag, files: files)
    case "failed": return .failed(v: v, tag: tag, why: ReelFailure(reel["why"]?.string))
    default: throw RoomError("bad-reel")
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
/// final hash as raw JSON (the engine's `room.replayOf`). A pitch that has had a
/// rematch keeps a newer match under the same code.
public struct ReelMatch: Equatable, Sendable {
  public let n: Int
  public let hash: String?
  public init(n: Int, hash: String?) {
    self.n = n
    self.hash = hash
  }
}

/// The room's kept replay as the read-only `replay` fetch gives it (the web's
/// `askKept`): its version, and the match it is of.
public struct KeptReplay: Equatable, Sendable {
  public let v: Int
  public let n: Int?
  public let hash: String?
  /// The finished match's last snapshot (`snap`), when the replay carries one: a sealed
  /// pitch (a shared match) is shown from it.
  public let snap: String?
  /// The engine the match was played on (`engine`, `room.replayOf`'s copy of
  /// `match.engine`), when the replay names one.
  public let engine: String?
  public init(v: Int, n: Int?, hash: String?, snap: String? = nil, engine: String? = nil) {
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

  /// One reply on the wire: `{ t: "replay", id, room, v, at, replay }`. Nil when the
  /// room keeps none. Throws for an `error`.
  public static func read(_ reply: JSONNode, room: String) throws -> KeptReplay? {
    if reply["t"]?.string == "error" {
      throw RoomError(reply["code"]?.string ?? "bad-message", reply["message"]?.string ?? "")
    }
    guard reply["t"]?.string == "replay", reply["room"]?.string == room else {
      throw RoomError("unexpected-reply")
    }
    guard let v = reply["v"]?.int, let r = reply["replay"], !r.isNull else { return nil }
    return KeptReplay(v: v, n: r["n"]?.int, hash: hashText(r["hash"]), snap: r["snap"]?.string,
      engine: r["engine"]?.string)
  }
}

/// A done reel's files, as site paths under `/reels/<code>/`.
public struct ReelFiles: Equatable, Sendable {
  public let tall: String
  public let wide: String
  public let seconds: Double?
  public init?(tall: String, wide: String, seconds: Double? = nil, room: String) {
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
  init?(_ reel: JSONNode, room: String) {
    guard let tall = reel["tall"]?.string, let wide = reel["wide"]?.string else { return nil }
    self.init(tall: tall, wide: wide, seconds: reel["seconds"]?.double, room: room)
  }
}

extension RoomsClient {
  /// This pitch's highlight reel: one `reel` request on a socket of its own, with no
  /// join and no member id, closed once answered. Asking how a reel stands is free;
  /// the first ask of a kept replay starts it. `v`: the kept replay version the asker
  /// means (from the `replay` fetch); the server then answers `why: "moved"` for any
  /// other, starting nothing. Left out, the server takes whatever it keeps.
  public func reel(v: Int? = nil) async throws -> ReelAnswer {
    let transport = newTransport()
    let id = UUID()
    reportSockets[id] = transport
    defer { reportSockets[id] = nil }
    return try await Self.askReel(room: code, v: v, transport: transport, timing: timing)
  }

  /// The same, for a pitch this device holds no client for (a winner card with only a
  /// code; a shared match against the computer later).
  public static func reel(
    room: String, v: Int? = nil, url: URL, appVersion: String, timing: Timing = Timing(),
    factory: Factory = { WebSocketTransport(request: $0) }
  ) async throws -> ReelAnswer {
    guard room.range(of: "^[2-9a-hjkmnp-z]{8,24}$", options: .regularExpression) != nil else {
      throw RoomError("bad-room")
    }
    if let v, v < 1 { throw RoomError("bad-message") }  // the server refuses it too
    let transport = factory(socketRequest(url: url, appVersion: appVersion))
    return try await askReel(room: room, v: v, transport: transport, timing: timing)
  }

  static func askReel(room: String, v: Int?, transport: any RoomsTransport, timing: Timing)
    async throws -> ReelAnswer
  {
    // `v` is a positive integer or absent, never null
    if let v, v < 1 { throw RoomError("bad-message") }
    var fields: [(String, JS)] = [("t", .string("reel")), ("id", .int(1)), ("room", .string(room))]
    if let v { fields.append(("v", .int(v))) }
    let message = JS.object(fields)
    let reply = try await exchange(message, transport: transport, timing: timing) { reply in
      let t = reply["t"]?.string
      return (t == "reel" || t == "error") && (reply["id"]?.int == 1 || reply["id"] == nil)
    }
    return try ReelAnswer.read(reply, room: room)
  }

  /// The room's kept replay, read with the `replay` fetch, which starts nothing: the
  /// reel card checks it is the match on the screen before it asks for a reel.
  public static func kept(
    room: String, url: URL, appVersion: String, timing: Timing = Timing(),
    factory: Factory = { WebSocketTransport(request: $0) }
  ) async throws -> KeptReplay? {
    guard room.range(of: "^[2-9a-hjkmnp-z]{8,24}$", options: .regularExpression) != nil else {
      throw RoomError("bad-room")
    }
    let transport = factory(socketRequest(url: url, appVersion: appVersion))
    let message = JS.object([("t", .string("replay")), ("id", .int(1)), ("room", .string(room))])
    let reply = try await exchange(message, transport: transport, timing: timing) { reply in
      let t = reply["t"]?.string
      return (t == "replay" || t == "error") && (reply["id"]?.int == 1 || reply["id"] == nil)
    }
    return try KeptReplay.read(reply, room: room)
  }
}
