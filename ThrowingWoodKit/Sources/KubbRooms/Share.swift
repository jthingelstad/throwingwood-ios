import Foundation
import KubbEngine

// Sharing a match against the computer (the web's docs/REEL.md "Sharing a match against
// the computer", docs/ROOMS.md section 13, and its src/net/share.js, which this follows
// line for line): the name the share card allows, the `share` message made with the
// engine's own calls, what can be known before sending, and the card's states as a pure
// reducer. The card is the app's ShareCard.swift; once a code comes back the reel card
// takes over for it.
//
// What goes: the match's first snapshot and every action since, as the engine renames
// them (`renameStart`: side A takes the name typed on the card, so the name typed for
// the match never leaves the phone), the winner and the number of throws, the engine's
// version and `client: "ios"` (checked by the server, then dropped: never stored, as the
// web's "web" is not). No hashes, no member id, no device name, no clock of the phone's.
// The match's own start, with the day and time it began, is part of the first snapshot.

/// The server's ceilings and this side's wait (the web's SHARE_LIMITS).
public enum ShareLimits {
  /// The whole message, as ASCII JSON.
  public static let bytes = 256 * 1024
  public static let actions = 1000
  public static let startBytes = 16 * 1024
  /// Characters (code points) of the name on the reel.
  public static let nameMax = 16
  /// The server plays the match before answering: up to 20 s, and 30 s after the last part.
  public static let wait: Duration = .seconds(45)
}

/// The share card's words, the same on the web and the iPhone (the web's docs/REEL.md
/// "The share card" is the contract; `SHARE_WORDS` in its src/net/share.js).
public enum ShareWords {
  public static let title = "Share this match"
  public static let about =
    "To make a reel, this match goes to throwingwood.com and gets its own link. Anyone with the link can watch the replay and the reel, for a year."
  public static let label = "Name on the reel"
  public static let placeholder = "Your team's name"
  public static let sides =
    "Your side is shown by this name. The other side is Computer. Nothing else about you is sent."
  public static let when = "The score sheet shows the day and time the match was played."
  public static let share = "SHARE AND MAKE THE REEL"
  public static let notNow = "NOT NOW"
  public static let checking = "CHECKING THE MATCH"
  public static let checkingText = "This takes a few seconds."
  public static let link = "The link:"
  public static let failed = "This match could not be shared."
  public static let notThisTime = "This match could not be shared. Not this time."
  public static let offline = "No connection."
  public static let tryAgain = "TRY AGAIN"
  public static let back = "BACK"
  /// Why the name will not do (`ShareName.Problem`).
  public static func name(_ p: ShareName.Problem) -> String {
    switch p {
    case .empty: "Type a name for your side."
    case .you: #"A reel needs a name, not "You"."#
    case .long: "Up to 16 characters."
    case .spaces: "No spaces at the start or end."
    }
  }
  /// The line for each why the server (or this side) refuses with.
  public static func why(_ w: ShareWhy) -> String {
    switch w {
    case .engine: "This match was played on another version of the game, so it cannot be shared."
    case .doesNotReplay: "This match did not pass the check, so it cannot be shared."
    case .busy: "Sharing is busy right now. Try again later."
    case .tooLong: "This match is too long to share."
    case .unavailable: "Matches cannot be shared right now."
    case .tooMany: "Too many matches shared at once. Try again later."
    }
  }
  /// `https://throwingwood.com/p/` (the web's SHARE_URL).
  public static let url = "https://throwingwood.com/p/"
}

/// A refusal: the server's `why` codes, and the error `too-many`. Anything this build
/// does not know is `unavailable` (the web's `known`).
public enum ShareWhy: String, Equatable, Sendable, CaseIterable {
  case engine
  case doesNotReplay = "does-not-replay"
  case busy
  case tooLong = "too-long"
  case unavailable
  case tooMany = "too-many"

  public init(code: String?) { self = code.flatMap(ShareWhy.init(rawValue:)) ?? .unavailable }

  /// Refusals this phone cannot change: the card says them again when opened again.
  /// The rest (busy, unavailable, too-many) start over the next time it is opened.
  public var final: Bool { self == .engine || self == .doesNotReplay || self == .tooLong }
}

/// The name on the reel, as the server's check takes it (the web's nameProblem,
/// nameFromMatch and clipName; backend/reels/check.mjs nameAllowed).
public enum ShareName {
  public enum Problem: String, Equatable, Sendable { case empty, spaces, long, you }

  /// JavaScript's String.prototype.trim: white space and line terminators.
  public static func jsTrimmed(_ s: String) -> String {
    let ws: (Unicode.Scalar) -> Bool = { c in
      (c.properties.isWhitespace && c != "\u{85}") || c == "\u{FEFF}"
    }
    let scalars = Array(s.unicodeScalars)
    guard let a = scalars.firstIndex(where: { !ws($0) }), let b = scalars.lastIndex(where: { !ws($0) })
    else { return "" }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars[a...b])
    return String(out)
  }

  /// Nil when it may go on the reel, else why not: 1 to 16 characters (code points), no
  /// spaces around it, not "You" in any case. The card trims before asking.
  public static func problem(_ name: String) -> Problem? {
    let trimmed = jsTrimmed(name)
    if trimmed.isEmpty { return .empty }
    if name != trimmed { return .spaces }
    if name.unicodeScalars.count > ShareLimits.nameMax { return .long }
    if name.lowercased() == "you" { return .you }
    return nil
  }

  /// What the field starts with: the name typed for the match, unless it was the game's
  /// stand-in "You" (or nothing, or one the reel cannot take).
  public static func fromMatch(start: String) -> String {
    guard let n = (try? JSONNode.parse(start))?["opts"]?["teams"]?["A"]?["name"]?.string
    else { return "" }
    let t = jsTrimmed(n)
    return problem(t) == nil ? t : ""
  }

  /// A typed name cut to 16 characters (code points, as the server counts them).
  public static func clip(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    out.append(contentsOf: text.unicodeScalars.prefix(ShareLimits.nameMax))
    return String(out)
  }
}

/// A finished match of the person (side A) against the computer (side B), as this phone
/// keeps it: the first snapshot, every action since and the hash after each, the winner,
/// the engine it was played on, and the last snapshot when it is at hand.
public struct ShareSource: Sendable {
  public let engine: String
  public let start: String
  public let actions: [JSONText]
  public let hashes: [String]
  public let winner: String
  public let now: String?
  public init(
    engine: String, start: String, actions: [JSONText], hashes: [String] = [], winner: String,
    now: String? = nil
  ) {
    self.engine = engine
    self.start = start
    self.actions = actions
    self.hashes = hashes
    self.winner = winner
    self.now = now
  }

  /// Whether this may be shared at all (the web's `shareable`): side B alone is the
  /// computer, and there is at least one action.
  public var shareable: Bool {
    guard !actions.isEmpty, let cpu = (try? JSONNode.parse(start))?["opts"]?["cpu"] else {
      return false
    }
    if cpu.string == "B" { return true }
    return cpu.kind == .array && cpu.items.count == 1 && cpu.items[0].string == "B"
  }
}

/// The `share` message, or why it cannot go (known here, nothing sent).
public enum ShareMade: Equatable, Sendable {
  case message(JSONText, bytes: Int)
  case refused(ShareWhy)
}

public enum ShareMessage {
  static func majorMinor(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }

  /// A value the engine wrote, written again as the web writes it (JSON.stringify's
  /// numbers: the engine's Lua writes `-3.4353675656080334e-05` where JavaScript writes
  /// `-0.000034353675656080334`). The server reads both as the same value; this keeps
  /// the message byte for byte the web's.
  static func js(_ n: JSONNode) -> JS {
    switch n.kind {
    case .null: return .null
    case .bool: return .bool(n.bool ?? false)
    case .number: return .number(n.double ?? 0)
    case .string: return .string(n.string ?? "")
    case .array: return .array(n.items.map(js))
    case .object: return .object(n.members.map { ($0.key, js($0.value)) })
    }
  }

  /// The `share` message for a finished match, renamed by the engine, or a refusal when
  /// it is plainly past what the server keeps (the web's shareMessage). The engine drops
  /// a finished document's log past its LOG_BUDGET, and such a match has no replay: the
  /// log as the document would hold it (each action with the hash after it) and the last
  /// snapshot are both in that document, so when they alone pass the budget the match is
  /// too long. Short of that the server decides (13.4).
  ///
  /// `engine` makes the rename; the message names the engine the match was played on.
  /// A match played on another major.minor than this engine's is refused here (the
  /// server would say the same of a version it does not carry, and this engine's rename
  /// is not that version's).
  public static func make(engine: Engine, source: ShareSource, name: String, id: Int = 1) throws
    -> ShareMade
  {
    guard majorMinor(source.engine) == majorMinor(engine.engineVersion) else {
      return .refused(.engine)
    }
    let args = JS.object([
      ("start", .string(source.start)),
      ("names", .object([("A", .string(name))])),
      ("log", .array(source.actions.map { JS.object([("a", .raw($0))]) })),
    ])
    let out = try JSONNode.parse(engine.call("renameStart", json: args.ascii))
    guard let start = out["start"]?.string else { throw RoomError("bad-rename") }
    let log = out["log"]?.kind == .array ? out["log"]!.items : []
    let throwCount = log.filter { $0["a"]?["type"]?.string == "throw" }.count
    let g = JS.object([
      ("client", .string("ios")),
      ("engine", .string(source.engine)),
      ("start", .string(start)),
      ("log", .array(log.map(js))),
      ("end", .object([("winner", .string(source.winner)), ("throws", .int(throwCount))])),
    ])
    let message = JS.object([("t", .string("share")), ("id", .int(id)), ("g", g)])
    let text = message.ascii
    let bytes = text.utf8.count
    if bytes > ShareLimits.bytes || log.count > ShareLimits.actions
      || start.utf8.count > ShareLimits.startBytes
    {
      return .refused(.tooLong)
    }
    let budget = try JSONNode.parse(engine.call("room.constants"))["value"]?["LOG_BUDGET"]?.int
    let kept =
      JS.array(
        log.enumerated().map { i, e in
          JS.object([
            ("a", e["a"].map(js) ?? .null),
            ("h", .string(i < source.hashes.count ? source.hashes[i] : "")),
          ])
        }
      ).ascii.utf8.count + JS.string(source.now ?? "").ascii.utf8.count
    // a margin for the name's length in the last snapshot, which is the typed one
    if let budget, kept - 4096 > budget { return .refused(.tooLong) }
    return .message(JSONText(text), bytes: bytes)
  }
}

/// What the server said to a `share` (13.2): a code, or none and why.
public struct ShareReply: Equatable, Sendable {
  public let code: String?
  public let v: Int?
  public let why: String?
  public init(code: String?, v: Int?, why: String?) {
    self.code = code
    self.v = v
    self.why = why
  }

  /// One reply on the wire: `{ t: "shared", id, code, v, why? }`. Throws the error's code
  /// for an `error` (13.3).
  public static func read(_ reply: JSONNode) throws -> ShareReply {
    if reply["t"]?.string == "error" {
      throw RoomError(reply["code"]?.string ?? "bad-message", reply["message"]?.string ?? "", re: "share")
    }
    guard reply["t"]?.string == "shared" else { throw RoomError("unexpected-reply") }
    let code = reply["code"]?.string
    return ShareReply(
      code: code?.isEmpty == false ? code : nil, v: reply["v"]?.int, why: reply["why"]?.string)
  }
}

extension RoomsClient {
  /// One `share` message on a socket of its own, with no join and no member id, in parts
  /// when long (section 2.1), closed once answered. Waits 45 s for the answer: the server
  /// plays the match first. A share is idempotent on the server (the same start and log
  /// are answered the same code, free), so sending it again after a lost answer gives
  /// one link.
  public static func share(
    _ message: JSONText, url: URL, appVersion: String, timing: Timing? = nil,
    factory: Factory = { WebSocketTransport(request: $0) }
  ) async throws -> ShareReply {
    var wait = timing ?? Timing()
    if timing == nil { wait.answer = ShareLimits.wait }
    let transport = factory(socketRequest(url: url, appVersion: appVersion))
    let reply = try await exchange(.raw(message), transport: transport, timing: wait) { reply in
      let t = reply["t"]?.string
      let re = reply["re"]?.string
      return (t == "shared" || (t == "error" && (re == nil || re == "share")))
        && (reply["id"]?.int == 1 || reply["id"] == nil)
    }
    return try ShareReply.read(reply)
  }

  /// A thrown error as the share card's reducer takes it: the server's error code, or
  /// `closed` for a socket that closed or never opened, or ran out of time.
  public static func shareErrorCode(_ error: Error) -> String {
    if let room = error as? RoomError { return room.code }
    return "closed"
  }
}

// ---------- the card's states ----------
//
// idle      the name card (SHARE AND MAKE THE REEL, NOT NOW)
// sending   CHECKING THE MATCH, the slow bar
// shared    a code: the reel card takes over
// refused   a why, no TRY AGAIN; final ones stay, the others start over when opened
// error     no connection (TRY AGAIN as often as pressed) or the server could not keep
//           it (TRY AGAIN once)
// failed    the second such failure: "Not this time"

public struct ShareState: Equatable, Sendable {
  public enum Phase: String, Equatable, Sendable { case idle, sending, shared, refused, error, failed }
  public enum ErrorKind: String, Equatable, Sendable { case offline, failed }
  public enum Event: Equatable, Sendable {
    /// SHARE AND MAKE THE REEL, or TRY AGAIN.
    case send
    /// What `shared` said.
    case answer(ShareReply)
    /// What went wrong asking: the error's code (`too-many`, `too-big`, `bad-message`,
    /// `failed`; `timeout`, `closed`, `unavailable` for no connection).
    case error(String)
    /// Known here, nothing sent.
    case refuse(ShareWhy)
    /// The card opened again.
    case open
  }

  public private(set) var phase = Phase.idle
  public private(set) var code: String?
  public private(set) var v: Int?
  public private(set) var why: ShareWhy?
  public private(set) var error: ErrorKind?
  public private(set) var retried = 0
  public init() {}

  public func step(_ e: Event) -> ShareState {
    var s = self
    switch e {
    case .open:
      // the card opened again: a refusal that may pass later starts over
      if phase == .refused, let why, !why.final {
        s.phase = .idle
        s.why = nil
      }
    case .send:
      if phase == .idle {
        s.phase = .sending
        s.why = nil
      } else if phase == .error {
        if error == .failed, retried >= 1 {
          s.phase = .failed
        } else {
          if error == .failed { s.retried += 1 }
          s.phase = .sending
          s.error = nil
        }
      }
    case .refuse(let why):
      guard phase == .idle || phase == .sending else { return self }
      s.phase = .refused
      s.why = why
    case .answer(let a):
      guard phase == .sending else { return self }
      if let code = a.code {
        s.phase = .shared
        s.code = code
        s.v = a.v
        s.why = nil
      } else {
        s.phase = .refused
        s.why = ShareWhy(code: a.why)
      }
    case .error(let code):
      guard phase == .sending else { return self }
      switch code {
      case "too-many": s.phase = .refused; s.why = .tooMany
      case "too-big": s.phase = .refused; s.why = .tooLong
      case "bad-message": s.phase = .refused; s.why = .doesNotReplay
      case "timeout", "closed", "unavailable": s.phase = .error; s.error = .offline
      default:
        if retried >= 1 {
          s.phase = .failed
        } else {
          s.phase = .error
          s.error = .failed
        }
      }
    }
    return s
  }

  /// What the card shows for a state (the web's shareView).
  public struct View: Equatable, Sendable {
    public var phase: Phase
    public var line = ""
    public var text = ""
    public var bar = false
    public var retry = false
    public var form = false
    public var code: String?
  }

  public var view: View {
    var v = View(phase: phase, code: code)
    switch phase {
    case .idle: v.form = true
    case .sending:
      v.line = ShareWords.checking
      v.text = ShareWords.checkingText
      v.bar = true
    case .refused: v.text = ShareWords.why(why ?? .unavailable)
    case .failed: v.text = ShareWords.notThisTime
    case .error:
      v.text = error == .offline ? ShareWords.offline : ShareWords.failed
      v.retry = true
    case .shared: break
    }
    return v
  }
}
