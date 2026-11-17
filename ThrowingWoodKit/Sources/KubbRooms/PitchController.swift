import Foundation
import KubbEngine

/// A headless pitch. Room rules are exclusively `room.*`; this type owns effects:
/// socket writes, engine actions, snapshot recovery, the host clock and keep requests.
@MainActor public final class PitchController {
  public enum State: String, Sendable { case lobby, match, versionMismatch, closed, failed }
  public let room: RoomsClient
  public let engine: Engine
  public private(set) var state: State = .lobby
  public private(set) var mismatch: JSONText?
  public private(set) var lastError: String?
  public private(set) var matchNumber: Int?
  public private(set) var sequence = 0
  public private(set) var applied = 0
  public private(set) var corrections = 0
  public private(set) var adoptions = 0
  public private(set) var pending = false
  public private(set) var mayAct = false
  public private(set) var control = JSONText.null
  public private(set) var need = JSONText.null
  public private(set) var lastCast: JSONText?
  private var match: JSONNode?
  private var observation: UUID?
  private var clock: Task<Void, Never>?
  private var hostGoneAt: Int?
  private var lastClaim: Int?
  private var kept: Int?
  private var arrivedOver: Int?
  private var lastAim: JSONText?
  private var lastAimAt = 0
  private var lastShoutAt: Int?

  public init(room: RoomsClient, engine: Engine) throws {
    guard room.engineVersion == engine.engineVersion else { throw RoomError("engine-version") }
    self.room = room
    self.engine = engine
    observation = room.observe { [weak self] in self?.receive($0) }
  }

  /// Starts the wire and a 200 ms presence/host clock. Call close when the owner ends.
  public func connect() {
    room.connect()
    guard clock == nil else { return }
    clock = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        self?.tick()
      }
    }
  }
  public func close() {
    clock?.cancel()
    clock = nil
    if let observation {
      room.removeObserver(observation)
      self.observation = nil
    }
    room.close()
    state = .closed
    mayAct = false
  }

  public func roomCall(_ name: String, _ args: [(String, JS)] = []) throws -> JSONNode {
    let result = try JSONNode.parse(engine.call("room." + name, json: JS.object(args).ascii))
    guard let value = result["value"] else { throw RoomError("engine-result") }
    return value
  }
  private func call(_ name: String, _ args: JS? = nil) throws -> JSONNode {
    try JSONNode.parse(engine.call(name, json: args?.ascii ?? ""))
  }
  public func setMe(name: String, level: String) throws {
    let clean = try roomCall("cleanName", [("name", .string(name))])
    room.setMe([
      ("name", .raw(clean.raw)), ("level", .string(level)),
      ("engine", .string(engine.engineVersion)),
    ])
  }

  @discardableResult public func reduce(_ name: String, fields: [(String, JS)] = []) async throws
    -> Bool
  {
    // Only these host reducers are exposed; seat and sync decisions remain in Lua.
    let hostOnly = ["setOptions", "setAccess", "pruneTeams", "backToLobby"]
    if hostOnly.contains(name), !room.isHost { throw RoomError("not-host") }
    guard ["joinTeam", "setOptions", "setAccess", "pruneTeams", "backToLobby"].contains(name) else {
      throw RoomError("bad-reducer")
    }
    return try await room.update { [self] doc in
      if hostOnly.contains(name), !room.isHost { return nil }
      var args = fields.filter { $0.0 != "doc" && $0.0 != "id" }
      if name == "joinTeam" { args.append(("id", .string(room.you))) }
      let value = try roomCall(name, [("doc", .raw(doc))] + args)
      return value.isNull ? nil : value.raw
    } != nil
  }
  public func joinTeam(_ side: String?) async throws {
    _ = try await reduce("joinTeam", fields: [("side", side.map(JS.string) ?? .null)])
  }

  /// A fresh match is built inside the CAS reducer so a retry uses the current lineup
  /// and options. Strict version checks: no unknown or different player engine starts.
  @discardableResult public func start(seed: Int, at: JSONText) async throws -> Bool {
    guard room.isHost, state == .lobby, !pending else { return false }
    pending = true
    defer { pending = false }
    do {
      let result = try await room.update { [self] doc in
        guard room.isHost else { return nil }
        let lineup = try roomCall("lineup", [("doc", .raw(doc)), ("members", room.membersJSON)])
        if lineup.isNull { return nil }
        let players = lineup["players"]!.raw
        let check = try roomCall(
          "startCheck",
          [
            ("players", .raw(players)),
            ("members", room.membersJSON), ("host", .string(room.you)),
          ])
        guard check["ok"]?.bool == true else {
          mismatch = check.raw
          state = .versionMismatch
          return nil
        }
        let opts = try roomCall(
          "matchOptions",
          [
            ("doc", .raw(doc)), ("lineup", .raw(lineup.raw)),
            ("seed", .int(seed)), ("start", .raw(at)),
          ])
        let args = JS.object(
          opts.members.map { ($0.key, JS.raw($0.value.raw)) } + [("mode", .string("match"))])
        _ = try call("new", args)
        let snap = try engine.call("snapshot")
        let value = try roomCall(
          "startMatch",
          [
            ("doc", .raw(doc)), ("snap", .string(snap)),
            ("hash", .string(engine.hash())), ("players", .raw(players)),
            ("cpu", .raw(lineup["cpu"]?.raw ?? .null)), ("host", .string(room.you)),
            ("setup", .raw(opts.raw)), ("members", room.membersJSON),
          ])
        guard !value.isNull else { return nil }
        let m = value["match"]!
        match = m
        matchNumber = m["n"]?.int
        sequence = 0
        state = .match
        arrivedOver = nil
        kept = nil
        try refreshSeat()
        return value.raw
      }
      if result == nil, state != .versionMismatch { try synchronize(room.document) }
      return result != nil
    } catch {
      try? synchronize(room.document)
      throw error
    }
  }

  private func context() -> JS {
    .object([
      ("players", .raw(match?["players"]?.raw ?? JSONText(#"{"A":[],"B":[]}"#))),
      ("cpu", .raw(match?["cpu"]?.raw ?? .null)),
      ("host", room.host.map(JS.string) ?? .null),
      (
        "connected",
        .array(
          room.members.filter { $0["connected"]?.bool == true }.compactMap { $0["id"]?.string }.map(
            JS.string))
      ),
    ])
  }
  private func refreshSeat() throws {
    guard state == .match else {
      mayAct = false
      return
    }
    let ctx = context()
    let next = try roomCall("controlFor", [("ctx", ctx), ("me", .string(room.you))])
    let same = try roomCall("sameControl", [("a", .raw(control)), ("b", .raw(next.raw))])
    if same.bool != true {
      let gainedCPU =
        next["cpu"]?.bool == true && (try? JSONNode.parse(control)["cpu"]?.bool) != true
      control = next.raw
      if gainedCPU, !pending, (try call("need"))["cpu"]?.bool == true {
        _ = try engine.call("restore", json: engine.call("snapshot"))
      }
      _ = try engine.call("setControl", json: control.text)
    }
    need = try engine.call("need").asJSON
    mayAct =
      try roomCall("mayAct", [("need", .raw(need)), ("ctx", ctx), ("me", .string(room.you))]).bool
      == true
  }

  private func receive(_ event: RoomsClient.Event) {
    do {
      switch event {
      case .document(let v, let doc, let rider, let mine):
        try synchronize(doc, rider: rider, mine: mine)
        try keepReplay(doc, version: v)
      case .state:
        // Rejoins have no rider. A gap is deliberately adopted, never replayed twice.
        try synchronize(room.document)
        try refreshSeat()
      case .members, .host:
        if room.members.contains(where: {
          $0["id"]?.string == room.host && $0["connected"]?.bool == true
        }) {
          hostGoneAt = nil
        }
        try refreshSeat()
        if state == .versionMismatch, match == nil {
          state = .lobby
          mismatch = nil
        }
      case .left:
        if room.isHost, state == .lobby {
          let present = JS.array(room.members.compactMap { $0["id"]?.string }.map(JS.string))
          Task { [weak self] in
            do { _ = try await self?.reduce("pruneTeams", fields: [("present", present)]) } catch {
              self?.lastError = String(describing: error)
            }
          }
        }
      case .message(let msg):
        if msg["t"]?.string == "cast" {
          lastCast = msg.raw
          if msg["d"]?["t"]?.string == "aim", state == .match, let aim = msg["d"]?["s"] {
            _ = try engine.call("showAim", json: aim.raw.text)
          }
        }
      case .status(let status):
        if status == .closed || status == .replaced { mayAct = false }
      }
    } catch {
      lastError = String(describing: error)
      state = .failed
      mayAct = false
    }
  }

  private func synchronize(_ doc: JSONText, rider: JSONText? = nil, mine: Bool = false) throws {
    let local = JS.object([("n", matchNumber.map(JS.int) ?? .null), ("seq", .int(sequence))])
    let decision = try roomCall(
      "decide",
      [
        ("local", local), ("doc", .raw(doc)),
        ("with", rider.map(JS.raw) ?? .null), ("mine", .bool(mine)),
      ])
    guard let kind = decision["kind"]?.string else { throw RoomError("engine-result") }
    if kind == "lobby" {
      state = .lobby
      match = nil
      matchNumber = nil
      sequence = 0
      mayAct = false
      control = .null
      mismatch = nil
      return
    }
    if kind == "old" { return }
    guard let m = decision["match"] else { return }
    let check = try roomCall(
      "mayPlay", [("engine", .string(engine.engineVersion)), ("match", .raw(m.raw))])
    guard check["ok"]?.bool == true else {
      state = .versionMismatch
      mismatch = check.raw
      mayAct = false
      return
    }
    if state == .versionMismatch {
      state = .match
      mismatch = nil
    }
    switch kind {
    case "start":
      state = .match
      matchNumber = m["n"]?.int
      sequence = m["seq"]?.int ?? 0
      arrivedOver = m["over"]?.bool == true ? matchNumber : nil
      kept = nil
      control = .null
      _ = try engine.call("restore", json: m["snap"]!.string!)
    case "apply":
      var agrees = false
      do {
        let out = try engine.call("apply", json: decision["action"]!.raw.text)
        agrees = try JSONNode.parse(out)["ok"]?.bool != false && engine.hash() == m["hash"]?.string
      } catch { agrees = false }
      if agrees {
        applied += 1
      } else {
        corrections += 1
        _ = try engine.call("restore", json: m["snap"]!.string!)
      }
      sequence = m["seq"]?.int ?? 0
    case "adopt":
      adoptions += 1
      _ = try engine.call("restore", json: m["snap"]!.string!)
      sequence = m["seq"]?.int ?? 0
    case "same":
      if !pending, try engine.hash() != m["hash"]?.string {
        corrections += 1
        _ = try engine.call("restore", json: m["snap"]!.string!)
      }
    default: break
    }
    if kind == "start" || kind == "adopt" || kind == "apply" { control = .null }
    match = m
    try refreshSeat()
  }

  private func keepReplay(_ doc: JSONText, version: Int) throws {
    let m = try JSONNode.parse(doc)["match"]
    guard state == .match, let m, m["over"]?.bool == true,
      m["n"]?.int == matchNumber, kept != matchNumber, arrivedOver != matchNumber
    else { return }
    let replay = try roomCall("replayOf", [("match", .raw(m.raw))])
    if !replay.isNull, room.keep(replay.raw, version: version) { kept = matchNumber }
  }

  /// Take a user action only in this member's seat. The engine validates the action.
  @discardableResult public func take(_ action: JSONText) async throws -> Bool {
    guard state == .match, room.status == .open, !pending else { return false }
    try refreshSeat()
    guard mayAct else { return false }
    let out = try call("apply", .raw(action))
    if out["ok"]?.bool == false { return false }
    return try await commit(action)
  }

  /// A frame can release a host-owned computer throw or this member's dial throw.
  /// No room bridge calls run per frame: `mayAct` and `control` are cached.
  public func frame(_ input: JSONText) async throws -> JSONText? {
    guard state == .match, room.status == .open, !pending else { return nil }
    let n = try JSONNode.parse(need)
    let cpuControl = try JSONNode.parse(control)["cpu"]?.bool == true
    let cpu = n["cpu"]?.bool == true && cpuControl
    guard mayAct || cpu else { return nil }
    let out = try call("frame", .raw(input))
    if let action = out["action"] { _ = try await commit(action.raw) }
    return out.raw
  }

  private func commit(_ action: JSONText) async throws -> Bool {
    guard let n = matchNumber else { return false }
    let seq = sequence + 1
    let snap = try engine.call("snapshot")
    let hash = try engine.hash()
    let over = try call("need")["kind"]?.string == "over"
    let rider = try roomCall(
      "rider",
      [
        ("n", .int(n)), ("seq", .int(seq)), ("action", .raw(action)),
        ("bytes", .int(room.limits?["withBytes"]?.int ?? 4096)),
        ("client", .string("ios")), ("engine", .string(engine.engineVersion)),
      ])
    sequence = seq
    pending = true
    do {
      let result = try await room.update(rider: rider.isNull ? nil : rider.raw) { [self] doc in
        let value = try roomCall(
          "commitAction",
          [
            ("doc", .raw(doc)), ("n", .int(n)), ("seq", .int(seq)),
            ("snap", .string(snap)), ("hash", .string(hash)), ("action", .raw(action)),
            ("over", .bool(over)),
          ])
        return value.isNull ? nil : value.raw
      }
      pending = false
      // A losing optimistic seq can look "same" or "old" to decide; explicitly discard
      // it before recovering the server document after a conflict or an uncertain set.
      if result == nil { try recover() }
      try refreshSeat()
      try keepReplay(room.document, version: room.version)
      return result != nil
    } catch {
      pending = false
      try? recover()
      throw error
    }
  }
  private func recover() throws {
    matchNumber = nil
    sequence = 0
    control = .null
    try synchronize(room.document)
  }

  /// Presence is a host-side effect. Lua chooses the successor; the client waits the
  /// server's full grace (16 seconds locally to allow network/clock skew).
  public func tick(now: Int = Int(Date().timeIntervalSince1970 * 1000)) {
    guard room.status == .open else { return }
    do {
      if !pending { try refreshSeat() }
      if room.isHost {
        hostGoneAt = nil
        return
      }
      let host = room.members.first { $0["id"]?.string == room.host }
      if host?["connected"]?.bool == true {
        hostGoneAt = nil
        return
      }
      if hostGoneAt == nil { hostGoneAt = now }
      if host != nil, now - hostGoneAt! < max(16_000, room.limits?["hostGraceMs"]?.int ?? 15_000) {
        return
      }
      let next = try roomCall(
        "nextHost", [("members", room.membersJSON), ("host", room.host.map(JS.string) ?? .null)])
      if next.string == room.you, lastClaim == nil || now - lastClaim! >= 5000 {
        lastClaim = now
        room.claimHost()
      }
    } catch { lastError = String(describing: error) }
  }

  public func castAim(now: Int = Int(Date().timeIntervalSince1970 * 1000)) throws {
    guard state == .match, mayAct, !pending, now - lastAimAt >= 200 else { return }
    let aim = try engine.call("aimState").asJSON
    if aim != lastAim, room.cast(JS.object([("t", .string("aim")), ("s", .raw(aim))]).json) {
      lastAim = aim
      lastAimAt = now
    }
  }
  public func shout(_ word: String, now: Int = Int(Date().timeIntervalSince1970 * 1000)) {
    guard ["NICE!", "OOH!", "TOK!", "UNLUCKY"].contains(word),
      lastShoutAt == nil || now - lastShoutAt! >= 700
    else { return }
    if room.cast(JS.object([("t", .string("shout")), ("w", .string(word))]).json) {
      lastShoutAt = now
    }
  }
}

extension String { fileprivate var asJSON: JSONText { JSONText(self) } }
