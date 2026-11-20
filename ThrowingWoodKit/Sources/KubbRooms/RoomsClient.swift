import Foundation

/// The room wire, with serial compare-and-set reducers and reconnect settlement.
/// All state and callbacks live on the main actor; the Lua engine never crosses actors.
@MainActor public final class RoomsClient {
  public enum Status: String, Sendable { case connecting, open, reconnecting, closed, replaced }
  public enum Event: Sendable {
    case status(Status)
    case state, members, host
    case left(String)
    case document(v: Int, doc: JSONText, rider: JSONText?, mine: Bool)
    /// Cast, pong, reported, recorded, list, replay and errors retain their wire text.
    case message(JSONNode)
  }
  public struct Timing: Sendable {
    public var retry: Duration = .milliseconds(500)
    public var retryMax: Duration = .seconds(15)
    public var answer: Duration = .seconds(10)
    public var ping: Duration = .seconds(240)
    public var pong: Duration = .seconds(15)
    public init() {}
  }
  public typealias Reducer = @MainActor (JSONText) throws -> JSONText?
  public typealias Factory = @MainActor (URLRequest) -> any RoomsTransport

  public let code: String
  public let you: String
  public let engineVersion: String
  public private(set) var status: Status = .closed
  public private(set) var host: String?
  public private(set) var members: [JSONNode] = []
  public private(set) var version = 0
  public private(set) var document = JSONText.null
  public private(set) var by: String?
  public private(set) var limits: JSONNode?
  public var isHost: Bool { host == you }
  public var membersJSON: JS { .array(members.map { .raw($0.raw) }) }

  private let url: URL
  private let appVersion: String
  private let factory: Factory
  /// Each timer takes the value as it starts. Settable inside the module so a test
  /// can let exactly one answer be late.
  var timing: Timing
  private var me: [(String, JS)]
  private var observers: [UUID: @MainActor (Event) -> Void] = [:]
  private var socket: (any RoomsTransport)?
  private var generation = 0
  private var stopped = true
  private var joinedOnce = false
  private var joined = false
  private var attempt = 0
  private var sequence = 0
  private var memberRevs: [String: Int] = [:]
  private var hostRev = 0
  private var parts = Frames.Reassembler()
  private var reader: Task<Void, Never>?
  private var retry: Task<Void, Never>?
  private var pinger: Task<Void, Never>?
  private var pongTimer: Task<Void, Never>?
  private var joinTimer: Task<Void, Never>?
  private var afterJoin: [CheckedContinuation<Void, Error>] = []
  private var updateTail: Task<Void, Never>?
  private var sendTail: Task<Void, Never>?

  private struct SetWait {
    let base: Int
    let doc: JSONText
    let rider: JSONText?
    let answer: CheckedContinuation<Bool, Error>
    let timer: Task<Void, Never>
    var lost = false
  }
  private struct AskWait {
    let answer: CheckedContinuation<JSONNode, Error>
    let timer: Task<Void, Never>
  }
  private var sets: [Int: SetWait] = [:]
  private var asks: [Int: AskWait] = [:]

  public init(
    url: URL, room: String, engineVersion: String, appVersion: String,
    me: [(String, JS)] = [], store: any MemberIDStore = DeviceMemberIDStore(),
    timing: Timing = Timing(), factory: @escaping Factory = { WebSocketTransport(request: $0) }
  ) throws {
    guard room.range(of: "^[2-9a-hjkmnp-z]{8,24}$", options: .regularExpression) != nil else {
      throw RoomError("bad-room")
    }
    self.url = url
    code = room
    self.engineVersion = engineVersion
    self.appVersion = appVersion
    self.factory = factory
    self.timing = timing
    self.me = me.filter { $0.0 != "engine" } + [("engine", .string(engineVersion))]
    if let id = store.load(),
      id.range(of: "^[A-Za-z0-9_-]{8,40}$", options: .regularExpression) != nil
    {
      you = id
    } else {
      let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
      you = String((0..<16).map { _ in alphabet.randomElement()! })
      store.save(you)
    }
  }

  @discardableResult public func observe(_ fn: @escaping @MainActor (Event) -> Void) -> UUID {
    let id = UUID()
    observers[id] = fn
    return id
  }
  public func removeObserver(_ id: UUID) { observers[id] = nil }
  private func emit(_ event: Event) { for fn in Array(observers.values) { fn(event) } }
  private func setStatus(_ next: Status) {
    if status != next {
      status = next
      emit(.status(next))
    }
  }

  public func connect() {
    guard stopped, status != .replaced else { return }
    stopped = false
    open()
  }
  public func ready() async throws {
    if joined { return }
    if stopped { throw RoomError(status == .replaced ? "replaced" : "closed") }
    try await withCheckedThrowingContinuation { afterJoin.append($0) }
  }

  static func socketRequest(url: URL, appVersion: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("https://app.throwingwood.com", forHTTPHeaderField: "Origin")
    request.setValue("ThrowingWood/\(appVersion) (ios)", forHTTPHeaderField: "User-Agent")
    return request
  }
  func newTransport() -> any RoomsTransport {
    factory(Self.socketRequest(url: url, appVersion: appVersion))
  }
  private func open() {
    guard !stopped else { return }
    generation += 1
    let gen = generation
    setStatus(joinedOnce ? .reconnecting : .connecting)
    let transport = newTransport()
    socket = transport
    reader = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let frame = try await transport.receive()
          guard let self, self.generation == gen else { return }
          self.receive(frame)
        }
      } catch { self?.disconnected(gen) }
    }
    var fields: [(String, JS)] = [
      ("t", .string("join")), ("room", .string(code)),
      ("member", .string(you)), ("me", .object(me)),
    ]
    if version > 0 { fields.append(("v", .int(version))) }
    enqueue(.object(fields))
    joinTimer = Task { [weak self, timing] in
      do { try await Task.sleep(for: timing.answer) } catch { return }
      self?.disconnected(gen)
    }
  }

  private func disconnected(_ gen: Int) {
    guard generation == gen, !stopped else { return }
    generation += 1
    socket?.close()
    socket = nil
    reader?.cancel()
    joinTimer?.cancel()
    pinger?.cancel()
    pongTimer?.cancel()
    parts.reset()
    joined = false
    for id in Array(sets.keys) {
      sets[id]?.lost = true
      sets[id]?.timer.cancel()
    }
    for id in Array(asks.keys) { finishAsk(id, .failure(RoomError("uncertain"))) }
    setStatus(joinedOnce ? .reconnecting : .connecting)
    let seconds = min(Double(attempt), 5)
    let delay =
      min(timing.retry * pow(2, seconds), timing.retryMax) * Double.random(in: 0.75...1.25)
    attempt += 1
    retry?.cancel()
    retry = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      self?.open()
    }
  }

  /// Serialized sends keep all chunks together. The generation guard drops queued
  /// frames for a socket that has since closed, including a delayed join or leave.
  private func enqueue(_ value: JS) {
    let previous = sendTail
    let gen = generation
    let transport = socket
    let text = value.ascii
    let frame = max(Frames.head + 1, min(30_000, limits?["frame"]?.int ?? 30_000))
    sendTail = Task { [weak self] in
      await previous?.value
      guard let self, self.generation == gen, let transport else { return }
      do {
        for part in Frames.split(text, frame: frame) {
          guard self.generation == gen else { return }
          try await transport.send(part)
        }
      } catch { self.disconnected(gen) }
    }
  }

  private func adopt(
    _ v: Int, _ doc: JSONText, _ writer: String?, rider: JSONText? = nil, mine: Bool = false
  ) {
    guard v > version else { return }
    version = v
    document = doc
    by = writer
    emit(.document(v: v, doc: doc, rider: rider, mine: mine))
  }

  /// Internal so injected transports and ordering tests exercise the same reader.
  func receive(_ frame: String) {
    guard let text = parts.accept(frame), let msg = try? JSONNode.parse(text) else { return }
    let id = msg["id"]?.int
    switch msg["t"]?.string {
    case "joined":
      joinTimer?.cancel()
      attempt = 0
      limits = msg["limits"]
      host = msg["host"]?.string
      hostRev = msg["rev"]?.int ?? 0
      members = msg["members"]?.items ?? []
      memberRevs = Dictionary(
        uniqueKeysWithValues: members.compactMap { m in
          m["id"]?.string.map { ($0, hostRev) }
        })
      // A join is authoritative even when the old room expired and its version
      // restarted at zero. Ordinary doc/ok/no frames still only move forward.
      if let doc = msg["doc"] {
        version = msg["v"]?.int ?? 0
        document = doc.raw
        by = msg["by"]?.string
      }
      joined = true
      joinedOnce = true
      for id in Array(sets.keys) {
        guard let w = sets[id], w.lost else { continue }
        if msg["sid"]?.string == String(id), msg["by"]?.string == you {
          finishSet(id, .success(true))
        } else if msg["v"]?.int == w.base {
          finishSet(id, .success(false))
        } else {
          finishSet(id, .failure(RoomError("uncertain")))
        }
      }
      setStatus(.open)
      emit(.state)
      emit(.members)
      let waits = afterJoin
      afterJoin.removeAll()
      for wait in waits { wait.resume() }
      startPing()
    case "member", "left":
      let member = msg["member"]
      guard let key = member?["id"]?.string ?? msg["id"]?.string,
        let rev = msg["rev"]?.int, rev > (memberRevs[key] ?? 0)
      else { return }
      memberRevs[key] = rev
      members.removeAll { $0["id"]?.string == key }
      if let member { members.append(member) } else { emit(.left(key)) }
      members.sort { ($0["joined"]?.int ?? 0) < ($1["joined"]?.int ?? 0) }
      emit(.members)
    case "host":
      guard let rev = msg["rev"]?.int, rev > hostRev else { return }
      hostRev = rev
      host = msg["host"]?.string
      emit(.host)
    case "doc":
      adopt(
        msg["v"]?.int ?? 0, msg["doc"]?.raw ?? .null, msg["by"]?.string, rider: msg["with"]?.raw)
    case "ok":
      if let id, let w = sets[id] {
        adopt(msg["v"]?.int ?? 0, w.doc, you, rider: w.rider, mine: true)
        finishSet(id, .success(true))
      }
    case "no":
      adopt(msg["v"]?.int ?? 0, msg["doc"]?.raw ?? .null, msg["by"]?.string)
      if let id { finishSet(id, .success(false)) }
    case "pong": pongTimer?.cancel()
    case "error":
      let error = RoomError(
        msg["code"]?.string ?? "bad-message", msg["message"]?.string ?? "", re: msg["re"]?.string)
      if error.code == "replaced" {
        close(as: .replaced, error: error)
      } else if error.re == "join" {
        if error.code == "busy" {
          disconnected(generation)
        } else {
          close(as: .closed, error: error)
        }
      } else if let id, error.re == "set" {
        finishSet(id, .failure(error))
      }
      if let id { finishAsk(id, .failure(error)) }
    default:
      if let id { finishAsk(id, .success(msg)) }
    }
    emit(.message(msg))
  }

  private func startPing() {
    pinger?.cancel()
    pinger = Task { [weak self, timing] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: timing.ping) } catch { return }
        guard let self, self.joined else { return }
        self.enqueue(.object([("t", .string("ping"))]))
        let gen = self.generation
        self.pongTimer?.cancel()
        self.pongTimer = Task { [weak self] in
          do { try await Task.sleep(for: timing.pong) } catch { return }
          self?.disconnected(gen)
        }
      }
    }
  }

  private func finishSet(_ id: Int, _ result: Result<Bool, Error>) {
    guard let wait = sets.removeValue(forKey: id) else { return }
    wait.timer.cancel()
    wait.answer.resume(with: result)
  }
  private func finishAsk(_ id: Int, _ result: Result<JSONNode, Error>) {
    guard let wait = asks.removeValue(forKey: id) else { return }
    wait.timer.cancel()
    wait.answer.resume(with: result)
  }

  /// Reducers run again only after an explicit conflict or proof that a lost set did
  /// not land. Cancellation closes this client's pending work through close().
  @discardableResult public func update(
    rider: JSONText? = nil, retries: Int = 20,
    _ reduce: @escaping Reducer
  ) async throws -> JSONText? {
    let previous = updateTail
    let task = Task { [self] () throws -> JSONText? in
      await previous?.value
      for _ in 0...max(0, retries) {
        try await ready()
        guard let doc = try reduce(document) else { return nil }
        guard ASCIIJSON.asciify(doc.text).utf8.count <= (limits?["docBytes"]?.int ?? 262_144),
          rider.map({ ASCIIJSON.asciify($0.text).utf8.count <= (limits?["withBytes"]?.int ?? 4096) }
          ) ?? true
        else {
          throw RoomError("too-big")
        }
        let base = version
        sequence += 1
        let id = sequence
        let landed: Bool = try await withCheckedThrowingContinuation { answer in
          let gen = generation
          let timer = Task { [weak self, timing] in
            do { try await Task.sleep(for: timing.answer) } catch { return }
            if self?.sets[id] != nil { self?.disconnected(gen) }
          }
          sets[id] = SetWait(base: base, doc: doc, rider: rider, answer: answer, timer: timer)
          var fields: [(String, JS)] = [
            ("t", .string("set")), ("id", .int(id)),
            ("base", .int(base)), ("doc", .raw(doc)),
          ]
          if let rider { fields.append(("with", .raw(rider))) }
          enqueue(.object(fields))
        }
        if landed { return doc }
      }
      throw RoomError("busy")
    }
    updateTail = Task { _ = try? await task.value }
    return try await task.value
  }

  /// A correlated wire request (game/report/list/replay). Raw fields go through as text.
  public func request(_ type: String, fields: [(String, JS)] = []) async throws -> JSONNode {
    try await ready()
    sequence += 1
    let id = sequence
    return try await withCheckedThrowingContinuation { answer in
      let timer = Task { [weak self, timing] in
        do { try await Task.sleep(for: timing.answer) } catch { return }
        self?.finishAsk(id, .failure(RoomError("uncertain")))
      }
      asks[id] = AskWait(answer: answer, timer: timer)
      enqueue(.object([("t", .string(type)), ("id", .int(id))] + fields))
    }
  }

  private func tagged(_ text: JSONText) throws -> JS {
    let node = try JSONNode.parse(text)
    guard node.kind == .object else { throw RoomError("bad-message") }
    return .object(
      node.members.filter { $0.key != "client" && $0.key != "engine" }.map {
        ($0.key, JS.raw($0.value.raw))
      } + [("client", .string("ios")), ("engine", .string(engineVersion))])
  }
  public func recordGame(_ game: JSONText) async throws -> JSONNode {
    try await request("game", fields: [("g", tagged(game))])
  }
  public func report(_ report: JSONText) async throws -> JSONNode {
    try await request("report", fields: [("r", tagged(report))])
  }

  /// Reports and reel requests use an unjoined socket each. There is no member
  /// identity on these requests. Closing the client closes them.
  var reportSockets: [UUID: any RoomsTransport] = [:]
  public func sendPitchReport(_ report: JSONText) async throws {
    let transport = newTransport()
    let id = UUID()
    reportSockets[id] = transport
    defer { reportSockets[id] = nil }
    try await Self.deliverReport(tagged(report), transport: transport, timing: timing)
  }

  /// Practice and solo use this sender without joining a room or creating a member ID.
  public static func sendReport(_ report: JSONText, url: URL, appVersion: String) async throws {
    let request = socketRequest(url: url, appVersion: appVersion)
    try await deliverReport(.raw(report), transport: WebSocketTransport(request: request), timing: Timing())
  }

  private static func deliverReport(_ report: JS, transport: any RoomsTransport, timing: Timing) async throws {
    let message = JS.object([("t", .string("report")), ("id", .int(1)), ("r", report)])
    guard message.ascii.utf8.count <= 65536 else {
      transport.close()
      throw RoomError("too-big")
    }
    let reply = try await exchange(message, transport: transport, timing: timing) { _ in true }
    if reply["t"]?.string == "reported", reply["id"]?.int == 1 { return }
    throw RoomError(reply["code"]?.string ?? "unexpected-reply")
  }

  /// One message on a socket of its own, and the first reply `accept` takes; the
  /// socket is closed after. An unanswered message fails at the answer deadline.
  static func exchange(
    _ message: JS, transport: any RoomsTransport, timing: Timing,
    accept: (JSONNode) -> Bool
  ) async throws -> JSONNode {
    defer { transport.close() }
    let deadline = Task { [timing] in
      do { try await Task.sleep(for: timing.answer) } catch { return }
      transport.close()
    }
    defer { deadline.cancel() }
    for part in Frames.split(message.ascii) { try await transport.send(part) }
    var parts = Frames.Reassembler()
    while true {
      guard let text = parts.accept(try await transport.receive()) else { continue }
      let reply = try JSONNode.parse(text)
      if accept(reply) { return reply }
    }
  }

  public func setMe(_ fields: [(String, JS)]) {
    for (key, value) in fields {
      me.removeAll { $0.0 == key }
      if value != .null { me.append((key, value)) }
    }
    if joined { enqueue(.object([("t", .string("me")), ("me", .object(fields))])) }
  }
  @discardableResult public func send(_ type: String, fields: [(String, JS)] = []) -> Bool {
    guard joined else { return false }
    enqueue(.object([("t", .string(type))] + fields))
    return true
  }
  @discardableResult public func cast(_ value: JSONText) -> Bool {
    send("cast", fields: [("d", .raw(value))])
  }
  @discardableResult public func claimHost() -> Bool { send("claim") }
  @discardableResult public func keep(_ replay: JSONText, version: Int) -> Bool {
    send("keep", fields: [("v", .int(version)), ("replay", .raw(replay))])
  }
  public func leave() async {
    _ = send("leave")
    await sendTail?.value
    close()
  }
  public func close() { close(as: .closed, error: RoomError("closed")) }
  private func close(as status: Status, error: RoomError) {
    for report in reportSockets.values { report.close() }
    stopped = true
    joined = false
    generation += 1
    reader?.cancel()
    retry?.cancel()
    pinger?.cancel()
    pongTimer?.cancel()
    joinTimer?.cancel()
    socket?.close()
    socket = nil
    parts.reset()
    for id in Array(sets.keys) { finishSet(id, .failure(error)) }
    for id in Array(asks.keys) { finishAsk(id, .failure(error)) }
    let waits = afterJoin
    afterJoin.removeAll()
    for wait in waits { wait.resume(throwing: error) }
    setStatus(status)
  }
}
