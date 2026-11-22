import Foundation
import KubbEngine
import KubbPitch
import Observation

public struct PitchLink: Equatable, Sendable {
  public let code: String
  /// `?observe=1`: watch the pitch as an observer, with no seat (the web's
  /// docs/OBSERVER.md). The pitch's own link (`url`) never carries it.
  public var observe = false
  public var url: URL { URL(string: "https://throwingwood.com/p/" + code)! }
  /// The same pitch, joined (`observe` false) or watched as an observer.
  public func observing(_ on: Bool) -> Self {
    var link = self
    link.observe = on
    return link
  }
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
      observe = url.queryItems?.contains { $0.name == "observe" && $0.value == "1" } == true
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
    /// An observer at a pitch nobody has used: the pitch refuses it `no-pitch` and keeps
    /// nothing. "No game here".
    case noGame
    /// A shared match against the computer (the API's replay says `sealed`): watched and
    /// never joined (the web's docs/ROOMS.md 13.5). The app shows it from its replay.
    case sealed
    /// The match on the pitch holds a name the game did not make (a forged start): not
    /// shown, "Cannot show this match" (NameWords).
    case namesRefused
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
  /// player carries (`pitch.engineFor`); nil while it can. Shown in the lobby.
  public private(set) var engineLine: String?
  public private(set) var isOpen = false
  /// Each side's team name as shown (the document's `teamNames` when it passes, else
  /// "Team A" / "Team B"): a side of several plays under it, and the lobby shows PLAYS AS.
  public private(set) var teamNames: [String: String] = ["A": "Team A", "B": "Team B"]
  public private(set) var options: [String: String] = [:]
  /// The rows the lobby offers: the lobby engine's card for the room's scene
  /// (`pitch.optionRows({ scene })`, since 0.14): Scene first, a Surface row only where
  /// the scene leaves one, then Computer (Kid first since 0.15), Opening, Raising and
  /// Wind, in the solo card's order (`SoloOptions.ordered`), never `hiddenRows`.
  public private(set) var optionRows: [MatchOption] = []
  /// Rows the lobby never shows (the web's HIDDEN_ROWS): the set, which the scene
  /// decides (the 1.0 design), as on the solo card; the engine's card has no Kubbs row
  /// while no scene allows two sets.
  public static let hiddenRows: Set<String> = ["set"]
  /// The scene the lobby shows: the room's `settings.scene` on an engine that takes one,
  /// else the day. An id this build does not draw is the day, and kept in the room.
  public var lobbyScene: String {
    optionRows.contains { $0.id == "scene" } ? SceneID.shown(options["scene"]) : "day"
  }
  public private(set) var versionCard: VersionCard?
  public private(set) var turnLabel = ""
  /// Someone else's turn starting, while this device watches: the handoff card's words
  /// as a banner for `HandoffBanner.seconds`, so the remote dial shows under it instead
  /// of behind a card. The thrower's own card stays the modal THROW card.
  public private(set) var watchHandoff: HandoffBanner?
  public var note = ""
  public private(set) var shouts: [String] = []
  public private(set) var name: String
  public var changed: (() -> Void)?
  public static let words = ["NICE!", "OOH!", "TOK!", "UNLUCKY"]
  private let create: Bool
  private var firstJoin = true
  private var suspended = false
  private var ended = false
  private var timeout: Task<Void, Never>?
  private var shownVersionKey: String?
  /// The match (its `n`) whose snapshot the board refused through the strict door: shown
  /// as "Cannot show this match" until another match or the lobby.
  private var boardRefused: Int?
  private var shoutTimes: [Int] = []
  /// Actions to show, each with when it may play (this device's ms): a peer's throw waits
  /// for its aim to play out first (`AimBuffer.holdFor`).
  private var queue: [(JSONText, JSONNode, Int)] = []
  private var holding: Task<Void, Never>?
  /// This member's own action was submitted during the current tick.
  private var released = false
  private var displayControl: JSONText?
  private var displayedMatch: Int?
  private(set) var displayedSeq = 0
  /// The action number the board shows (the local cross-play probe waits on it).
  public var displayedSeqForProbe: Int { displayedSeq }
  private var writing = false
  private var openKey: JSONText?
  private var openAt = 0
  /// Someone else's aim, played behind the pitch's clock (`AimBuffer`).
  private var aims = AimBuffer()
  private var shownAim: JSONText?
  public private(set) var shownAims = 0
  public private(set) var displayCorrections = 0
  public var displayedHash: String { (try? board.engine.hash()) ?? "" }
  public var pitch: PitchClient { controller.pitch }
  /// The API, for the sealed check of a pitch with nobody on it; nil skips it.
  private let api: PitchAPI?
  /// An observer (`link.observe`): a member with no seat that never acts, never writes
  /// the document and is never host (PitchController.observing).
  public var observing: Bool { controller.observing }
  private let defaults: UserDefaults

  /// The lobby options this device last picked as a host, for the next pitch it hosts
  /// (the web's `pitchOptions`): `[key: value]`, each set as it is picked.
  static let hostOptionsKey = "pitch.hostOptions"
  /// Before 0.5 only the scene was kept, here (read once into `hostOptionsKey`).
  static let hostSceneKey = "pitch.hostScene"
  /// The kept host options. A kept scene is put on a new pitch only when it is one of
  /// the Scene row's (an old or unknown value is dropped); the controller then drops
  /// whatever the new pitch's engine does not take (`PitchController.takenOptions`).
  static func keptOptions(_ defaults: UserDefaults) -> [String: String] {
    var kept = storedOptions(defaults)
    if let scene = kept["scene"], !SceneID.catalogue.contains(where: { $0.id == scene }) {
      kept["scene"] = nil
    }
    return kept
  }
  /// What is stored, the older lone scene read in when nothing newer is.
  private static func storedOptions(_ defaults: UserDefaults) -> [String: String] {
    if let all = defaults.dictionary(forKey: hostOptionsKey) {
      return all.compactMapValues { $0 as? String }
    }
    if let scene = defaults.string(forKey: hostSceneKey) { return ["scene": scene] }
    return [:]
  }
  /// One option the host picked, kept with the rest (and the older key dropped).
  static func keep(_ key: String, _ value: String, in defaults: UserDefaults) {
    var all = storedOptions(defaults)
    all[key] = value
    defaults.set(all, forKey: hostOptionsKey)
    defaults.removeObject(forKey: hostSceneKey)
  }

  public init(
    url: URL, link: PitchLink, create: Bool, name: String,
    appVersion: String, store: any MemberIDStore = DeviceMemberIDStore(),
    observerStore: any MemberIDStore = ObserverMemberIDStore.shared,
    timing: PitchClient.Timing = .init(), defaults: UserDefaults = .standard,
    api: PitchAPI? = nil, factory: PitchClient.Factory? = nil
  ) throws {
    self.link = link
    self.api = api
    self.defaults = defaults
    self.create = create
    self.appVersion = appVersion
    board = try PitchSession(appVersion: appVersion)
    let engines = try EngineShelf(appVersion: appVersion)
    let engine = engines.newest
    teamMax = try JSONNode.parse(engine.call("pitch.constants"))["value"]!["TEAM_MAX"]!.int!
    // the device's name, a generated one (PlayerName): sent as it is
    self.name = name
    let client = try PitchClient(
      url: url, pitch: link.code, appVersion: appVersion,
      // a watcher joins with an id of its own, never the player's: a member's role is
      // fixed while it is on the pitch
      store: store.joining(observing: link.observe, observer: observerStore),
      observing: link.observe, create: create, timing: timing,
      factory: factory ?? { WebSocketTransport(request: $0) })
    controller = try PitchController(pitch: client, engines: engines)
    try controller.setMe(name: self.name)
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
    pitch.close()
    board.acceptsInput = false
    board.runsComputer = false
  }
  public func close() {
    ended = true
    timeout?.cancel()
    holding?.cancel()
    changed = nil
    controller.close()
    board.onlineAction = nil
  }
  public func leave() async {
    ended = true
    timeout?.cancel()
    await pitch.leave()
    close()
  }
  /// How long the screen says CONNECTING, never connected yet, before it says the pitch
  /// cannot be reached (the web's stuckMs). The client keeps trying either way, and the
  /// pitch comes back when it answers; a drop after joining stays RECONNECTING.
  public static let reconnectingFor: Duration = .seconds(8)  // the web's pitch.js stuckMs
  private func receive(_ event: PitchClient.Event) {
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
        case .reconnecting: stage = .reconnecting
        case .connecting:
          stage = .connecting
          // never connected yet: after a while say so (the client keeps trying)
          timeout = Task { [weak self] in
            do { try await Task.sleep(for: Self.reconnectingFor) } catch { return }
            self?.stage = .unreachable
            self?.changed?()
          }
        }
      case .state:
        aims.reset()
        if pitch.version == 0 && pitch.isHost && pitch.document == .null {
          if observing {
            noGame()
            changed?()
            return
          }
          if !create || !firstJoin {
            gone()
            changed?()
            return
          }
          Task { [weak self] in
            guard let self else { return }
            do {
              try await controller.prepareLobby(options: Self.keptOptions(defaults))
            } catch { if !ended && !suspended { note = "Could not prepare the lobby." } }
          }
        }
        firstJoin = false
        try refreshPitch()
      case .document:
        if pitch.status == .open { try refreshPitch() }
      case .members, .host:
        if pitch.status == .open { try refreshPitch() }
      case .left: return
      case .message(let m):
        switch m["t"]?.string {
        case "error" where m["re"]?.string == "join":
          switch m["code"]?.string {
          case "full": finish(.full)
          case "no-pitch":
            if observing { noGame() } else { gone() }
          case "bad-member", "bad-role", "already-joined": finish(.notFound)
          case "bad-message": stage = .unreachable
          default: break  // refused for now: the client tries again
          }
        case "cast":
          guard let d = m["d"] else { return }
          if d["t"]?.string == "shout", let w = d["w"]?.string, Self.words.contains(w) {
            showShout(w, from: m["m"]?.string)
          } else if d["t"]?.string == "aim", let aim = d["s"], let ts = m["ts"]?.int {
            aims.add(aim, from: m["m"]?.string, ts: ts, k: d["k"]?.int, now: Self.now())
            return
          } else {
            return
          }
        case "start", "act", "ok", "refused":
          // the controller has taken it in (and presented what changed)
          if stage == .match || controller.match != nil { try refreshPitch() }
        default: return
        }
      }
      try seat()
      changed?()
    } catch { fail(error) }
  }

  private func refreshPitch() throws {
    let hostChanged = isHost != pitch.isHost
    isHost = pitch.isHost
    if hostChanged { openKey = nil }
    let doc = try JSONNode.parse(pitch.document)
    isOpen = doc["open"]?.bool == true
    if controller.state == .namesRefused, doc["started"]?.bool == true {
      stage = .namesRefused
      return
    }
    // the board refused this match's snapshot itself (a watch-only match on an engine
    // this build lacks, which the controller hands over unchecked): the refusal stays
    // with that match through every refresh, until another match or the lobby
    if let m = controller.match, doc["started"]?.bool == true, let n = boardRefused, n == m["n"]?.int {
      stage = .namesRefused
      return
    }
    if let m = controller.match, doc["started"]?.bool == true {
      stage = .match
      if controller.state == .versionMismatch {
        // An incompatible spectator tries the match on the newest engine, as the web
        // does: the controller presents it to the board, and never grants a seat.
        let theirs = m["engine"]?.string
        let identity = "match-\(m["n"]?.int ?? 0)/" + (theirs ?? "")
        if identity != shownVersionKey {
          shownVersionKey = identity
          versionCard = card(theirs: Engine.majorMinor(theirs))
        }
      }
      if controller.state == .failed { throw PitchError("session") }
      return
    }
    stage = .lobby
    boardRefused = nil
    queue.removeAll()
    displayedMatch = nil
    let l = try controller.pitchCall("lobbyOf", [("doc", .raw(pitch.document))])
    let teams = l["teams"]
    let a = Set(teams?["A"]?.items.compactMap(\.string) ?? [])
    let b = Set(teams?["B"]?.items.compactMap(\.string) ?? [])
    // every name checked (a generated name or a default, else "Player n"), two alike
    // told apart ("II"): never the text that failed (docs/ONLINE.md "Names")
    let shown = controller.shownNames().apart
    teamNames = ["A": controller.teamNameOf("A"), "B": controller.teamNameOf("B")]
    members = pitch.members.compactMap { m in
      guard let id = m["id"]?.string else { return nil }
      return PitchMember(
        id: id, name: shown[id] ?? "Someone",
        connected: m["connected"]?.bool == true, host: pitch.host == id, you: id == pitch.you,
        side: a.contains(id) ? "A" : b.contains(id) ? "B" : nil)
    }
    isOpen = l["open"]?.bool == true
    // every option, the engine's own (computer, scene) too, on the engine the next
    // match would run on (PitchController.roomOptions)
    options = try controller.roomOptions(pitch.document)
    let card = controller.optionRows(scene: options["scene"] ?? "day")?["rows"] ?? (try? controller.optionRows())
    optionRows = SoloOptions.ordered(
      ((try? JSONDecoder().decode([MatchOption].self, from: Data((card?.raw.text ?? "[]").utf8))) ?? []).filter {
        !Self.hiddenRows.contains($0.id)
      })
    let lineup = try controller.pitchCall(
      "lineup", [("doc", .raw(pitch.document)), ("members", pitch.membersJSON)])
    // Which engine the next match would run on: the host and every player (watchers
    // do not count). A version is never shown unless it stops play.
    let chosen = try controller.roomEngine()
    engineLine = lineup.isNull || chosen["engine"]?.string != nil ? nil : try blocked(chosen)
    canStart = isHost && !observing && !lineup.isNull && engineLine == nil
    // the host rolls a team name for a side that has come to several players, once, so
    // everyone sees what it will play as (the web's rollTeamNames)
    if isHost, !observing { Task { [weak self] in _ = try? await self?.controller.rollTeamNames() } }
    if !isHost, members.contains(where: { $0.you && $0.side != nil }) {
      let host = try controller.carried(by: pitch.host)
      try checkVersion(host, key: pitch.host ?? "")
    } else {
      versionCard = nil
      shownVersionKey = nil
    }
  }
  /// The lobby's line for a room with no engine every player carries (VersionWords.lobby).
  /// `missing` names those without the engine most of the room shares and `unknown` those
  /// naming none (an older client).
  private func blocked(_ chosen: JSONNode) throws -> String {
    let ids = ((chosen["missing"]?.items ?? []) + (chosen["unknown"]?.items ?? [])).compactMap(\.string)
    // newer or older than this build's newest, by the newest a member carries
    var newer: [String: Bool] = [:]
    for m in members where !m.you {
      newer[m.id] = card(theirs: try controller.carried(by: m.id).first) == .newer
    }
    return VersionWords.lobby(
      missing: ids, you: pitch.you,
      players: members.filter { !$0.you && ($0.side != nil || $0.host) }.map(\.id),
      isNewer: { newer[$0] ?? false },
      name: { id in members.first { $0.id == id }?.name ?? "Someone" })
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

  /// The device's name (Settings), as the room knows it. A person has no level to send
  /// (engine 0.13: the pitch takes "club" for a member that names none, and changes
  /// nothing with it).
  public func profile(name: String) throws {
    if name != self.name, controller.names.valid(.player, name).ok {
      pitch.setMe([("name", .string(name))])
      self.name = name
    }
  }
  /// The host picks a side's team name in the lobby (its name row).
  public func teamName(_ side: String, _ text: String) async throws {
    try await controller.setTeamName(side, text)
  }

  /// The host's name row for a side's team name ("Team A's name"), once the side has a
  /// generated team name (rolled when it came to several players); nil for everyone
  /// else, who read the name as text, and until then.
  public func teamRow(_ side: String) -> NameRowModel? {
    guard isHost, !observing, let text = teamNames[side], controller.names.valid(.team, text).ok else { return nil }
    if let row = teamRows[side] {
      row.set(text)
      return row
    }
    let row = NameRowModel(names: controller.names, kind: .team, text: text, label: "Team \(side)'s name")
    row.onChange = { [weak self] t in
      Task { [weak self] in try? await self?.teamName(side, t) }
    }
    teamRows[side] = row
    return row
  }
  @ObservationIgnored private var teamRows: [String: NameRowModel] = [:]
  public func team(_ side: String?) async throws { try await controller.joinTeam(side) }
  public func option(_ key: String, _ value: String) async throws {
    // the host's options are kept for the next pitch they host, as the web keeps them
    if isHost { Self.keep(key, value, in: defaults) }
    // the scene goes with every write (engine 0.14: the pitch holds the surface and the
    // set to the named scene's), so a change of scene brings its own ground
    var sent: [(String, JS)] = [(key, .string(value))]
    if key != "scene", controller.lobbyTakesScene() { sent.append(("scene", .string(options["scene"] ?? "day"))) }
    _ = try await controller.reduce("setOptions", fields: [("options", .object(sent))])
  }
  public func access(open: Bool) async throws {
    _ = try await controller.reduce("setAccess", fields: [("open", .bool(open))])
  }
  @discardableResult public func start(seed: Int, at: JSONText) async throws -> Bool {
    note = ""
    let started = try await controller.start(seed: seed, at: at)
    // the host's START is answered `ok`, not `start`: its document event came before the
    // controller held the match, so the pitch is taken up here
    if started, !ended { try refreshPitch() }
    if !started, let mismatch = controller.mismatch {
      let m = try JSONNode.parse(mismatch)
      let ids = (m["differ"]?.items ?? []) + (m["unknown"]?.items ?? [])
      let who = ids.map { id in members.first { $0.id == id.string }?.name ?? "Someone" }
      let chosen = try controller.roomEngine()
      note = chosen["engine"]?.string == nil ? try blocked(chosen) : VersionWords.another(who)
    }
    try seat()
    changed?()
    return started
  }
  public func rematch() async throws {
    guard let n = controller.matchNumber else { return }
    _ = try await controller.reduce("backToLobby", fields: [("n", .int(n))])
  }
  static func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
  private func clock(_ now: Int) {
    do {
      if pitch.isHost, !observing, isOpen || openKey != nil {
        let listing = try controller.pitchCall(
          "openListing",
          [
            ("doc", .raw(pitch.document)), ("members", pitch.membersJSON),
            ("over", .bool(board.need?.kind == "over" && stage == .match)),
          ]
        )
        // the pitch counts players and watchers itself: only seats and state go
        let info =
          listing.isNull
          ? JSONText.null
          : JS.object([
            ("seats", .raw(listing["seats"]?.raw ?? JSONText("12"))),
            ("state", .raw(listing["state"]?.raw ?? JSONText(#""waiting""#))),
          ]).json
        if info != openKey || now - openAt >= 300_000 {
          if pitch.list(info) {
            openKey = info == .null ? nil : info
            openAt = now
          }
        }
      }
      if let banner = watchHandoff, now >= banner.until { watchHandoff = nil }
      while let first = shoutTimes.first, now - first >= 2600 {
        shoutTimes.removeFirst()
        shouts.removeFirst()
      }
    } catch { fail(error) }
  }
  public func shout(_ word: String) {
    guard !observing else { return }
    if controller.shout(word) { showShout(word, from: pitch.you) }
  }
  private func showShout(_ word: String, from: String?) {
    shouts.append(controller.nameOf(from) + "  " + word)
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
      let now = Self.now()
      let isThrow = (try? JSONNode.parse(action))?["type"]?.string == "throw"
      let hold = isThrow ? aims.holdFor(ts: controller.remoteTs, now: now) : 0
      queue.append((action, m, now + hold))
      try drain()
    }
  }
  private func restore(_ m: JSONNode) throws {
    guard let snap = m["snap"]?.string else { throw PitchError("snapshot") }
    // The board plays the match on its own engine; one this build does not carry (a
    // spectator's try, as on the web) is shown on the newest.
    let theirs = Engine.majorMinor(m["engine"]?.string)
    try board.useEngine(minor: controller.engines.carries(theirs) ? theirs : nil)
    // a snapshot someone else sent: through restore's strict door, refused before the
    // board changes when its names are not all the game's (a spectator's try of a match
    // on an engine this build lacks comes here unchecked by the controller)
    guard let view: ViewOutput = try? board.read("restore", Names.checkedRestore(snap)) else {
      boardRefused = m["n"]?.int ?? -1
      stage = .namesRefused
      return
    }
    boardRefused = nil
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
      stage == .match && controller.state == .match && pitch.status == .open && !suspended && !ended
    let caughtUp =
      current && !writing && queue.isEmpty && !controller.starting
      && displayedSeq == controller.sequence
    let wasActing = board.acceptsInput
    board.acceptsInput = caughtUp && controller.mayAct
    if wasActing && !board.acceptsInput {
      board.resetContact()
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
    // with no side in the match this board watches (the watcher's view and free camera)
    board.watching = stage == .match && (observing || controller.playingSide == nil)
    if current { turnLabel = controller.actorDescription }
    // Someone else's turn: its card becomes a banner, so the dial shows under it.
    if caughtUp, !controller.mayAct, !board.acceptsInput, let c = board.handoff {
      watchHandoff = HandoffBanner(handoff: c, until: Self.now() + HandoffBanner.ms)
      board.dismissHandoff()
    }
  }
  private func drain() throws {
    while !board.playing && !board.raiseShowing, let first = queue.first {
      let wait = first.2 - Self.now()
      if wait > 0 {
        if holding == nil {
          holding = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(wait)) } catch { return }
            guard let self, !self.ended else { return }
            self.holding = nil
            do { try self.drain() } catch { self.fail(error) }
            do { try self.seat() } catch {}
            self.changed?()
          }
        }
        return
      }
      let (action, m, _) = queue.removeFirst()
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
    // a raise of the kubb on the screen is watched tipping up (AutoRaise.swift), at the
    // sender's pace, before the next action is drawn
    let raised = board.raiseEnd(of: action)
    let out: Applied = try board.read("apply", action.text)
    guard out.ok else { throw PitchError("refused") }
    board.dismissHandoff()
    if let recording = out.recording {
      try board.beginPlayback(recording)
    } else if board.need?.kind == "raise", (try? JSONNode.parse(action.text))?["type"]?.string == "raise" {
      try board.watchRaise(end: raised)
    } else {
      try board.adopt(board.read("view"))
    }
  }
  private func track(_ action: JSONText) {
    board.trail.append(action, snapshot: (try? board.engine.call("snapshot")) ?? board.trail.now)
  }
  /// Scripted seats use the same release/placement submission as a gesture.
  public func act(_ action: JSONText) throws {
    guard board.acceptsInput, !board.playing, !board.raiseShowing else { throw PitchError("not-acting") }
    try applyOnBoard(action)
    try submit(action)
  }
  private func submit(_ action: JSONText) throws {
    let cpu = board.need?.cpu == true && board.runsComputer
    guard board.acceptsInput || cpu, !writing, let n = displayedMatch else {
      throw PitchError("not-acting")
    }
    writing = true
    released = !cpu
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
    let playing = board.playing || board.raiseShowing
    // this member's aim as it stands before the frame: a release in this frame sends it
    let aim = stage == .match && board.canAim && !writing ? JSONText(try board.engine.call("aimState")) : nil
    released = false
    let drew = try board.tick(dt)
    if playing && !board.playing && !board.raiseShowing {
      try drain()
      try seat()
    }
    let now = Self.now()
    if let aim {
      if released {
        // the release's aim goes at once and unthinned (`all`), before the act (the web's
        // AimSender flush), so watchers see the swing finish
        try controller.castAim(aim, final: true, now: now)
      } else if !writing {
        // this member's aim, at most 15 a second while it changes
        try controller.castAim(aim, now: now)
      }
    }
    return try showRemoteAim(now: now) || drew
  }

  /// Someone else's aim as it stood `AimBuffer.delay` ms ago on the pitch's clock,
  /// moved smoothly between their casts. Only while this board waits on their throw.
  private func showRemoteAim(now: Int) throws -> Bool {
    // a throw held for its aim (`AimBuffer.holdFor`) lets the swing play out first
    let waiting = queue.first.map { $0.2 > now } ?? true
    guard stage == .match, !board.acceptsInput, !board.playing, waiting,
      let aim = aims.sample(now: now), aim != shownAim,
      let output: AimOutput = try? board.read("showAim", aim.text)
    else { return false }
    shownAim = aim
    board.aim(output.aim, camera: output.camera)
    if let dial = output.dial { board.dial = dial }
    shownAims += 1
    return true
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
  /// An observer at a pitch nobody has used: "No game here" (the pitch refused it
  /// `no-pitch` and kept nothing).
  private func noGame() {
    ended = true
    timeout?.cancel()
    stage = .noGame
    board.acceptsInput = false
    board.runsComputer = false
    board.watching = false
    controller.close()
  }
  /// A link to a pitch with nobody on it that this device did not make: off it at once
  /// (`leave`, so it keeps no member), then the API's replay says whether it is a
  /// shared match against the computer (sealed, shown from its replay) or not there.
  private func gone() {
    ended = true
    timeout?.cancel()
    stage = .connecting
    board.acceptsInput = false
    board.runsComputer = false
    let controller = controller
    let api = api
    let code = link.code
    Task { [weak self] in
      if controller.pitch.isJoined { await controller.pitch.leave() }
      controller.close()
      let sealed = (try? await api?.replay(pitch: code))??.sealed == true
      guard let self else { return }
      self.stage = sealed ? .sealed : .notFound
      self.changed?()
    }
  }
  private func fail(_ error: Error) {
    note = String(describing: error)
    stage = .unreachable
    board.acceptsInput = false
    board.runsComputer = false
    changed?()
  }
}

/// Someone else's turn starting, as a banner over the pitch while this device watches
/// (`OnlinePitch.watchHandoff`): the handoff card's words, gone after `ms`.
public struct HandoffBanner {
  public static let ms = 2500
  public let handoff: MatchNeed.Handoff
  public let until: Int
}
