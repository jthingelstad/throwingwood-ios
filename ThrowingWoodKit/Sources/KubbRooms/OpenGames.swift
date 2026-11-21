import Foundation

/// One open pitch from the rooms server's read-only `list` (the web's docs/ROOMS.md
/// section 9): how many are on it, of how many places, whether it has started and when
/// it was made. Never a name.
public struct OpenGame: Equatable, Sendable, Identifiable {
  public let room: String
  public let made, players, seats: Int
  public let state: String
  public var id: String { room }
  public init(room: String, made: Int, players: Int, seats: Int, state: String) {
    self.room = room
    self.made = made
    self.players = players
    self.seats = seats
    self.state = state
  }
}

/// The Open games list where the online entry is (the web's public/js/open-games.js,
/// its words and rules): a socket of its own for each look, `{t:"list", id:1}`, closed as
/// soon as the answer comes, at most every 30 s while the screen shows. Each row has
/// JOIN (its link) and WATCH (the same pitch as an observer).
public enum OpenGames {
  public static let title = "Open games"
  public static let intro = "These pitches are open to anyone. Join one and pick a side, or watch a match."
  public static let looking = "Looking for open games..."
  public static let empty = "No open games right now. Start a pitch and make it open, and it shows here."
  public static let failed = "The open games could not be loaded just now."
  /// s between looks while the list shows (the web's EVERY).
  public static let every: Duration = .seconds(30)
  /// The answer's deadline for each look (the web's guard).
  public static let deadline: Duration = .seconds(10)

  /// The rooms server's code pattern: a row with any other code is left out.
  static func isCode(_ code: String) -> Bool {
    code.range(of: "^[2-9a-hjkmnp-z]{8,24}$", options: .regularExpression) != nil
  }

  /// The games in a `list` answer, in its order, with its clock (`now`, ms; `fallback`
  /// when it has none). nil for any other message.
  public static func decode(_ reply: JSONNode, fallback: Int) -> (now: Int, games: [OpenGame])? {
    guard reply["t"]?.string == "list", let rows = reply["games"], rows.kind == .array else { return nil }
    let now = reply["now"]?.double.map { Int($0) } ?? fallback
    let games = rows.items.compactMap { g -> OpenGame? in
      guard g.kind == .object, let room = g["room"]?.string, isCode(room) else { return nil }
      return OpenGame(
        room: room, made: g["made"]?.double.map { Int($0) } ?? now,
        players: g["players"]?.double.map { Int($0) } ?? 0,
        seats: g["seats"]?.double.map { Int($0) } ?? 0,
        state: g["state"]?.string ?? "")
    }
    return (now, games)
  }

  /// "made just now", "made 4 min ago", "made 1 hour ago", "made 3 hours ago".
  public static func ago(_ ms: Int) -> String {
    let min = max(0, ms) / 60000
    if min < 1 { return "made just now" }
    if min < 60 { return "made \(min) min ago" }
    let h = min / 60
    return "made \(h)" + (h == 1 ? " hour ago" : " hours ago")
  }

  /// A row's words: "3 of 12 on the pitch · in play · made 4 min ago".
  public static func line(_ g: OpenGame, now: Int) -> String {
    "\(g.players) of \(g.seats) on the pitch · \(g.state == "playing" ? "in play" : "waiting to start") · \(ago(now - g.made))"
  }

  /// One look: the `list` message on a socket of its own (no member, no join), the
  /// answer read and the socket closed. Throws when the server answers with an error,
  /// closes, or says nothing within 10 s.
  @MainActor public static func look(url: URL, appVersion: String) async throws -> (now: Int, games: [OpenGame]) {
    var timing = RoomsClient.Timing()
    timing.answer = deadline
    let transport = WebSocketTransport(request: RoomsClient.socketRequest(url: url, appVersion: appVersion))
    return try await look(transport: transport, timing: timing)
  }

  @MainActor static func look(transport: any RoomsTransport, timing: RoomsClient.Timing) async throws
    -> (now: Int, games: [OpenGame])
  {
    let message = JS.object([("t", .string("list")), ("id", .int(1))])
    let reply = try await RoomsClient.exchange(message, transport: transport, timing: timing) {
      ($0["t"]?.string == "list" && $0["games"]?.kind == .array) || $0["t"]?.string == "error"
    }
    let now = Int(Date().timeIntervalSince1970 * 1000)
    guard let out = decode(reply, fallback: now) else {
      throw RoomError(reply["code"]?.string ?? "unexpected-reply")
    }
    return out
  }
}
