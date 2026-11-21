import Foundation

/// The plain HTTPS calls that are not live play (the web's backend/api/API.md):
/// `report`, `game`, `replay`, `reel` and `share` at `<base><call>`, and the pitch
/// server's open games list (`GET /open`, PROTOCOL.md section 5 "open"). No member id,
/// no `Origin` header (the API answers a request without one as it is).
public struct PitchAPI: Sendable {
  public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  /// The API's base, ending in a slash: `https://throwingwood.com/api/` in production.
  public let base: URL
  public let appVersion: String
  /// Seconds an ordinary call may take; a share waits longer (`ShareLimits.wait`):
  /// the API plays the match first.
  public var timeout: TimeInterval = 10
  private let fetch: Fetch

  public init(base: URL, appVersion: String, fetch: Fetch? = nil) {
    self.base = base
    self.appVersion = appVersion
    self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
  }

  func request(_ call: String, query: [URLQueryItem] = [], body: JS? = nil, timeout: TimeInterval? = nil)
    -> URLRequest
  {
    var parts = URLComponents(url: base.appendingPathComponent(call), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { parts.queryItems = query }
    var request = URLRequest(url: parts.url!)
    request.timeoutInterval = timeout ?? self.timeout
    request.setValue("ThrowingWood/\(appVersion) (ios)", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(body.ascii.utf8)
    }
    return request
  }

  /// One call, its answer read. A refusal (`{ error, message }` with its status)
  /// throws its `error` code; a call that could not be made throws `timeout` or
  /// `closed` (the share card's "no connection").
  func call(_ request: URLRequest) async throws -> JSONNode {
    try await Self.send(request, fetch: fetch)
  }
  static func send(_ request: URLRequest, fetch: Fetch) async throws -> JSONNode {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await fetch(request)
    } catch let error as URLError {
      throw PitchError(error.code == .timedOut ? "timeout" : "closed")
    } catch let error as PitchError {
      throw error
    } catch {
      throw PitchError("closed")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
    let node = try? JSONNode.parse(String(decoding: data, as: UTF8.self))
    if let code = node?["error"]?.string {
      throw PitchError(code, node?["message"]?.string ?? "")
    }
    guard (200..<300).contains(status), let node, node.kind == .object else {
      throw PitchError(status == 503 ? "unavailable" : status >= 500 ? "failed" : "unexpected-reply")
    }
    return node
  }

  /// A record tagged as this app's: `client: "ios"`, and `engine` the record's own when
  /// it names one (a match on an older engine this build carries), else `engine` (left
  /// out when that is nil too).
  static func tagged(_ text: JSONText, engine: String?) throws -> JS {
    let node = try JSONNode.parse(text)
    guard node.kind == .object else { throw PitchError("bad-message") }
    let named = node["engine"]?.string ?? engine
    return .object(
      node.members.filter { $0.key != "client" && $0.key != "engine" }.map {
        ($0.key, JS.raw($0.value.raw))
      } + [("client", .string("ios"))] + (named.map { [("engine", JS.string($0))] } ?? []))
  }

  /// A throw report or feedback (`POST report { r }`), at most 64 KB.
  public func report(_ report: JSONText, engine: String? = nil) async throws {
    let body = JS.object([("r", try Self.tagged(report, engine: engine))])
    guard body.ascii.utf8.count <= 65_536 + 8 else { throw PitchError("too-big") }
    let reply = try await call(request("report", body: body))
    guard reply["ok"]?.bool == true else { throw PitchError("unexpected-reply") }
  }

  /// A match played on one device (`POST game { g }`).
  public func recordGame(_ game: JSONText, engine: String) async throws {
    let reply = try await call(request("game", body: .object([("g", try Self.tagged(game, engine: engine))])))
    guard reply["ok"]?.bool == true else { throw PitchError("unexpected-reply") }
  }

  static func checkCode(_ pitch: String) throws {
    guard pitch.range(of: "^[2-9a-hjkmnp-z]{8,24}$", options: .regularExpression) != nil else {
      throw PitchError("bad-pitch")
    }
  }

  /// The pitch's kept replay (`GET replay?pitch=`), which starts nothing: nil when it
  /// keeps none yet. `sealed` on the answer marks a shared match against the computer.
  public func replay(pitch: String) async throws -> KeptReplay? {
    try Self.checkCode(pitch)
    let reply = try await call(request("replay", query: [URLQueryItem(name: "pitch", value: pitch)]))
    return try KeptReplay.read(reply, pitch: pitch)
  }
  /// The pitch's highlight reel (`POST reel { pitch, v? }`). Asking how a reel stands
  /// is free; the first ask of a kept replay starts it. `v`: the kept replay the asker
  /// means; another is answered `why: "moved"`, starting nothing.
  public func reel(pitch: String, v: Int? = nil) async throws -> ReelAnswer {
    try Self.checkCode(pitch)
    if let v, v < 1 { throw PitchError("bad-message") }  // the API refuses it too
    var fields: [(String, JS)] = [("pitch", .string(pitch))]
    if let v { fields.append(("v", .int(v))) }
    do {
      return try ReelAnswer.read(try await call(request("reel", body: .object(fields))), pitch: pitch)
    } catch let error as PitchError where error.code == "failed" {
      return .notStarted
    }
  }

  /// A finished match against the computer shared (`POST share { g }`): the `g` of the
  /// share message (`ShareMessage.make`, the web's byte for byte). Waits
  /// `ShareLimits.wait`; the same match shared again gets the same code.
  public func share(_ message: JSONText) async throws -> ShareReply {
    let node = try JSONNode.parse(message)
    guard let g = node["g"], g.kind == .object else { throw PitchError("bad-message") }
    let wait = Double(ShareLimits.wait.components.seconds)
    let reply = try await call(request("share", body: .object([("g", .raw(g.raw))]), timeout: wait))
    return ShareReply.read(reply)
  }

  /// A thrown error as the share card's reducer takes it: the API's error code, or
  /// `closed` for a call that could not be made.
  public static func errorCode(_ error: Error) -> String {
    (error as? PitchError)?.code ?? "closed"
  }

  /// The pitch server's open games (`GET <pitch server>/open`), in its order.
  public static func openGames(
    server: URL, appVersion: String, fetch: Fetch? = nil
  ) async throws -> (now: Int, games: [OpenGame]) {
    var request = URLRequest(url: OpenGames.listURL(server))
    request.timeoutInterval = Double(OpenGames.deadline.components.seconds)
    request.setValue("ThrowingWood/\(appVersion) (ios)", forHTTPHeaderField: "User-Agent")
    let reply = try await send(request, fetch: fetch ?? { try await URLSession.shared.data(for: $0) })
    let now = Int(Date().timeIntervalSince1970 * 1000)
    guard let out = OpenGames.decode(reply, fallback: now) else { throw PitchError("unexpected-reply") }
    return out
  }
}
