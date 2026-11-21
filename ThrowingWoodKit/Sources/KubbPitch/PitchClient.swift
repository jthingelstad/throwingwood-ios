import Foundation

/// One pitch on the pitch server (the web's backend/pitch-server/PROTOCOL.md): the
/// socket, the join and resume, the lobby's compare-and-set writes, START, the action
/// outbox and casts. All state and callbacks live on the main actor; the Lua engine never
/// crosses actors and this type knows no Kubb (the controller does).
@MainActor public final class PitchClient {
  public enum Status: String, Sendable { case connecting, open, reconnecting, closed, replaced }
  public enum Event: Sendable {
    case status(Status)
    /// `joined` (after every connect) or `state` (after a `resync`): the whole pitch.
    /// The frame is `lastJoin`.
    case state
    case members, host
    case left(String)
    case document(v: Int, doc: JSONText, mine: Bool)
    /// Every other frame, in order: `start`, `act`, `ok`, `refused`, `cast`, `error`,
    /// `pong`, `bye`. Frames that move `s` arrive here only in order: one past a gap is
    /// held back and a `resync` sent instead.
    case message(JSONNode)
  }
  /// The join refusals that end the client (the web's pitch-client.js FINAL).
  static let final: Set<String> = ["full", "no-pitch", "bad-member", "bad-role", "already-joined", "bad-message"]

  public struct Timing: Sendable {
    /// Reconnect backoff (the web's pitch-client.js tune): the first retry at a random
    /// wait under `firstRetry`, then `retry` doubling to `retryMax`, each ±25% at random.
    public var firstRetry: Duration = .milliseconds(300)
    public var retry: Duration = .seconds(1)
    public var retryMax: Duration = .seconds(10)
    /// A join, a `set` or a `start` not answered by then counts the socket as gone.
    public var answer: Duration = .seconds(10)
    /// The keep-alive: the literal `ping` (answered by the runtime, the pitch stays
    /// asleep) this long after the last frame, and the socket counted gone when nothing
    /// comes back within `pong`.
    public var ping: Duration = .seconds(20)
    public var pong: Duration = .seconds(10)
    public init() {}
  }
  public typealias Reducer = @MainActor (JSONText) throws -> JSONText?
  public typealias Factory = @MainActor (URLRequest) -> any PitchTransport
  /// Where the controller's match stands: what a join asks to resume from (PROTOCOL.md
  /// section 7). Nil when it holds no match.
  public typealias Cursor = @MainActor () -> (n: Int, seq: Int)?

  public let code: String
  public let you: String
  /// Joined as an observer: never writes, acts, casts or hosts.
  public let observing: Bool
  public private(set) var status: Status = .closed
  public private(set) var host: String?
  public private(set) var members: [JSONNode] = []
  public private(set) var version = 0
  public private(set) var document = JSONText.null
  public private(set) var by: String?
  public private(set) var limits: JSONNode?
  /// The last `joined` or `state` frame: its `match` is the controller's to read.
  public private(set) var lastJoin: JSONNode?
  /// The pitch sequence this client holds (PROTOCOL.md section 2).
  public private(set) var s = 0
  /// Resyncs sent for a gap in `s` (tests).
  public private(set) var gaps = 0
  public var isHost: Bool { host == you }
  public var isJoined: Bool { joined }
  public var membersJSON: JS { .array(members.map { .raw($0.raw) }) }
  public var cursor: Cursor?

  private let url: URL
  private let appVersion: String
  private let factory: Factory
  private let create: Bool
  /// Each timer takes the value as it starts. Settable inside the module so a test can
  /// shorten one.
  var timing: Timing
  private var me: [(String, JS)]
  private var observers: [UUID: @MainActor (Event) -> Void] = [:]
  private var observerOrder: [UUID] = []
  private var socket: (any PitchTransport)?
  private var generation = 0
  private var stopped = true
  private var joinedOnce = false
  private var joined = false
  private var resyncing = false
  private var attempt = 0
  private var sequence = 0
  private var reader: Task<Void, Never>?
  private var retry: Task<Void, Never>?
  private var pinger: Task<Void, Never>?
  private var joinTimer: Task<Void, Never>?
  private var afterJoin: [CheckedContinuation<Void, Error>] = []
  private var updateTail: Task<Void, Never>?
  private var sendTail: Task<Void, Never>?

  private struct Wait {
    let base: Int
    let doc: JSONText
    let answer: CheckedContinuation<Bool, Error>
    let timer: Task<Void, Never>
    var lost = false
  }
  private var sets: [String: Wait] = [:]
  private var starts: [String: Wait] = [:]
  /// Actions sent and not yet answered, in order, by id. Each is sent again, as it was,
  /// after a reconnect: the pitch answers one it already has `ok` with `dup: true`.
  public private(set) var outbox: [(id: String, frame: JS)] = []

  public init(
    url: URL, pitch: String, appVersion: String, me: [(String, JS)] = [],
    store: any MemberIDStore = DeviceMemberIDStore(), observing: Bool = false,
    create: Bool = false, timing: Timing = Timing(),
    factory: @escaping Factory = { WebSocketTransport(request: $0) }
  ) throws {
    guard pitch.range(of: "^[2-9a-hjkmnp-z]{8,24}$", options: .regularExpression) != nil else {
      throw PitchError("bad-pitch")
    }
    self.url = url
    code = pitch
    self.appVersion = appVersion
    self.factory = factory
    self.timing = timing
    self.observing = observing
    self.create = create && !observing
    self.me = me
    if let id = store.load(),
      id.range(of: "^[A-Za-z0-9_-]{8,40}$", options: .regularExpression) != nil
    {
      you = id
    } else {
      you = Self.randomID(16)
      store.save(you)
    }
  }

  static func randomID(_ count: Int) -> String {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    return String((0..<count).map { _ in alphabet.randomElement()! })
  }

  /// Observers are told in the order they were added (the controller first, then the
  /// screen), so the screen always sees what the controller has already taken in.
  @discardableResult public func observe(_ fn: @escaping @MainActor (Event) -> Void) -> UUID {
    let id = UUID()
    observers[id] = fn
    observerOrder.append(id)
    return id
  }
  public func removeObserver(_ id: UUID) {
    observers[id] = nil
    observerOrder.removeAll { $0 == id }
  }
  private func emit(_ event: Event) {
    for id in observerOrder { observers[id]?(event) }
  }
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
    if stopped { throw PitchError(status == .replaced ? "replaced" : "closed") }
    try await withCheckedThrowingContinuation { afterJoin.append($0) }
  }

  /// The socket's address: `/ws?pitch=<code>` on the pitch server.
  public static func socketURL(_ base: URL, pitch: String) -> URL {
    var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    var path = parts.path
    if !path.hasSuffix("/") { path += "/" }
    parts.path = path + "ws"
    parts.queryItems = [URLQueryItem(name: "pitch", value: pitch)]
    return parts.url!
  }
  /// No `Origin` header: the pitch server lets a request without one through (it keeps
  /// other web pages out, not other programs; PROTOCOL.md section 1).
  static func socketRequest(url: URL, appVersion: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("ThrowingWood/\(appVersion) (ios)", forHTTPHeaderField: "User-Agent")
    return request
  }
  private func open() {
    guard !stopped else { return }
    generation += 1
    let gen = generation
    setStatus(joinedOnce ? .reconnecting : .connecting)
    let transport = factory(Self.socketRequest(url: Self.socketURL(url, pitch: code), appVersion: appVersion))
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
      ("t", .string("join")), ("member", .string(you)),
      ("role", .string(observing ? "observer" : "player")), ("me", .object(me)),
    ]
    if version > 0 { fields.append(("v", .int(version))) }
    if let at = cursor?() { fields += [("n", .int(at.n)), ("seq", .int(at.seq))] }
    if create { fields.append(("create", .bool(true))) }
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
    joined = false
    resyncing = false
    for id in Array(sets.keys) {
      sets[id]?.lost = true
      sets[id]?.timer.cancel()
    }
    // A START whose answer was lost is settled by the next join's match, which the
    // controller adopts either way.
    for id in Array(starts.keys) { finish(&starts, id, .failure(PitchError("uncertain"))) }
    setStatus(joinedOnce ? .reconnecting : .connecting)
    let delay =
      attempt == 0
      ? timing.firstRetry * Double.random(in: 0..<1)
      : min(timing.retry * pow(2, Double(min(attempt - 1, 8))), timing.retryMax) * Double.random(in: 0.75...1.25)
    attempt += 1
    retry?.cancel()
    retry = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      self?.open()
    }
  }

  /// The device came online or the app became active (the web's `online` and
  /// `visibilitychange`): a reconnect waiting out its backoff tries at once, and an open
  /// socket is checked with a `ping` now.
  public func retryNow() {
    guard !stopped else { return }
    if let pending = retry, socket == nil {
      pending.cancel()
      retry = nil
      open()
    } else if joined {
      // any frame back restarts the keep-alive; none within `pong` means a dead socket
      enqueueText("ping")
      pinger?.cancel()
      let gen = generation
      pinger = Task { [weak self, timing] in
        do { try await Task.sleep(for: timing.pong) } catch { return }
        self?.disconnected(gen)
      }
    }
  }

  /// Serialized sends keep frames in order. The generation guard drops queued frames
  /// for a socket that has since closed.
  private func enqueue(_ value: JS) { enqueueText(value.ascii) }
  private func enqueueText(_ text: String) {
    let previous = sendTail
    let gen = generation
    let transport = socket
    sendTail = Task { [weak self] in
      await previous?.value
      guard let self, self.generation == gen, let transport else { return }
      do { try await transport.send(text) } catch { self.disconnected(gen) }
    }
  }

  private func adopt(_ v: Int, _ doc: JSONText, _ writer: String?, mine: Bool = false) {
    guard v > version else { return }
    version = v
    document = doc
    by = writer
    emit(.document(v: v, doc: doc, mine: mine))
  }

  /// The frames that move `s`: taken only in order (PROTOCOL.md section 2).
  private static let stamped: Set<String> = ["member", "left", "host", "doc", "start", "act"]

  /// Internal so injected transports and ordering tests exercise the same reader.
  func receive(_ frame: String) {
    keepAlive()
    if frame == "pong" { return }
    guard let msg = try? JSONNode.parse(frame), let t = msg["t"]?.string else { return }
    // Nothing counts before this connection's `joined` (a frame for an earlier member).
    if !joined && t != "joined" && t != "error" { return }
    if Self.stamped.contains(t) || (t == "ok" && msg["dup"]?.bool != true) {
      guard let next = msg["s"]?.int else { return }
      if next <= s { return }
      if next > s + 1 || resyncing {
        // Something was missed: ask for the whole pitch and take nothing until it comes.
        if !resyncing { resync() }
        if t == "ok", let id = msg["id"]?.string { settleOK(id, msg) }
        return
      }
      s = next
    }
    switch t {
    case "joined", "state":
      if t == "joined" {
        joinTimer?.cancel()
        attempt = 0
        limits = msg["limits"]
      }
      resyncing = false
      lastJoin = msg
      s = msg["s"]?.int ?? s
      host = msg["host"]?.string
      members = msg["members"]?.items ?? []
      if let doc = msg["doc"] {
        version = msg["v"]?.int ?? 0
        document = doc.raw
        by = msg["by"]?.string
      } else if msg["v"]?.int != version {
        // not ours to keep: a new pitch, or one whose lobby was wiped
        version = msg["v"]?.int ?? 0
        document = .null
        by = msg["by"]?.string
      }
      for id in Array(sets.keys) {
        guard let w = sets[id], w.lost else { continue }
        // The write landed when the version is the next one and this member wrote it.
        if version == w.base + 1, by == you {
          finish(&sets, id, .success(true))
        } else {
          finish(&sets, id, .success(false))
        }
      }
      joined = true
      joinedOnce = true
      setStatus(.open)
      emit(.state)
      emit(.members)
      if t == "joined" {
        for entry in outbox { enqueue(entry.frame) }
        let waits = afterJoin
        afterJoin.removeAll()
        for wait in waits { wait.resume() }
      }
    case "member":
      if let host = msg["host"]?.string { self.host = host }
      guard let member = msg["member"], let key = member["id"]?.string else { return }
      members.removeAll { $0["id"]?.string == key }
      members.append(member)
      members.sort { ($0["joined"]?.int ?? 0) < ($1["joined"]?.int ?? 0) }
      emit(.members)
    case "left":
      host = msg["host"]?.string
      guard let key = msg["id"]?.string else { return }
      members.removeAll { $0["id"]?.string == key }
      emit(.left(key))
      emit(.members)
    case "host":
      host = msg["host"]?.string
      emit(.host)
    case "doc":
      adopt(msg["v"]?.int ?? 0, msg["doc"]?.raw ?? .null, msg["by"]?.string)
    case "start":
      adopt(msg["v"]?.int ?? 0, msg["doc"]?.raw ?? .null, msg["by"]?.string)
    case "ok":
      if let id = msg["id"]?.string { settleOK(id, msg) }
    case "no":
      adopt(msg["v"]?.int ?? 0, msg["doc"]?.raw ?? .null, msg["by"]?.string)
      if let id = msg["id"]?.string {
        finish(&sets, id, .success(false))
        finish(&starts, id, .success(false))
      }
    case "refused":
      // this one and every later one of this member's: each follows the refused one
      if let id = msg["id"]?.string, let i = outbox.firstIndex(where: { $0.id == id }) {
        outbox.removeSubrange(i...)
      }
    case "error":
      let error = PitchError(
        msg["code"]?.string ?? "bad-message", msg["message"]?.string ?? "", re: msg["re"]?.string)
      let id = msg["id"]?.string ?? msg["id"]?.int.map(String.init)
      if error.code == "replaced" {
        close(as: .replaced, error: error)
      } else if !joined && Self.final.contains(error.code) {
        // a join refused for good: no point trying again (the web's FINAL)
        close(as: .closed, error: error)
      } else if !joined && error.re == "join" {
        // refused for now (busy, too many): try again after the backoff
        disconnected(generation)
      } else if let id {
        finish(&sets, id, .failure(error))
        finish(&starts, id, .failure(error))
        if error.re == "act" { outbox.removeAll { $0.id == id } }
      }
    default: break
    }
    emit(.message(msg))
  }

  private func settleOK(_ id: String, _ msg: JSONNode) {
    switch msg["re"]?.string {
    case "set":
      if let w = sets[id] {
        adopt(msg["v"]?.int ?? 0, w.doc, you, mine: true)
        finish(&sets, id, .success(true))
      }
    case "start":
      if let w = starts[id] {
        adopt(msg["v"]?.int ?? 0, w.doc, you, mine: true)
        finish(&starts, id, .success(true))
      }
    case "act": outbox.removeAll { $0.id == id }
    default: break
    }
  }

  /// Any frame shows the socket is alive: the next `ping` waits from it.
  private func keepAlive() {
    guard !stopped else { return }
    pinger?.cancel()
    let gen = generation
    pinger = Task { [weak self, timing] in
      do { try await Task.sleep(for: timing.ping) } catch { return }
      guard let self, self.generation == gen, !self.stopped else { return }
      self.enqueueText("ping")
      do { try await Task.sleep(for: timing.pong) } catch { return }
      self.disconnected(gen)
    }
  }

  private func finish(_ waits: inout [String: Wait], _ id: String, _ result: Result<Bool, Error>) {
    guard let wait = waits.removeValue(forKey: id) else { return }
    wait.timer.cancel()
    wait.answer.resume(with: result)
  }

  private func nextID(_ prefix: String) -> String {
    sequence += 1
    return prefix + String(sequence)
  }

  /// A lobby write (`set`): the reducer runs on the document this client holds, and
  /// again only after a `no` (someone else wrote first) or proof that a lost write did
  /// not land. Returns the written document, or nil when the reducer had nothing to do.
  @discardableResult public func update(retries: Int = 20, _ reduce: @escaping Reducer) async throws
    -> JSONText?
  {
    if observing { throw PitchError("observer") }
    let previous = updateTail
    let task = Task { [self] () throws -> JSONText? in
      await previous?.value
      for _ in 0...max(0, retries) {
        try await ready()
        guard let doc = try reduce(document) else { return nil }
        guard ASCIIJSON.asciify(doc.text).utf8.count <= (limits?["docBytes"]?.int ?? 65_536) else {
          throw PitchError("too-big")
        }
        let base = version
        let id = nextID("w")
        let landed: Bool = try await withCheckedThrowingContinuation { answer in
          sets[id] = Wait(base: base, doc: doc, answer: answer, timer: deadline(id))
          enqueue(.object([("t", .string("set")), ("id", .string(id)), ("base", .int(base)), ("doc", .raw(doc))]))
        }
        if landed { return doc }
      }
      throw PitchError("busy")
    }
    updateTail = Task { _ = try? await task.value }
    return try await task.value
  }

  private func deadline(_ id: String) -> Task<Void, Never> {
    let gen = generation
    return Task { [weak self, timing] in
      do { try await Task.sleep(for: timing.answer) } catch { return }
      guard let self, self.sets[id] != nil || self.starts[id] != nil else { return }
      self.disconnected(gen)
    }
  }

  /// START (host only): the lobby write that starts match `n`, with its first hash and
  /// snapshot and the start info a replay needs (`meta`). True on `ok`, false on `no`
  /// (the lobby moved); throws on an error, or `uncertain` when the socket went before
  /// the answer (the next join's match says what happened).
  public func start(base: Int, doc: JSONText, n: Int, h: String, snap: String, meta: JSONText)
    async throws -> Bool
  {
    if observing { throw PitchError("observer") }
    try await ready()
    let id = nextID("go")
    return try await withCheckedThrowingContinuation { answer in
      starts[id] = Wait(base: base, doc: doc, answer: answer, timer: deadline(id))
      enqueue(
        .object([
          ("t", .string("start")), ("id", .string(id)), ("base", .int(base)), ("doc", .raw(doc)),
          ("n", .int(n)), ("h", .string(h)), ("snap", .string(snap)), ("meta", .raw(meta)),
        ]))
    }
  }

  /// One action (`act`), sent now if joined and kept in the outbox until it is answered;
  /// never waited on. Every outbox action goes again, unchanged, after a reconnect.
  public func act(id: String, n: Int, seq: Int, a: JSONText, h: String, snap: String, over: Bool) {
    guard !observing else { return }
    var fields: [(String, JS)] = [
      ("t", .string("act")), ("id", .string(id)), ("n", .int(n)), ("seq", .int(seq)),
      ("a", .raw(a)), ("h", .string(h)), ("snap", .string(snap)),
    ]
    if over { fields.append(("over", .bool(true))) }
    fields.append(("c", .string("ios")))
    let frame = JS.object(fields)
    outbox.append((id, frame))
    if joined { enqueue(frame) }
  }
  /// Forget outbox actions the controller has given up (a conflict it lost).
  public func dropActs(_ ids: Set<String>? = nil) {
    if let ids { outbox.removeAll { ids.contains($0.id) } } else { outbox.removeAll() }
  }

  public func resync() {
    guard joined else { return }
    resyncing = true
    gaps += 1
    enqueue(.object([("t", .string("resync"))]))
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
  /// A cast (`d` opaque, at most 2 KB). `all` reaches observers past the thinning: a
  /// shout, the last aim before a release.
  @discardableResult public func cast(_ value: JSONText, all: Bool = false) -> Bool {
    guard !observing else { return false }
    return send("cast", fields: [("d", .raw(value))] + (all ? [("all", .bool(true))] : []))
  }
  /// The open listing (host only): `{ seats, state }`, or null to take it off.
  @discardableResult public func list(_ open: JSONText) -> Bool {
    send("open", fields: [("open", .raw(open))])
  }

  /// Off the pitch for good: `leave`, then the socket closed.
  public func leave() async {
    _ = send("leave")
    await sendTail?.value
    close()
  }
  public func close() { close(as: .closed, error: PitchError("closed")) }
  private func close(as status: Status, error: PitchError) {
    stopped = true
    joined = false
    generation += 1
    reader?.cancel()
    retry?.cancel()
    pinger?.cancel()
    joinTimer?.cancel()
    socket?.close()
    socket = nil
    for id in Array(sets.keys) { finish(&sets, id, .failure(error)) }
    for id in Array(starts.keys) { finish(&starts, id, .failure(error)) }
    let waits = afterJoin
    afterJoin.removeAll()
    for wait in waits { wait.resume(throwing: error) }
    setStatus(status)
  }
}
