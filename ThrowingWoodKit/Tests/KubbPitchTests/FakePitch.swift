import Foundation

@testable import KubbPitch

/// One pitch on an in-process stand-in for the pitch server: the parts of the web's
/// backend/pitch-server/PROTOCOL.md the client and controller lean on (join and resume,
/// compare-and-set writes, START, actions with idempotent retries and refusals, resync,
/// casts, the literal keep-alive), on transports that can lose answers or drop. The real
/// server (`wrangler dev`) is `LivePitchTests`'; this one lets a test lose exactly one
/// answer.
@MainActor final class FakePitch {
  /// One socket to this pitch, as the client sees it.
  final class Link: PitchTransport {
    weak var pitch: FakePitch?
    let request: URLRequest
    var member: String?
    var closed = false
    /// What the client sent on this socket (parsed; the literal keep-alive as `{t:"ping"}`).
    var sent: [JSONNode] = []
    /// What the pitch sent to it.
    var got: [JSONNode] = []
    /// The pitch handles what comes, but its answers on this socket are lost.
    var deaf = false
    /// What comes is lost on the way: the pitch never sees it.
    var swallow = false
    /// The runtime's literal `pong` is not sent.
    var noPong = false
    private var inbox: [Result<String, Error>] = []
    private var waiting: CheckedContinuation<String, Error>?

    init(_ pitch: FakePitch, _ request: URLRequest) {
      self.pitch = pitch
      self.request = request
    }
    func send(_ text: String) async throws {
      if closed { throw PitchError("closed") }
      if text == "ping" {
        sent.append(try JSONNode.parse(#"{"t":"ping"}"#))
        if !noPong && !swallow { deliver(.success("pong")) }
        return
      }
      sent.append(try JSONNode.parse(text))
      if !swallow { pitch?.handle(self, text) }
    }
    func receive() async throws -> String {
      if !inbox.isEmpty { return try inbox.removeFirst().get() }
      if closed { throw PitchError("closed") }
      return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    private func deliver(_ value: Result<String, Error>) {
      if let w = waiting {
        waiting = nil
        w.resume(with: value)
      } else {
        inbox.append(value)
      }
    }
    /// A frame from the pitch (unless this socket is deaf).
    func push(_ text: String) {
      guard !closed, !deaf else { return }
      if let node = try? JSONNode.parse(text) { got.append(node) }
      deliver(.success(text))
    }
    func push(_ value: JS) { push(value.ascii) }
    /// The client closes it.
    func close() {
      guard !closed else { return }
      closed = true
      deliver(.failure(PitchError("closed")))
      pitch?.gone(self)
    }
    /// The network goes: the client's next read fails.
    func drop() { close() }
    func sent(_ t: String) -> [JSONNode] { sent.filter { $0["t"]?.string == t } }
    func got(_ t: String) -> [JSONNode] { got.filter { $0["t"]?.string == t } }
  }

  struct Member {
    var role: String
    var me: [(String, JS)]
    var joined: Int
    var since: Int
    var link: Link?
  }
  struct Act {
    let id: String
    let m: String
    let seq: Int
    let a: JSONText
    let h: String
    let s: Int
    let ts: Int
    let over: Bool
    let c: String?
  }
  struct Match {
    var n: Int
    var meta: JSONText
    var h0: String
    var at: Int
    var seq = 0
    var h: String
    var snap: String
    var over = false
    var acts: [Act] = []
  }

  let code: String
  var links: [Link] = []
  var members: [String: Member] = [:]
  var s = 0
  var host: String?
  var v = 0
  var by: String?
  var sid: String?
  var doc = JSONText.null
  var match: Match?
  var open: JSONText?
  var fresh = true
  var now = 1_795_280_000_000
  var resumeMax = 64
  /// The next `act` is refused with this reason whatever it is.
  var refuseNext: String?

  init(code: String = "abcdefghjk") { self.code = code }

  var factory: PitchClient.Factory {
    { [weak self] request in
      let link = Link(self!, request)
      self!.links.append(link)
      return link
    }
  }
  var live: [Link] { links.filter { !$0.closed } }
  /// Every socket this member has had, oldest first.
  func links(of member: String) -> [Link] { links.filter { $0.member == member } }
  /// Every socket goes at once (a server restart, the network gone).
  func dropAll() { for l in live { l.drop() } }

  private func tick() -> Int {
    now += 5
    return now
  }
  private func stamp() -> (Int, Int) {
    s += 1
    return (s, tick())
  }
  private func view(_ id: String, _ m: Member) -> JS {
    .object([
      ("id", .string(id)), ("role", .string(m.role)), ("connected", .bool(m.link != nil)),
      ("joined", .int(m.joined)), ("since", .int(m.since)), ("me", .object(m.me)),
    ])
  }
  var membersJS: JS {
    .array(members.sorted { $0.value.joined < $1.value.joined }.map { view($0.key, $0.value) })
  }
  private func joinedLinks(except: Link? = nil, role: String? = nil) -> [Link] {
    members.values.compactMap(\.link).filter { l in
      l !== except && !l.closed && (role == nil || members[l.member ?? ""]?.role == role)
    }
  }
  private func broadcast(_ frame: JS, except: Link? = nil, role: String? = nil) {
    for l in joinedLinks(except: except, role: role) { l.push(frame) }
  }
  private func error(_ link: Link, _ code: String, re: String?, id: JSONNode?) {
    var f: [(String, JS)] = [("t", .string("error")), ("code", .string(code)), ("message", .string(code))]
    if let re { f.append(("re", .string(re))) }
    if let id, !id.isNull { f.append(("id", .raw(id.raw))) }
    link.push(.object(f))
  }

  func relay(_ n: Int, _ r: Act) -> JS {
    var f: [(String, JS)] = [
      ("t", .string("act")), ("m", .string(r.m)), ("s", .int(r.s)), ("ts", .int(r.ts)),
      ("id", .string(r.id)), ("n", .int(n)), ("seq", .int(r.seq)), ("a", .raw(r.a)), ("h", .string(r.h)),
    ]
    if r.over { f.append(("over", .bool(true))) }
    return .object(f)
  }
  func matchView(n: Int?, seq: Int?, full force: Bool = false) -> JS {
    guard let M = match else { return .null }
    var f: [(String, JS)] = [("n", .int(M.n)), ("seq", .int(M.seq)), ("h", .string(M.h)), ("over", .bool(M.over))]
    if !force, n == M.n, let seq, seq >= 0, seq <= M.seq, M.seq - seq <= resumeMax {
      f += [("full", .bool(false)), ("acts", .array(M.acts.filter { $0.seq > seq }.map { relay(M.n, $0) }))]
    } else {
      f += [
        ("full", .bool(true)), ("at", .int(M.at)), ("h0", .string(M.h0)), ("meta", .raw(M.meta)),
        ("snap", .string(M.snap)),
      ]
    }
    return .object(f)
  }
  func stateFrame() -> JS {
    .object([
      ("t", .string("state")), ("s", .int(s)), ("ts", .int(tick())), ("host", host.map(JS.string) ?? .null),
      ("members", membersJS), ("v", .int(v)), ("by", by.map(JS.string) ?? .null), ("doc", .raw(doc)),
      ("match", matchView(n: nil, seq: nil, full: true)),
    ])
  }

  func handle(_ link: Link, _ text: String) {
    guard let msg = try? JSONNode.parse(text), let t = msg["t"]?.string else {
      return error(link, "bad-message", re: nil, id: nil)
    }
    if t == "ping" { return link.push(.object([("t", .string("pong")), ("ts", .int(tick()))])) }
    if t == "join" { return join(link, msg) }
    guard let id = link.member, members[id]?.link === link else {
      return error(link, "not-joined", re: t, id: msg["id"])
    }
    let role = members[id]!.role
    if role == "observer", ["set", "start", "act", "cast"].contains(t) {
      return error(link, "observer", re: t, id: msg["id"])
    }
    switch t {
    case "me":
      merge(id, msg["me"])
      let (s, ts) = stamp()
      broadcast(.object([("t", .string("member")), ("member", view(id, members[id]!)), ("host", host.map(JS.string) ?? .null), ("s", .int(s)), ("ts", .int(ts))]))
    case "set":
      guard msg["base"]?.int == v else { return no(link, msg) }
      write(id, msg)
      let (s, ts) = stamp()
      broadcast(.object([("t", .string("doc")), ("v", .int(v)), ("by", .string(id)), ("doc", .raw(doc)), ("s", .int(s)), ("ts", .int(ts))]), except: link)
      link.push(.object([("t", .string("ok")), ("re", .string("set")), ("id", .raw(msg["id"]!.raw)), ("v", .int(v)), ("s", .int(s)), ("ts", .int(ts))]))
    case "start":
      guard id == host else { return error(link, "not-host", re: "start", id: msg["id"]) }
      let n = (match?.n ?? 0) + 1
      guard msg["n"]?.int == n else { return error(link, "bad-match", re: "start", id: msg["id"]) }
      guard msg["base"]?.int == v else { return no(link, msg) }
      write(id, msg)
      let h = msg["h"]!.string!
      let snap = msg["snap"]!.string!
      match = Match(n: n, meta: msg["meta"]?.raw ?? JSONText("{}"), h0: h, at: now, h: h, snap: snap)
      let (s, ts) = stamp()
      broadcast(
        .object([
          ("t", .string("start")), ("m", .string(id)), ("v", .int(v)), ("by", .string(id)), ("doc", .raw(doc)),
          ("n", .int(n)), ("h", .string(h)), ("snap", .string(snap)), ("meta", .raw(match!.meta)),
          ("s", .int(s)), ("ts", .int(ts)),
        ]), except: link)
      link.push(.object([("t", .string("ok")), ("re", .string("start")), ("id", .raw(msg["id"]!.raw)), ("v", .int(v)), ("n", .int(n)), ("s", .int(s)), ("ts", .int(ts))]))
    case "act": act(link, id, msg)
    case "cast":
      let frame = JS.object([("t", .string("cast")), ("m", .string(id)), ("s", .int(s)), ("ts", .int(tick())), ("d", .raw(msg["d"]?.raw ?? .null))])
      broadcast(frame, except: link, role: "player")
      broadcast(frame, role: "observer")
    case "open":
      guard id == host else { return error(link, "not-host", re: "open", id: nil) }
      open = msg["open"]?.raw
    case "resync": link.push(stateFrame())
    case "leave":
      members[id] = nil
      link.member = nil
      if host == id { host = nil; succeed() }
      let (s, ts) = stamp()
      broadcast(.object([("t", .string("left")), ("id", .string(id)), ("host", host.map(JS.string) ?? .null), ("s", .int(s)), ("ts", .int(ts))]))
      link.push(.object([("t", .string("bye")), ("ts", .int(tick()))]))
    default: error(link, "bad-message", re: t, id: nil)
    }
  }

  private func merge(_ id: String, _ fields: JSONNode?) {
    for (k, value) in fields?.members ?? [] {
      members[id]!.me.removeAll { $0.0 == k }
      if !value.isNull { members[id]!.me.append((k, .raw(value.raw))) }
    }
  }
  private func write(_ id: String, _ msg: JSONNode) {
    v = msg["base"]!.int! + 1
    by = id
    sid = msg["id"]?.string ?? msg["id"]?.int.map(String.init)
    doc = msg["doc"]!.raw
  }
  private func no(_ link: Link, _ msg: JSONNode) {
    link.push(
      .object([
        ("t", .string("no")), ("re", .string(msg["t"]!.string!)), ("id", .raw(msg["id"]?.raw ?? .null)),
        ("v", .int(v)), ("by", by.map(JS.string) ?? .null), ("sid", sid.map(JS.string) ?? .null), ("doc", .raw(doc)),
      ]))
  }
  /// The earliest-joined connected player when there is no host.
  private func succeed() {
    guard host == nil else { return }
    host = members.filter { $0.value.link != nil && $0.value.role == "player" }.min { $0.value.joined < $1.value.joined }?.key
  }
  /// The host passes to `to` (the pitch decides; PROTOCOL.md section 4).
  func passHost(to id: String) {
    host = id
    let (s, ts) = stamp()
    broadcast(.object([("t", .string("host")), ("host", .string(id)), ("s", .int(s)), ("ts", .int(ts))]))
  }

  private func join(_ link: Link, _ msg: JSONNode) {
    let role = msg["role"]?.string ?? "player"
    guard let id = msg["member"]?.string else { return error(link, "bad-member", re: "join", id: nil) }
    if fresh && role == "observer" { return error(link, "no-pitch", re: "join", id: nil) }
    if let m = members[id], m.role != role { return error(link, "bad-role", re: "join", id: nil) }
    if members[id] == nil {
      let last = members.values.map(\.joined).max() ?? 0
      members[id] = Member(role: role, me: [], joined: max(now, last + 1), since: now, link: nil)
    }
    merge(id, msg["me"])
    let old = members[id]!.link
    members[id]!.link = link
    members[id]!.since = now
    link.member = id
    fresh = false
    succeed()
    let (s, ts) = stamp()
    broadcast(.object([("t", .string("member")), ("member", view(id, members[id]!)), ("host", host.map(JS.string) ?? .null), ("s", .int(s)), ("ts", .int(ts))]), except: link)
    if let old, old !== link {
      old.member = nil
      old.push(.object([("t", .string("error")), ("code", .string("replaced")), ("message", .string("replaced"))]))
      old.close()
    }
    var f: [(String, JS)] = [
      ("t", .string("joined")), ("pitch", .string(code)), ("you", .string(id)), ("role", .string(role)),
      ("host", host.map(JS.string) ?? .null), ("s", .int(s)), ("ts", .int(ts)), ("members", membersJS),
      ("limits", .object([("docBytes", .int(65_536)), ("resumeMax", .int(resumeMax))])),
      ("v", .int(v)), ("by", by.map(JS.string) ?? .null),
    ]
    if !(msg["v"]?.int == v && v > 0) { f.append(("doc", .raw(doc))) }
    f.append(("match", matchView(n: msg["n"]?.int, seq: msg["seq"]?.int)))
    link.push(.object(f))
  }

  private func act(_ link: Link, _ who: String, _ msg: JSONNode) {
    guard let id = msg["id"]?.string, let n = msg["n"]?.int, let seq = msg["seq"]?.int, let a = msg["a"],
      let h = msg["h"]?.string, let snap = msg["snap"]?.string
    else { return error(link, "bad-message", re: "act", id: msg["id"]) }
    if let M = match, n == M.n, let r = M.acts.first(where: { $0.id == id }) {
      return link.push(
        .object([
          ("t", .string("ok")), ("re", .string("act")), ("id", .string(id)), ("n", .int(M.n)), ("seq", .int(r.seq)),
          ("s", .int(r.s)), ("ts", .int(r.ts)), ("dup", .bool(true)),
        ]))
    }
    let why: String? =
      refuseNext ?? (match == nil ? "no-match" : n != match!.n ? "match" : match!.over ? "over" : seq != match!.seq + 1 ? "seq" : nil)
    refuseNext = nil
    if let why {
      let head: JS = match.map { .object([("n", .int($0.n)), ("seq", .int($0.seq)), ("h", .string($0.h)), ("over", .bool($0.over))]) } ?? .null
      return link.push(
        .object([("t", .string("refused")), ("id", .string(id)), ("n", .int(n)), ("seq", .int(seq)), ("why", .string(why)), ("head", head)]))
    }
    let r = store(from: who, id: id, seq: seq, a: a.raw, h: h, snap: snap, over: msg["over"]?.bool == true, c: msg["c"]?.string, except: link)
    link.push(.object([("t", .string("ok")), ("re", .string("act")), ("id", .string(id)), ("n", .int(match!.n)), ("seq", .int(seq)), ("s", .int(r.s)), ("ts", .int(r.ts))]))
  }

  /// An action stored and relayed to everyone but `except` (nil: a peer the test plays).
  @discardableResult func store(
    from who: String, id: String, seq: Int, a: JSONText, h: String, snap: String, over: Bool, c: String? = nil,
    except: Link? = nil
  ) -> Act {
    let (s, ts) = stamp()
    let r = Act(id: id, m: who, seq: seq, a: a, h: h, s: s, ts: ts, over: over, c: c)
    match!.acts.append(r)
    match!.seq = seq
    match!.h = h
    match!.snap = snap
    if over { match!.over = true }
    broadcast(relay(match!.n, r), except: except)
    return r
  }

  /// Another member STARTs the next match (as host): everyone gets `start`.
  func startAs(_ who: String, meta: JSONText, h: String, snap: String) {
    let n = (match?.n ?? 0) + 1
    v += 1
    by = who
    match = Match(n: n, meta: meta, h0: h, at: now, h: h, snap: snap)
    let (s, ts) = stamp()
    broadcast(
      .object([
        ("t", .string("start")), ("m", .string(who)), ("v", .int(v)), ("by", .string(who)), ("doc", .raw(doc)),
        ("n", .int(n)), ("h", .string(h)), ("snap", .string(snap)), ("meta", .raw(meta)), ("s", .int(s)), ("ts", .int(ts)),
      ]))
  }

  /// The client closed this socket, or it dropped: the member is kept, marked away.
  func gone(_ link: Link) {
    guard let id = link.member, members[id]?.link === link else { return }
    members[id]!.link = nil
    members[id]!.since = now
    let (s, ts) = stamp()
    broadcast(.object([("t", .string("member")), ("member", view(id, members[id]!)), ("host", host.map(JS.string) ?? .null), ("s", .int(s)), ("ts", .int(ts))]))
  }
}
