import Foundation
import KubbEngine
import KubbRooms
import Observation

public struct PitchLink: Equatable, Sendable {
  public let code: String
  public var url: URL { URL(string: "https://throwingwood.com/p/" + code)! }
  public init?(_ input: String) {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    var code = text
    if let url = URLComponents(string: text), url.scheme != nil {
      guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
        ["throwingwood.com", "kubb.thingelstad.xyz"].contains(host),
        url.user == nil, url.password == nil, url.port == nil
      else { return nil }
      let path = url.path.split(separator: "/")
      guard path.count == 2, path[0] == "p" else { return nil }
      code = String(path[1])
    }
    code = code.lowercased()
    guard (8...24).contains(code.utf8.count),
      code.allSatisfy({ Self.alphabet.contains($0) })
    else { return nil }
    self.code = code
  }
  private static let alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
  public static func fresh() -> Self {
    Self(String((0..<10).map { _ in alphabet.randomElement()! }))!
  }
}

public struct PitchMember: Identifiable, Equatable {
  public let id, name: String
  public let connected, host, you: Bool
  public let side: String?
}

@Observable @MainActor public final class OnlinePitch {
  public enum Stage: Equatable {
    case connecting, lobby, match, reconnecting, notFound, full, unreachable, replaced
    /// The join was refused `sealed`: a shared match against the computer, watched and
    /// never joined (the web's docs/ROOMS.md 13.5). The app shows it from its replay.
    case sealed
  }
  public enum VersionCard: String { case newer, older }
  public let controller: PitchController
  public let board: PitchSession
  public let link: PitchLink
  public let teamMax: Int
  public let appVersion: String
  public private(set) var stage = Stage.connecting
  public private(set) var members: [PitchMember] = []
  public private(set) var isHost = false
  public private(set) var canStart = false
  /// Why the pitch cannot start, in a player's words, when the room has no engine every
  /// player carries (`room.engineFor`); nil while it can. Shown in the lobby.
  public private(set) var engineLine: String?
  public private(set) var isOpen = false
  public private(set) var options: [String: String] = [:]
  /// The rows the lobby offers: the room's engine's `MATCH_OPTIONS` (Computer since 0.9).
  /// A scene is kept in the room as the host's engine left it, never offered.
  public private(set) var optionRows: [MatchOption] = []
  public private(set) var versionCard: VersionCard?
  public private(set) var turnLabel = ""
  public var note = ""
  public private(set) var shouts: [String] = []
  public private(set) var name: String
  public private(set) var level: String
  public var changed: (() -> Void)?
  public static let words = ["NICE!", "OOH!", "TOK!", "UNLUCKY"]
  private let create: Bool
  private var firstJoin = true
  private var suspended = false
  private var ended = false
  private var timeout: Task<Void, Never>?
  private var shownVersionKey: String?
  private var shoutTimes: [Int] = []
  private var queue: [(JSONText, JSONNode)] = []
  private var displayControl: JSONText?
  private var displayedMatch: Int?
  private(set) var displayedSeq = 0
  /// The action number the board shows (the local cross-play probe waits on it).
  public var displayedSeqForProbe: Int { displayedSeq }
  private var writing = false
  private var openKey: JSONText?
  private var openAt = 0
  public private(set) var shownAims = 0
  public private(set) var displayCorrections = 0
  public var displayedHash: String { (try? board.engine.hash()) ?? "" }
  public var room: RoomsClient { controller.room }

  public init(
    url: URL, link: PitchLink, create: Bool, name: String, level: String,
    appVersion: String, store: any MemberIDStore = DeviceMemberIDStore(),
    timing: RoomsClient.Timing = .init()
  ) throws {
    self.link = link
    self.create = create
    self.appVersion = appVersion
    board = try PitchSession(appVersion: appVersion)
    let engines = try EngineShelf(appVersion: appVersion)
    let engine = engines.newest
    teamMax = try JSONNode.parse(engine.call("room.constants"))["value"]!["TEAM_MAX"]!.int!
    let clean = try JSONNode.parse(
      engine.call("room.cleanName", json: JS.object([("name", .string(name))]).ascii))
    self.name = clean["value"]?.string ?? ""
    self.level = level
    let room = try RoomsClient(
      url: url, room: link.code, engineVersion: engine.engineVersion,
      appVersion: appVersion, store: store, timing: timing)
    controller = try PitchController(room: room, engines: engines)
    try controller.setMe(name: self.name, level: level)
    board.playerSide = { [weak controller] in controller?.playingSide }
    board.acceptsInput = false
    board.runsComputer = false
    board.onlineAction = { [weak self] in try self?.submit($0) }
    controller.present = { [weak self] in try self?.present($0) }
    controller.didReceive = { [weak self] in self?.receive($0) }
    controller.onClock = { [weak self] in self?.clock($0) }
  }

  public func connect() {
    guard !ended else { return }
    suspended = false
    controller.connect()
  }
  public func background() {
    guard !ended else { return }
    suspended = true
    timeout?.cancel()
    room.close()
    board.acceptsInput = false
    board.runsComputer = false
  }
  public func close() {
    ended = true
    timeout?.cancel()
    changed = nil
    controller.close()
    board.onlineAction = nil
  }
  public func leave() async {
    ended = true
    timeout?.cancel()
    await room.leave()
    close()
  }
  private func receive(_ event: RoomsClient.Event) {
    guard !suspended, !ended else { return }
    do {
      switch event {
      case .status(let status):
        timeout?.cancel()
        openKey = nil
        switch status {
        case .open: return
        case .replaced: finish(.replaced)
        case .closed: stage = .unreachable
        case .connecting, .reconnecting:
          stage = status == .connecting ? .connecting : .reconnecting
          timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.stage = .unreachable
            self?.changed?()
          }
        }
      case .state:
        if room.version == 0 && room.isHost && room.document == .null {
          if !create || !firstJoin {
            finish(.notFound)
            changed?()
            return
          }
          Task { [weak self] in
            guard let self else { return }
            do {
              _ = try await room.update { [self] doc in
                guard doc == .null, room.isHost else { return nil }
                return try controller.roomCall("lobbyOf", [("doc", .raw(doc))]).raw
              }
            } catch { if !ended && !suspended { note = "Could not prepare the lobby." } }
          }
        }
        firstJoin = false
        try refreshRoom()
      case .document(_, _, let rider, _):
        if room.status == .open { try refreshRoom(rider: rider) }
      case .members, .host:
        if room.status == .open { try refreshRoom() }
      case .left: return
      case .message(let m):
        if m["t"]?.string == "error", m["re"]?.string == "join" {
          switch m["code"]?.string {
          case "full": finish(.full)
          case "sealed": finish(.sealed)
          case "bad-room": finish(.notFound)
          case "busy": return
          default: stage = .unreachable
          }
        } else if m["t"]?.string == "cast", let d = m["d"] {
          if d["t"]?.string == "shout", let w = d["w"]?.string, Self.words.contains(w) {
            showShout(w, from: m["from"]?.string)
          } else if d["t"]?.string == "aim", stage == .match, !board.acceptsInput,
            !board.playing, queue.isEmpty, let aim = d["s"],
            let output: AimOutput = try? board.read("showAim", aim.raw.text)
          {
            board.aim(output.aim, camera: output.camera)
            if let dial = output.dial { board.dial = dial }
            shownAims += 1
          } else {
            return
          }
        } else {
          return
        }
      }
      try seat()
      changed?()
    } catch { fail(error) }
  }

  private func refreshRoom(rider: JSONText? = nil) throws {
    let hostChanged = isHost != room.isHost
    isHost = room.isHost
    if hostChanged { openKey = nil }
    let doc = try JSONNode.parse(room.document)
    isOpen = doc["open"]?.bool == true
    if let m = doc["match"], !m.isNull, doc["started"]?.bool == true {
      stage = .match
      if controller.state == .versionMismatch {
        let theirs = m["engine"]?.string
        let identity = "match-\(m["n"]?.int ?? 0)/" + (theirs ?? "")
        if identity != shownVersionKey {
          shownVersionKey = identity
          versionCard = card(theirs: Engine.majorMinor(theirs))
        }
        // An incompatible spectator can try the same recording as the web.
        // Only the display session sees it. The controller never grants a seat.
        let newest = queue.last?.1["seq"]?.int ?? displayedSeq
        if displayedMatch != m["n"]?.int || newest != m["seq"]?.int {
          let local = JS.object([("n", displayedMatch.map(JS.int) ?? .null), ("seq", .int(newest))])
          let d = try controller.roomCall(
            "decide",
            [
              ("local", local), ("doc", .raw(room.document)),
              ("with", rider.map(JS.raw) ?? .null),
            ])
          if d["kind"]?.string == "apply", let action = d["action"] {
            try present(.apply(action: action.raw, match: m))
          } else {
            try restore(m)
          }
        }
      }
      if controller.state == .failed { throw RoomError("session") }
      return
    }
    stage = .lobby
    queue.removeAll()
    displayedMatch = nil
    let l = try controller.roomCall("lobbyOf", [("doc", .raw(room.document))])
    let teams = l["teams"]
    let a = Set(teams?["A"]?.items.compactMap(\.string) ?? [])
    let b = Set(teams?["B"]?.items.compactMap(\.string) ?? [])
    members = try room.members.compactMap { m in
      guard let id = m["id"]?.string else { return nil }
      let n =
        try controller.roomCall("cleanName", [("name", .raw(m["me"]?["name"]?.raw ?? .null))])
        .string ?? ""
      return PitchMember(
        id: id, name: n.isEmpty ? "Someone" : n,
        connected: m["connected"]?.bool == true, host: room.host == id, you: id == room.you,
        side: a.contains(id) ? "A" : b.contains(id) ? "B" : nil)
    }
    isOpen = l["open"]?.bool == true
    // every option, the engine's own (computer, scene) too, on the engine the next
    // match would run on (PitchController.roomOptions)
    options = try controller.roomOptions(room.document)
    optionRows =
      (try? JSONDecoder().decode(
        [MatchOption].self, from: Data(controller.optionRows().raw.text.utf8))) ?? []
    let lineup = try controller.roomCall(
      "lineup", [("doc", .raw(room.document)), ("members", room.membersJSON)])
    // Which engine the next match would run on: the host and every player (watchers
    // do not count). A version is never shown unless it stops play.
    let chosen = try controller.roomEngine()
    engineLine = lineup.isNull || chosen["engine"]?.string != nil ? nil : try blocked(chosen)
    canStart = isHost && !lineup.isNull && engineLine == nil
    if !isHost, members.contains(where: { $0.you && $0.side != nil }) {
      let host = try controller.carried(by: room.host)
      try checkVersion(host, key: room.host ?? "")
    } else {
      versionCard = nil
      shownVersionKey = nil
    }
  }
  /// The lobby's line for a room with no engine every player carries: who to tell, and
  /// what to do. `missing` names those without the engine most of the room shares.
  private func blocked(_ chosen: JSONNode) throws -> String {
    let ids = (chosen["missing"]?.items ?? []).compactMap(\.string)
    func name(_ id: String) -> String { members.first { $0.id == id }?.name ?? "Someone" }
    // Newer or older than this build's newest, by the newest a member carries.
    func newer(_ id: String) throws -> Bool { card(theirs: try controller.carried(by: id).first) == .newer }
    if ids.contains(room.you) {
      let others = members.filter { !$0.you && ($0.side != nil || $0.host) }.map(\.id)
      if try others.contains(where: newer) {
        return "This pitch is on a newer version of Throwing Wood. Update the app to play, or watch."
      }
      let who = others.map(name)
      let names = who.isEmpty ? "Someone" : who.joined(separator: ", ")
      return
        "\(names) \(who.count > 1 ? "are" : "is") on an older version of Throwing Wood. To play together, they need to update the app or reload the page."
    }
    let who = ids.map(name)
    let names = who.isEmpty ? "Someone" : who.joined(separator: ", ")
    let older = try !ids.isEmpty && !ids.contains(where: newer)
    return
      "\(names) \(who.count > 1 ? "are" : "is") on \(older ? "an older" : "another") version of Throwing Wood. To play together, \(older ? "they need to update the app or reload the page" : "update the app or reload the page")."
  }
  /// A seated player's card when the host carries no engine this build does: newer or
  /// older by the newest each carries.
  private func checkVersion(_ theirs: [String], key: String) throws {
    let identity = key + "/" + theirs.joined(separator: ",")
    guard identity != shownVersionKey else { return }
    shownVersionKey = identity
    if theirs.isEmpty || theirs.contains(where: controller.engines.carries) {
      // a host naming no engine is START's to refuse (startCheck's unknown), as before
      versionCard = theirs.isEmpty ? .older : nil
      return
    }
    versionCard = card(theirs: theirs.first)
  }
  private func card(theirs: String?) -> VersionCard {
    let newer = try? controller.newestCall(
      "compareEngines", [("a", theirs.map(JS.string) ?? .null), ("b", .string(Engine.newest))])
    return newer?.int == 1 ? .newer : .older
  }
  public func watch() {
    versionCard = nil
    changed?()
  }

  public func profile(name: String, level: String) throws {
    let clean = try controller.roomCall("cleanName", [("name", .string(name))]).string ?? ""
    if clean != self.name {
      room.setMe([("name", .string(clean))])
      self.name = clean
    }
    if level != self.level {
      room.setMe([("level", .string(level))])
      self.level = level
      if board.acceptsInput && board.need?.cpu == false { try board.useLevel(level) }
    }
  }
  public func team(_ side: String?) async throws { try await controller.joinTeam(side) }
  public func option(_ key: String, _ value: String) async throws {
    _ = try await controller.reduce(
      "setOptions", fields: [("options", .object([(key, .string(value))]))])
  }
  public func access(open: Bool) async throws {
    _ = try await controller.reduce("setAccess", fields: [("open", .bool(open))])
  }
  @discardableResult public func start(seed: Int, at: JSONText) async throws -> Bool {
    note = ""
    let started = try await controller.start(seed: seed, at: at)
    if !started, let mismatch = controller.mismatch {
      let m = try JSONNode.parse(mismatch)
      let ids = (m["differ"]?.items ?? []) + (m["unknown"]?.items ?? [])
      let who = ids.map { id in members.first { $0.id == id.string }?.name ?? "Someone" }
      let chosen = try controller.roomEngine()
      note =
        chosen["engine"]?.string == nil
        ? try blocked(chosen)
        : "\(who.joined(separator: ", ")) \(who.count > 1 ? "are" : "is") on another version of Throwing Wood. To play together, update the app or reload the page."
    }
    try seat()
    changed?()
    return started
  }
  public func rematch() async throws {
    guard let n = controller.matchNumber else { return }
    _ = try await controller.reduce("backToLobby", fields: [("n", .int(n))])
  }
  private func clock(_ now: Int) {
    do {
      if stage == .match, board.canAim, !writing {
        try controller.castAim(JSONText(board.engine.call("aimState")), now: now)
      }
      if room.isHost, isOpen || openKey != nil {
        let info = try controller.roomCall(
          "openListing",
          [
            ("doc", .raw(room.document)), ("members", room.membersJSON),
            ("over", .bool(board.need?.kind == "over" && stage == .match)),
          ]
        ).raw
        if info != openKey || now - openAt >= 300_000 {
          if room.send("open", fields: [("open", .raw(info))]) {
            openKey = info == .null ? nil : info
            openAt = now
          }
        }
      }
      while let first = shoutTimes.first, now - first >= 2600 {
        shoutTimes.removeFirst()
        shouts.removeFirst()
      }
    } catch { fail(error) }
  }
  public func shout(_ word: String) {
    if controller.shout(word) { showShout(word, from: room.you) }
  }
  private func showShout(_ word: String, from: String?) {
    let who = room.members.first { $0["id"]?.string == from }?["me"]?["name"]?.string ?? ""
    shouts.append((who.isEmpty ? "Someone" : who) + "  " + word)
    shoutTimes.append(Int(Date().timeIntervalSince1970 * 1000))
    if shouts.count > 4 {
      shouts.removeFirst()
      shoutTimes.removeFirst()
    }
  }

  private func present(_ event: PitchController.Presentation) throws {
    switch event {
    case .restore(let m): try restore(m)
    case .apply(let action, let m):
      queue.append((action, m))
      try drain()
    }
  }
  private func restore(_ m: JSONNode) throws {
    guard let snap = m["snap"]?.string else { throw RoomError("snapshot") }
    // The board plays the match on its own engine; one this build does not carry (a
    // spectator's try, as on the web) is shown on the newest.
    let theirs = Engine.majorMinor(m["engine"]?.string)
    try board.useEngine(minor: controller.engines.carries(theirs) ? theirs : nil)
    let view: ViewOutput = try board.read("restore", snap)
    board.resetPresentation()
    board.need = view.need
    try board.adopt(view)
    displayedMatch = m["n"]?.int
    displayedSeq = m["seq"]?.int ?? 0
    displayControl = nil
    queue.removeAll()
    board.trail = ReportTrail(snapshot: snap)
  }
  private func seat() throws {
    let current =
      stage == .match && controller.state == .match && room.status == .open && !suspended && !ended
    let caughtUp =
      current && !writing && queue.isEmpty && !controller.pending
      && displayedSeq == controller.sequence
    let wasActing = board.acceptsInput
    board.acceptsInput = caughtUp && controller.mayAct
    if wasActing && !board.acceptsInput {
      board.resetContact()
      board.levelOverride = nil
    }
    let control = current ? controller.control : JSONText(#"{"sides":[],"cpu":false}"#)
    if board.need != nil, control != .null, control != displayControl {
      if board.need?.cpu == true, !board.playing,
        (try JSONNode.parse(control))["cpu"]?.bool == true
      {
        _ = try board.engine.call("restore", json: board.engine.call("snapshot"))
      }
      _ = try board.engine.call("setControl", json: control.text)
      displayControl = control
    }
    board.runsComputer = caughtUp && (try? JSONNode.parse(control)["cpu"]?.bool) == true
    if current { turnLabel = controller.actorDescription }
    if board.acceptsInput && !wasActing && board.need?.cpu == false { try board.useLevel(level) }
  }
  private func drain() throws {
    while !board.playing, !queue.isEmpty {
      let (action, m) = queue.removeFirst()
      if (try? applyOnBoard(action)) == nil || displayedHash != m["hash"]?.string {
        displayCorrections += 1
        if let latest = controller.match { try restore(latest) } else { try restore(m) }
        return
      }
      displayedSeq = m["seq"]?.int ?? 0
      track(action)
    }
  }
  private func applyOnBoard(_ action: JSONText) throws {
    struct Applied: Decodable { let ok: Bool, recording: Recording? }
    let out: Applied = try board.read("apply", action.text)
    guard out.ok else { throw RoomError("refused") }
    board.dismissHandoff()
    if let recording = out.recording {
      try board.beginPlayback(recording)
    } else {
      try board.adopt(board.read("view"))
    }
  }
  private func track(_ action: JSONText) {
    board.trail.append(action, snapshot: (try? board.engine.call("snapshot")) ?? board.trail.now)
  }
  /// Scripted seats use the same release/placement submission as a gesture.
  public func act(_ action: JSONText) throws {
    guard board.acceptsInput, !board.playing else { throw RoomError("not-acting") }
    try applyOnBoard(action)
    try submit(action)
  }
  private func submit(_ action: JSONText) throws {
    let cpu = board.need?.cpu == true && board.runsComputer
    guard board.acceptsInput || cpu, !writing, let n = displayedMatch else {
      throw RoomError("not-acting")
    }
    writing = true
    track(action)
    let base = displayedSeq
    displayedSeq += 1
    board.acceptsInput = false
    board.runsComputer = false
    Task { [weak self] in
      guard let self else { return }
      do {
        let ok = controller.matchNumber == n && controller.sequence == base
        let landed = ok ? try await controller.take(action, computer: cpu) : false
        writing = false
        guard !ended && !suspended else { return }
        if !landed, let latest = controller.match { try restore(latest) }
        try seat()
        changed?()
      } catch {
        writing = false
        guard !ended && !suspended else { return }
        if let latest = controller.match { try? restore(latest) }
        try? seat()
        note = "The pitch did not take that. Try again."
        changed?()
      }
    }
  }
  public func skip() throws {
    try board.skipPlayback()
    try drain()
    try seat()
    changed?()
  }
  @discardableResult public func tick(_ dt: Double) throws -> Bool {
    let playing = board.playing
    let drew = try board.tick(dt)
    if playing && !board.playing {
      try drain()
      try seat()
    }
    return drew
  }
  // A terminal join or replacement must survive a background/foreground cycle.
  // Only a fresh entry from Home can make another attempt with this identity.
  private func finish(_ reason: Stage) {
    ended = true
    timeout?.cancel()
    stage = reason
    board.acceptsInput = false
    board.runsComputer = false
    controller.close()
  }
  private func fail(_ error: Error) {
    note = String(describing: error)
    stage = .unreachable
    board.acceptsInput = false
    board.runsComputer = false
    changed?()
  }
}
