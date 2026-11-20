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
    case other(String)
    init(_ code: String?) {
      switch code {
      case "unavailable": self = .unavailable
      case "replay": self = .replay
      case "engine": self = .engine
      case "busy": self = .busy
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
  /// the first ask of a kept replay starts it.
  public func reel() async throws -> ReelAnswer {
    let transport = newTransport()
    let id = UUID()
    reportSockets[id] = transport
    defer { reportSockets[id] = nil }
    return try await Self.askReel(room: code, transport: transport, timing: timing)
  }

  /// The same, for a pitch this device holds no client for (a winner card with only a
  /// code; a shared match against the computer later).
  public static func reel(
    room: String, url: URL, appVersion: String, timing: Timing = Timing(),
    factory: Factory = { WebSocketTransport(request: $0) }
  ) async throws -> ReelAnswer {
    guard room.range(of: "^[2-9a-hjkmnp-z]{8,24}$", options: .regularExpression) != nil else {
      throw RoomError("bad-room")
    }
    let transport = factory(socketRequest(url: url, appVersion: appVersion))
    return try await askReel(room: room, transport: transport, timing: timing)
  }

  static func askReel(room: String, transport: any RoomsTransport, timing: Timing) async throws
    -> ReelAnswer
  {
    let message = JS.object([("t", .string("reel")), ("id", .int(1)), ("room", .string(room))])
    let reply = try await exchange(message, transport: transport, timing: timing) { reply in
      let t = reply["t"]?.string
      return (t == "reel" || t == "error") && (reply["id"]?.int == 1 || reply["id"] == nil)
    }
    return try ReelAnswer.read(reply, room: room)
  }
}
