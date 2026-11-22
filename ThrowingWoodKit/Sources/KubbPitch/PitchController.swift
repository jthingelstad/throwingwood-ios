import Foundation
import KubbEngine

/// A headless pitch. Lobby, seat and engine rules are exclusively the engine's `pitch.*`;
/// this type owns the effects: socket writes, engine actions, the optimistic action
/// queue and its recovery, and the host's clock.
///
/// The pitch server keeps the lobby (`doc`, compare-and-set) and the match apart: a
/// match is its start info (`meta`), its first hash, and the actions after it, each
/// stored with the hash and snapshot after it. This member applies its own action at
/// once and sends it (`act`); it never waits for the answer before the next. Each
/// action not yet answered is `outstanding`, on top of the confirmed head. A peer's
/// action that arrives first wins: the outstanding ones are dropped (the pitch refuses
/// them too), the engine goes back to the head and plays the peer's action.
@MainActor public final class PitchController {
  /// `namesRefused`: the match on the pitch holds a name the game did not make (a forged
  /// start), so it is not shown or played here (NameWords.badMatch).
  public enum State: String, Sendable { case lobby, match, versionMismatch, namesRefused, closed, failed }
  public let pitch: PitchClient
  /// The engines this pitch can run (one Lua state per major.minor, made lazily).
  public let engines: EngineShelf
  /// The engine the pitch runs on now: the match's own (`meta.engine`) once there is
  /// one this build carries, else the newest (kubb-engine docs/ROOM.md "Speaking down").
  public private(set) var engine: Engine
  /// The presence fields last announced (`pitch.announce`: `engine` and `engines`).
  public private(set) var announced: JSONText?
  public private(set) var state: State = .lobby
  public private(set) var mismatch: JSONText?
  public private(set) var lastError: String?
  /// The match on the pitch, its number, and the action number this member holds:
  /// the confirmed head plus its own outstanding actions.
  public var matchNumber: Int? { head?.n }
  public var sequence: Int { (head?.seq ?? 0) + outstanding.count }
  /// The confirmed head: the last action the pitch stored that this member has.
  public private(set) var head: (n: Int, seq: Int, h: String, over: Bool)?
  /// This member's actions sent and not yet answered, in order.
  public private(set) var outstanding: [Outstanding] = []
  public struct Outstanding: Sendable {
    public let id: String
    public let n, seq: Int
    public let a: JSONText
    public let h: String
    public let snap: String
    public let over: Bool
  }
  /// A START on its way.
  public private(set) var starting = false
  /// A START on its way or actions not yet answered.
  public var pending: Bool { starting || !outstanding.isEmpty }
  /// Peer actions played on this engine and matching their hash; corrections (the
  /// engine put back to the pitch's state); whole matches taken from a join or resync;
  /// conflicts lost (own actions dropped for a peer's).
  public private(set) var applied = 0
  public private(set) var corrections = 0
  public private(set) var adoptions = 0
  public private(set) var conflicts = 0
  public private(set) var mayAct = false
  public private(set) var control = JSONText.null
  public private(set) var need = JSONText.null
  public private(set) var lastCast: JSONText?
  public enum Presentation {
    case restore(JSONNode)
    case apply(action: JSONText, match: JSONNode)
  }
  public var present: ((Presentation) throws -> Void)?
  /// The pitch's `ts` on the peer's action being presented (nil for a resumed one), so a
  /// watcher can let the aim before a throw play out first (`AimBuffer.holdFor`).
  public private(set) var remoteTs: Int?
  public var didReceive: ((PitchClient.Event) -> Void)?
  public var onClock: ((Int) -> Void)?
  /// The match as the engine's room calls take it: the start info (`meta`) with `n`,
  /// `seq`, `snap` (this member's state now), `hash`, `h0` and `over`. Nil in the lobby.
  public private(set) var match: JSONNode?
  /// The match's start info as the host sent it in `start`.
  public private(set) var meta: JSONNode?
  private var h0: String?
  /// The snapshot at the confirmed head (`head`), to go back to.
  private var headSnap: String?
  /// The last match number the pitch has had: the next START is this plus one.
  private var lastN = 0
  /// A `resync` was sent; nothing more is played until its `state`.
  public private(set) var awaitingState = false
  /// The engine's names door (the newest's words): every name this pitch shows, writes or
  /// starts a match with is checked through it (docs/ONLINE.md "Names").
  public private(set) lazy var names = Names(engine: engines.newest)
  private var observation: UUID?
  private var clock: Task<Void, Never>?
  private var lastAim: JSONText?
  private var lastAimAt = 0
  private var aimCount = 0
  private var lastShoutAt: Int?
  /// An observer (`?observe=1`, the web's docs/OBSERVER.md): a member with no seat
  /// that never acts, never writes the document and is never host (the pitch decides).
  public let observing: Bool
  static let noSeat = JSONText(#"{"sides":[],"cpu":false}"#)
  /// Aim is cast at most this often while it changes (15 a second; the pitch takes 16).
  public static let aimEvery = 66

  public init(pitch: PitchClient, engines: EngineShelf) throws {
    self.pitch = pitch
    self.engines = engines
    observing = pitch.observing
    engine = engines.newest
    observation = pitch.observe { [weak self] in self?.receive($0) }
    pitch.cursor = { [weak self] in
      guard let self, let head = self.head, self.state == .match || self.state == .versionMismatch
      else { return nil }
      return (head.n, head.seq)
    }
    try announce()
  }

  /// A pitch on one engine only.
  public convenience init(pitch: PitchClient, engine: Engine) throws {
    try self.init(pitch: pitch, engines: EngineShelf(engine: engine))
  }

  /// Starts the wire and a 200 ms presence clock. Call close when the owner ends.
  public func connect() {
    pitch.connect()
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
      pitch.removeObserver(observation)
      self.observation = nil
    }
    pitch.close()
    state = .closed
    mayAct = false
  }

  /// One of the engine's pitch calls (`pitch.<name>`, kubb-engine docs/PITCH.md) on the
  /// match's engine. Engine 0.13 renamed the module; `room.` was the spelling only the
  /// engines before it needed, and none is carried (docs/ENGINES.md).
  public func pitchCall(_ name: String, _ args: [(String, JS)] = []) throws -> JSONNode {
    try Self.pitchCall(engine, name, args)
  }
  /// A pitch call of the newest engine: the calls for several engines in one room
  /// (`engineFor`, `carried`, `announce`, `speakAs`, `compareEngines`) are only there.
  public func newestCall(_ name: String, _ args: [(String, JS)] = []) throws -> JSONNode {
    try Self.pitchCall(engines.newest, name, args)
  }
  private static func pitchCall(_ engine: Engine, _ name: String, _ args: [(String, JS)]) throws
    -> JSONNode
  {
    let result = try JSONNode.parse(engine.call("pitch." + name, json: JS.object(args).ascii))
    guard let value = result["value"] else { throw PitchError("engine-result") }
    return value
  }

  private var carriesJS: JS { .array(engines.carried.map(JS.string)) }

  /// The engine the lobby's options are read and set on: the room's engine counting
  /// this member, when this build carries it, else the newest. A room whose next match
  /// is on 0.8 offers 0.8's options, so nothing is offered that its match would not take.
  public func lobbyEngine() -> Engine {
    guard let mm = try? roomEngine(counting: true)["engine"]?.string, engines.carries(mm),
      let e = try? engines.engine(mm)
    else { return engines.newest }
    return e
  }

  /// Every match option the room holds, defaults filled in, on the lobby's engine:
  /// `pitch.optionsOf` (since 0.9: `options`' five and the engine's own from the
  /// document's `settings`, kubb-engine docs/ROOM.md difference 9), or on an older
  /// engine, which has no such call, `lobbyOf`'s `options`.
  public func roomOptions(_ doc: JSONText) throws -> [String: String] {
    let on = lobbyEngine()
    let all =
      try (try? Self.pitchCall(on, "optionsOf", [("doc", .raw(doc))]))
      ?? Self.pitchCall(on, "lobbyOf", [("doc", .raw(doc))])["options"]
    return Dictionary(
      uniqueKeysWithValues: (all?.members ?? []).compactMap { k, v in v.string.map { (k, $0) } })
  }

  /// The options the host may set (`MATCH_OPTIONS` of the lobby's engine) as raw JSON
  /// rows `[id, label, [[value, label]]]`.
  public func optionRows() throws -> JSONNode {
    let rows = try Self.pitchCall(lobbyEngine(), "constants", [])["MATCH_OPTIONS"]
    return try rows ?? JSONNode.parse("[]")
  }

  /// The lobby's card for `scene` (the lobby engine's `optionRows`, since 0.14): the Scene
  /// row first, a Surface row only where the scene leaves one, no Kubbs row while no scene
  /// allows two sets, `{ scene, rows, defaults }`. An engine before 0.14 has no such call:
  /// nil, and the caller walks `optionRows()`.
  public func optionRows(scene: String) -> JSONNode? {
    guard let card = try? Self.pitchCall(lobbyEngine(), "optionRows", [("scene", .string(scene))]),
      card["rows"] != nil
    else { return nil }
    return card
  }

  /// The lobby's engine takes a scene (`scene` in its OPTION_DEFAULTS, since 0.9): the
  /// host may pick one, written to the room's `settings.scene`. On 0.8 or 0.7 none is
  /// offered and the pitch is drawn as the day.
  public func lobbyTakesScene() -> Bool {
    (try? Self.pitchCall(lobbyEngine(), "constants", [])["OPTION_DEFAULTS"]?["scene"]) != nil
  }

  /// A new pitch this member hosts (version 0, no document yet): its lobby, and in it
  /// the options the host last picked in a lobby (the web's `pitchOptions`, set on a new
  /// pitch in its pitch.js `onReady`). Only what the lobby's engine takes goes in
  /// (`takenOptions`): a key in its `MATCH_OPTIONS` with one of its values, and `scene`
  /// where it takes a scene. Never a pitch someone else hosts or one that already has a
  /// document. False when it was not this member's to make.
  @discardableResult public func prepareLobby(options kept: [String: String]) async throws -> Bool {
    guard !observing else { return false }
    return try await pitch.update { [self] doc in
      guard doc == .null, pitch.isHost else { return nil }
      let lobby = try pitchCall("lobbyOf", [("doc", .raw(doc))])
      let taken = try takenOptions(kept)
      guard !taken.isEmpty else { return lobby.raw }
      let set = try Self.pitchCall(
        lobbyEngine(), "setOptions",
        [
          ("doc", .raw(lobby.raw)),
          ("options", .object(taken.sorted { $0.key < $1.key }.map { ($0.key, JS.string($0.value)) })),
        ])
      return set.isNull ? lobby.raw : set.raw
    } != nil
  }

  /// The kept options the lobby's engine takes: each `MATCH_OPTIONS` key with one of
  /// its own values (Computer only from 0.9), and `scene` only where the engine takes
  /// a scene (the client checks the id is one it offers). Anything else is dropped.
  public func takenOptions(_ kept: [String: String]) throws -> [String: String] {
    var taken = [String: String]()
    for row in try optionRows().items {
      let fields = row.items
      guard fields.count >= 3, let key = fields[0].string, let v = kept[key],
        fields[2].items.contains(where: { $0.items.first?.string == v })
      else { continue }
      taken[key] = v
    }
    if let scene = kept["scene"], lobbyTakesScene() { taken["scene"] = scene }
    return taken
  }

  /// The room's engine (`pitch.engineFor`): the newest major.minor the host and every
  /// player carry, `{ engine | null, missing, unknown }`. With `counting` this member
  /// is counted too, carrying what this build carries.
  public func roomEngine(counting: Bool = false) throws -> JSONNode {
    var args: [(String, JS)] = [
      ("doc", .raw(pitch.document)), ("members", pitch.membersJSON),
      ("host", pitch.host.map(JS.string) ?? .null),
    ]
    if counting { args += [("me", .string(pitch.you)), ("carries", carriesJS)] }
    return try newestCall("engineFor", args)
  }

  /// What a member carries, from its presence (`pitch.carried`), newest first.
  public func carried(by id: String?) throws -> [String] {
    let me = pitch.members.first { $0["id"]?.string == id }?["me"]?.raw ?? .null
    return try newestCall("carried", [("me", .raw(me))]).items.compactMap(\.string)
  }

  /// Speak down (kubb-engine docs/ROOM.md "Speaking down"): announce every engine this
  /// build carries, with `engine` the room's engine counting this member, marked
  /// `+engines`, so a client that carries one sees a match. Sent again only when it
  /// changes; before the room is known it is the newest.
  public func announce() throws {
    let mm = try roomEngine(counting: true)["engine"]
    let fields = try newestCall("announce", [("carries", carriesJS), ("engine", .raw(mm?.raw ?? .null))])
    guard fields.kind == .object, fields.raw != announced else { return }
    announced = fields.raw
    pitch.setMe(fields.members.map { ($0.key, JS.raw($0.value.raw)) })
  }
  private func call(_ name: String, _ args: JS? = nil) throws -> JSONNode {
    try JSONNode.parse(engine.call(name, json: args?.ascii ?? ""))
  }
  /// This member's presence: its name, a generated one (the device's), sent as it is;
  /// anything else is never sent (the pitch server would drop it). No level: a person
  /// throws on one meter (engine 0.13), and the lineup takes "club" for a member that
  /// names none.
  public func setMe(name: String) throws {
    if names.valid(.player, name).ok { pitch.setMe([("name", .string(name))]) }
    try announce()
  }

  @discardableResult public func reduce(_ name: String, fields: [(String, JS)] = []) async throws
    -> Bool
  {
    // An observer writes nothing to the document.
    if observing { throw PitchError("observer") }
    // Only these host reducers are exposed; seat and sync decisions remain in Lua. The
    // computer seats' four (engine 0.17, docs/PITCH.md "Computer seats") are the host's.
    let hostOnly = Self.seatReducers + ["setOptions", "setAccess", "pruneTeams", "backToLobby"]
    if hostOnly.contains(name), !pitch.isHost { throw PitchError("not-host") }
    guard (hostOnly + ["joinTeam"]).contains(name) else {
      throw PitchError("bad-reducer")
    }
    return try await pitch.update { [self] doc in
      if hostOnly.contains(name), !pitch.isHost { return nil }
      var args = fields.filter { $0.0 != "doc" && $0.0 != "id" }
      if name == "joinTeam" { args.append(("id", .string(pitch.you))) }
      // a seat reducer's `id` is the seat's, never a member's (engine 0.17)
      if Self.seatReducers.contains(name) { args = args.map { $0.0 == "seat" ? ("id", $0.1) : $0 } }
      // options are set on the engine they are offered from (`lobbyEngine`)
      let on = name == "setOptions" ? lobbyEngine() : engine
      let value = try Self.pitchCall(on, name, [("doc", .raw(doc))] + args)
      return value.isNull ? nil : value.raw
    } != nil
  }
  public func joinTeam(_ side: String?) async throws {
    _ = try await reduce("joinTeam", fields: [("side", side.map(JS.string) ?? .null)])
  }

  // MARK: - Computer seats (engine 0.17, docs/PITCH.md "Computer seats"; the web's pitch.js)

  /// The host's seat reducers: a seat added, re-levelled, moved or removed is a document
  /// write like a team change, through the engine's own reducer, which decides every rule
  /// (the host's only, while no match runs, six a team, a level a seat may have).
  static let seatReducers = ["addComputer", "setComputerLevel", "moveComputer", "removeComputer"]

  /// Is `id` a computer seat's id (`pitch.isSeat`)? Never a member's.
  public func isSeat(_ id: String?) -> Bool {
    guard let id else { return false }
    if let v = seatIds[id] { return v }
    let v = (try? pitchCall("isSeat", [("id", .string(id))]))?.bool == true
    seatIds[id] = v
    return v
  }
  private var seatIds: [String: Bool] = [:]

  /// The host adds a computer player last in `side`'s throwing order at `level`, named
  /// with a generated player name nobody on the pitch has, from this device's own draw
  /// (the engine rolls one from `seed` should none be found). The new seat's id, or nil
  /// when the engine refused it (a full side, a match running, not the host).
  @discardableResult public func addComputer(side: String, level: String = "club") async throws -> String? {
    guard !observing, pitch.isHost else { return nil }
    let seed = Int.random(in: 0..<2_147_483_648)
    var added: String?
    let landed =
      try await pitch.update { [self] doc in
        added = nil
        guard pitch.isHost else { return nil }
        var args: [(String, JS)] = [
          ("doc", .raw(doc)), ("side", .string(side)), ("level", .string(level)), ("seed", .int(seed)),
        ]
        if let name = freshSeatName(doc) { args.append(("name", .string(name))) }
        let before = Set(Self.computers(of: try pitchCall("lobbyOf", [("doc", .raw(doc))])).keys)
        let value = try pitchCall("addComputer", args)
        if value.isNull { return nil }
        added = Self.computers(of: try pitchCall("lobbyOf", [("doc", .raw(value.raw))])).keys.first {
          !before.contains($0)
        }
        return value.raw
      } != nil
    return landed ? added : nil
  }
  /// A seat's level (`setComputerLevel`). False when nothing changed.
  @discardableResult public func setComputerLevel(_ id: String, _ level: String) async throws -> Bool {
    try await reduce("setComputerLevel", fields: [("seat", .string(id)), ("level", .string(level))])
  }
  /// A seat to `side` at place `index` in its order (nil: last), the same side reorders
  /// (`moveComputer`). False when it did not move.
  @discardableResult public func moveComputer(_ id: String, side: String, index: Int?) async throws -> Bool {
    try await reduce(
      "moveComputer", fields: [("seat", .string(id)), ("side", .string(side)), ("index", index.map(JS.int) ?? .null)])
  }
  /// A seat off its team (`removeComputer`).
  @discardableResult public func removeComputer(_ id: String) async throws -> Bool {
    try await reduce("removeComputer", fields: [("seat", .string(id))])
  }

  /// A lobby's `computers` (`lobbyOf`'s: only seats with a good record on one team), by
  /// seat id: its level and its name as kept.
  public static func computers(of lobby: JSONNode) -> [String: (level: String, name: String?)] {
    var out: [String: (level: String, name: String?)] = [:]
    for (id, r) in lobby["computers"]?.members ?? [] {
      out[id] = (r["level"]?.string ?? "club", r["name"]?.string)
    }
    return out
  }

  /// A seat's name as the lobby shows it: the document's when the engine passes it
  /// (`names.check`'s `computers.<id>.name`), else "Computer" (the web's seatName).
  public func seatName(_ id: String) -> String {
    let n = (try? JSONNode.parse(pitch.document))?["computers"]?[id]?["name"]?.string
    guard let n, !n.isEmpty, !lobbyCheck().refusedFrom.contains("computers.\(id).name") else {
      return Names.computer
    }
    return n
  }

  /// A generated player name nobody on the pitch has (no member, no other seat, not this
  /// device), or nil after twenty tries (the web's freshSeatName).
  private func freshSeatName(_ doc: JSONText) -> String? {
    let lobby = try? pitchCall("lobbyOf", [("doc", .raw(doc))])
    var taken = Set(shownNames().plain.values)
    if let lobby { for (_, c) in Self.computers(of: lobby) { if let n = c.name { taken.insert(n) } } }
    if let mine = pitch.members.first(where: { $0["id"]?.string == pitch.you })?["me"]?["name"]?.string {
      taken.insert(mine)
    }
    for _ in 0..<20 {
      guard let t = (try? names.roll(.player))??.text else { return nil }
      if !taken.contains(t) { return t }
    }
    return nil
  }

  /// Why START was refused for the lineup itself (`startCheck`'s `text`, engine 0.17: no
  /// person plays, a team over six, a seat's level), the engine's own sentence; nil when
  /// it was not, or the refusal was the engines'.
  public private(set) var startRefusal: String?

  /// START: a fresh match built on the lobby as this member holds it, sent as one
  /// `start` (the lobby write and the match's first snapshot together). Tried again on
  /// the newer lobby when someone wrote first. Strict version checks: no unknown or
  /// different player engine starts.
  @discardableResult public func start(seed: Int, at: JSONText) async throws -> Bool {
    guard !observing, pitch.isHost, state == .lobby || (state == .versionMismatch && head == nil),
      !starting
    else { return false }
    startRefusal = nil
    starting = true
    defer { starting = false }
    for _ in 0...3 {  // the web's start: the first try and at most three more
      try await pitch.ready()
      guard pitch.isHost else { return false }
      let base = pitch.version
      guard let built = try build(doc: pitch.document, seed: seed, at: at) else { return false }
      let landed: Bool
      do {
        landed = try await pitch.start(
          base: base, doc: built.doc, n: built.n, h: built.hash, snap: built.snap, meta: built.meta)
      } catch let error as PitchError where error.code == "uncertain" {
        // the next join's match says whether it started; it is adopted either way
        return false
      }
      if landed {
        try begin(
          n: built.n, seq: 0, h: built.hash, over: false, meta: JSONNode.parse(built.meta),
          h0: built.hash, snap: built.snap, show: true)
        return true
      }
    }
    return false
  }

  private struct Built {
    let doc: JSONText
    let n: Int
    let hash: String
    let snap: String
    let meta: JSONText
  }
  /// The START for this lobby: the lobby document after it (without the match), the
  /// match number, and the engine's first hash, snapshot and start info. Nil when the
  /// lineup cannot start (then `mismatch` says why, when it is the engines).
  private func build(doc: JSONText, seed: Int, at: JSONText) throws -> Built? {
    // every name the match takes passes the check first, so an honest host never starts
    // a match the pitch server would refuse `bad-name` (docs/ONLINE.md "Names")
    let raw = try pitchCall("lineup", [("doc", .raw(doc)), ("members", pitch.membersJSON)])
    if raw.isNull { return nil }
    let lineup = try JSONNode.parse(checkedLineup(raw).ascii)
    let players = lineup["players"]!.raw
    // The pitch's engine now, from this document and presence: the newest that the host
    // and every player carry.
    let chosen = try newestCall(
      "engineFor",
      [
        ("doc", .raw(doc)), ("members", pitch.membersJSON), ("host", .string(pitch.you)),
        ("me", .string(pitch.you)), ("carries", carriesJS),
      ])
    guard let mm = chosen["engine"]?.string, engines.carries(mm) else {
      let unknown = chosen["unknown"]?.items ?? []
      let differ = (chosen["missing"]?.items ?? []).filter { id in
        !unknown.contains { $0.raw == id.raw }
      }
      mismatch = JS.object([
        ("ok", .bool(false)), ("engine", .null),
        ("differ", .array(differ.map { .raw($0.raw) })),
        ("unknown", .array(unknown.map { .raw($0.raw) })),
      ]).json
      state = .versionMismatch
      return nil
    }
    // START on that engine's own calls, with every member that carries it speaking as
    // it (a new announcement may still be on its way).
    let on = try engines.engine(mm)
    if on !== engine {
      engine = on
      control = .null
    }
    let members = try newestCall("speakAs", [("members", pitch.membersJSON), ("engine", .string(mm))]).raw
    let check = try pitchCall(
      "startCheck", [("players", .raw(players)), ("members", .raw(members)), ("host", .string(pitch.you))])
    // the lineup itself refused (engine 0.17: `why` and `text`): the engine's sentence,
    // and the lobby stays as it is
    if check["ok"]?.bool != true, check["why"] != nil, let text = check["text"]?.string {
      startRefusal = text
      return nil
    }
    guard check["ok"]?.bool == true else {
      mismatch = check.raw
      state = .versionMismatch
      return nil
    }
    let opts = try JSONNode.parse(
      teamNamed(
        pitchCall(
          "matchOptions",
          [("doc", .raw(doc)), ("lineup", .raw(lineup.raw)), ("seed", .int(seed)), ("start", .raw(at))]),
        lineup: lineup, doc: doc
      ).ascii)
    let args = JS.object(opts.members.map { ($0.key, JS.raw($0.value.raw)) } + [("mode", .string("match"))])
    _ = try call("new", args)
    let snap = try engine.call("snapshot")
    let hash = try engine.hash()
    // The match number is the pitch's next, whatever the lobby counted.
    let lobby = try pitchCall("lobbyOf", [("doc", .raw(doc))])
    let counted = max(lobby["n"]?.int ?? 0, lastN)
    let value = try pitchCall(
      "startMatch",
      [
        ("doc", .raw(Self.with(lobby, [("n", .int(counted))]).json)), ("snap", .string(snap)),
        ("hash", .string(hash)), ("players", .raw(players)),
        ("cpu", .raw(lineup["cpu"]?.raw ?? .null)), ("host", .string(pitch.you)),
        ("setup", .raw(opts.raw)), ("members", .raw(members)),
      ])
    guard !value.isNull, let m = value["match"], let n = m["n"]?.int else { return nil }
    return Built(
      doc: Self.with(value, [("match", Self.header(of: m))]).json, n: n, hash: hash, snap: snap,
      meta: Self.meta(of: m, version: engine.engineVersion).json)
  }

  // MARK: - Names (docs/ONLINE.md "Names"; the web's pitch.js)

  /// The lineup with every name checked: a player's presence name that is not a
  /// generated name or a default becomes "Player n" (n their place on the side, as the
  /// engine's lineup numbers a player with no name). The web's checkedLineup.
  func checkedLineup(_ lu: JSONNode) -> JS {
    var sides: [(String, JS)] = []
    for side in ["A", "B"] {
      let list = (lu["players"]?[side]?.items ?? []).enumerated().map { k, p -> JS in
        names.passes(.player, p["name"]?.string)
          ? .raw(p.raw) : Self.with(p, [("name", .string(Names.playerDefault(k + 1)))])
      }
      sides.append((side, .array(list)))
    }
    return Self.replacing(lu, [("players", .object(sides))])
  }

  /// A match's options with its team names: a side of several plays under the team name
  /// the host picked in the lobby (the document's `teamNames`), or one rolled now; a side
  /// of one under its player's name (the engine's matchOptions); the computer's as it is.
  func teamNamed(_ opts: JSONNode, lineup: JSONNode, doc: JSONText) throws -> JS {
    guard let teams = opts["teams"], teams.kind == .object else { return .raw(opts.raw) }
    let picked = try? JSONNode.parse(doc)["teamNames"]
    var out: [(String, JS)] = []
    for (side, t) in teams.members {
      let several = (lineup["players"]?[side]?.items.count ?? 0) > 1
      guard several, lineup["cpu"]?.string != side else {
        out.append((side, .raw(t.raw)))
        continue
      }
      let p = picked?[side]?.string
      let name = names.valid(.team, p).ok ? p! : (try names.roll(.team))?.text ?? Names.teamDefault(side)
      out.append((side, Self.replacing(t, [("name", .string(name))])))
    }
    return Self.replacing(opts, [("teams", .object(out))])
  }

  /// The engine's judgement of the lobby (`names.check` of the document and members:
  /// the host's `teamNames`, the match header's players, every member's name), kept
  /// while both are the same.
  private func lobbyCheck() -> Names.MatchCheck {
    let members = pitch.membersJSON.json
    if let c = checked, c.doc == pitch.document, c.members == members { return c.check }
    let check = names.check(document: pitch.document, members: members)
    checked = (pitch.document, members, check)
    return check
  }
  private var checked: (doc: JSONText, members: JSONText, check: Names.MatchCheck)?

  /// Every member's name as shown, by id: its presence name unless the engine refuses it
  /// (`names.check` of the lobby), else "Player n" (n its place on its side; a watcher,
  /// its place on the pitch); a player of the match who has left, the match's own name for
  /// them, checked. `apart` adds "II" to the second of two members with one name, for
  /// the lobby.
  public func shownNames() -> (plain: [String: String], apart: [String: String]) {
    let lobby = try? pitchCall("lobbyOf", [("doc", .raw(pitch.document))])
    let refused = lobbyCheck().refusedFrom
    func place(_ id: String, _ i: Int) -> Int {
      for side in ["A", "B"] {
        if let k = lobby?["teams"]?[side]?.items.firstIndex(where: { $0.string == id }) { return k + 1 }
      }
      return i + 1
    }
    var order: [(id: String, name: String)] = []
    for (i, m) in pitch.members.enumerated() {
      guard let id = m["id"]?.string else { continue }
      let n = m["me"]?["name"]?.string
      let shown = n?.isEmpty == false && !refused.contains("members[\(i)].me.name")
      order.append((id, shown ? n! : Names.playerDefault(place(id, i))))
    }
    for side in ["A", "B"] {
      for (k, p) in (match?["players"]?[side]?.items ?? []).enumerated() {
        guard let id = p["id"]?.string, !order.contains(where: { $0.id == id }) else { continue }
        order.append((id, names.shown(.player, p["name"]?.string, fallback: Names.playerDefault(k + 1))))
      }
    }
    return (Dictionary(order.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }), Names.apart(order))
  }

  /// A member's name as shown (never the text that failed).
  public func nameOf(_ id: String?) -> String {
    guard let id else { return "" }
    return shownNames().plain[id] ?? "Someone"
  }

  /// A side's team name as the lobby shows it: the document's unless the engine refuses
  /// it, else "Team A" / "Team B".
  public func teamNameOf(_ side: String) -> String {
    let t = (try? JSONNode.parse(pitch.document))?["teamNames"]?[side]?.string
    guard let t, !t.isEmpty, !lobbyCheck().refusedFrom.contains("teamNames.\(side)") else {
      return Names.teamDefault(side)
    }
    return t
  }

  /// The host picks a side's team name (a generated team name only), written into the
  /// document's own top-level `teamNames` (`{ A?, B? }`, the web's setTeamName: the
  /// engine's reducers keep a key they do not know).
  @discardableResult public func setTeamName(_ side: String, _ text: String) async throws -> Bool {
    guard !observing, pitch.isHost, side == "A" || side == "B", names.valid(.team, text).ok else { return false }
    return try await pitch.update { doc in
      guard let d = try? JSONNode.parse(doc), d.kind == .object else { return nil }
      if d["teamNames"]?[side]?.string == text { return nil }
      var fields = (d["teamNames"]?.members ?? []).filter { $0.key != side }.map { ($0.key, JS.raw($0.value.raw)) }
      fields.append((side, .string(text)))
      return Self.replacing(d, [("teamNames", .object(fields))]).json
    } != nil
  }

  /// The host, in the lobby: a side of several with no team name gets one rolled, once,
  /// so everyone sees what it will play as (the web's rollTeamNames). The side's name
  /// when one was written.
  @discardableResult public func rollTeamNames() async throws -> String? {
    guard !observing, pitch.isHost, state == .lobby || state == .versionMismatch, pitch.status == .open,
      !rollingTeam, teamRolls < 3
    else { return nil }
    let lobby = try pitchCall("lobbyOf", [("doc", .raw(pitch.document))])
    let ids = Set(pitch.members.compactMap { $0["id"]?.string })
    let picked = (try? JSONNode.parse(pitch.document))?["teamNames"]
    for side in ["A", "B"] {
      // people and computer seats together (the web's rollTeamNames)
      let several = (lobby["teams"]?[side]?.items ?? []).filter {
        ids.contains($0.string ?? "") || isSeat($0.string)
      }.count > 1
      guard several, !names.valid(.team, picked?[side]?.string).ok, let text = try names.roll(.team)?.text else { continue }
      rollingTeam = true
      teamRolls += 1
      defer { rollingTeam = false }
      if try await setTeamName(side, text) {
        teamRolls = 0
        return text
      }
      return nil
    }
    return nil
  }
  private var rollingTeam = false
  private var teamRolls = 0

  /// `node` (an object) with `fields` set: a key it has keeps its place, a new one goes
  /// last (as JavaScript's `{ ...node, key }` writes it).
  static func replacing(_ node: JSONNode, _ fields: [(String, JS)]) -> JS {
    var out: [(String, JS)] = node.members.map { m in
      (m.key, fields.first { $0.0 == m.key }?.1 ?? .raw(m.value.raw))
    }
    for f in fields where !node.members.contains(where: { $0.key == f.0 }) { out.append(f) }
    return .object(out)
  }

  /// The match's header, all the document keeps of it (the web's pitch.js `start`):
  /// `{ n, players, cpu, host, engine }`, engine as major.minor. The snapshot, the hash
  /// and `meta` go beside it in the `start` (PROTOCOL.md), never in the document.
  public static func header(of match: JSONNode) -> JS {
    .object([
      ("n", match["n"].map { .raw($0.raw) } ?? .null),
      ("players", match["players"].map { .raw($0.raw) } ?? .null),
      ("cpu", match["cpu"].map { .raw($0.raw) } ?? .null),
      ("host", match["host"].map { .raw($0.raw) } ?? .null),
      ("engine", Engine.majorMinor(match["engine"]?.string).map(JS.string) ?? .null),
    ])
  }

  /// The start info a replay needs besides the log, sent once as `start`'s `meta`, as the
  /// web's pitch.js writes it: `{ v: 1, setup, engine, version, players, cpu }`, `engine`
  /// the match's major.minor (what picks the engine to replay it on) and `version` the
  /// full engine version it was started on; the computer's level is inside `setup`. No
  /// host: the pitch decides that. The pitch server's kept replay is this with `n`, `h0`,
  /// the log, the final `hash` and `snap`.
  public static func meta(of match: JSONNode, version: String) -> JS {
    .object([
      ("v", .int(1)),
      ("setup", match["setup"].map { .raw($0.raw) } ?? .null),
      ("engine", Engine.majorMinor(match["engine"]?.string).map(JS.string) ?? .null),
      ("version", .string(version)),
      ("players", match["players"].map { .raw($0.raw) } ?? .null),
      ("cpu", match["cpu"].map { .raw($0.raw) } ?? .null),
    ])
  }
  static func with(_ node: JSONNode, _ fields: [(String, JS)]) -> JS {
    let keys = Set(fields.map(\.0))
    return .object(node.members.filter { !keys.contains($0.key) }.map { ($0.key, JS.raw($0.value.raw)) } + fields)
  }
  static func without(_ node: JSONNode, _ keys: Set<String>) -> JS {
    .object(node.members.filter { !keys.contains($0.key) }.map { ($0.key, JS.raw($0.value.raw)) })
  }

  /// The match for the engine's room calls at this member's state now.
  private func composite(snap: String?, seq: Int, hash: String, over: Bool) -> JSONNode? {
    guard let meta, let head else { return nil }
    var fields: [(String, JS)] = meta.members.filter { !["v", "version", "host"].contains($0.key) }
      .map { ($0.key, JS.raw($0.value.raw)) }
    // the host from the document's header (who started it), else the pitch's host now
    let docHost = (try? JSONNode.parse(pitch.document))?["match"]?["host"]?.string
    fields.append(("host", .string(docHost ?? meta["host"]?.string ?? pitch.host ?? pitch.you)))
    fields += [
      ("n", .int(head.n)), ("seq", .int(seq)), ("snap", snap.map(JS.string) ?? .null),
      ("hash", .string(hash)), ("h0", h0.map(JS.string) ?? .null),
    ]
    if over { fields.append(("over", .bool(true))) }
    return try? JSONNode.parse(JS.object(fields).json)
  }
  /// `match` again, from the engine now (or the head's snapshot when this build cannot
  /// play the match).
  private func remake() throws {
    guard let head else {
      match = nil
      return
    }
    if state == .versionMismatch {
      match = composite(snap: headSnap, seq: head.seq, hash: head.h, over: head.over)
      return
    }
    let last = outstanding.last
    match = composite(
      snap: try engine.call("snapshot"), seq: sequence, hash: last?.h ?? head.h,
      over: last?.over ?? head.over)
  }

  private func context() -> JS {
    .object([
      ("players", .raw(match?["players"]?.raw ?? JSONText(#"{"A":[],"B":[]}"#))),
      ("cpu", .raw(match?["cpu"]?.raw ?? .null)),
      ("host", pitch.host.map(JS.string) ?? .null),
      (
        "connected",
        .array(
          pitch.members.filter { $0["connected"]?.bool == true }.compactMap { $0["id"]?.string }.map(
            JS.string))
      ),
    ])
  }
  public var playingSide: String? {
    try? pitchCall("playingSide", [("ctx", context()), ("me", .string(pitch.you))]).string
  }
  public var actorDescription: String {
    guard let n = try? JSONNode.parse(need),
      let actor = try? pitchCall("shownActor", [("need", .raw(need)), ("ctx", context())]).string
    else { return "" }
    if actor == "cpu" {
      // a computer player in a team (engine 0.17): its name, generated by the match
      let th = n["setup"]?["thrower"]
      if th?["cpu"]?.bool == true, let name = th?["name"]?.string, !name.isEmpty { return "\(name) throws" }
      return "Computer throws"
    }
    if mayAct {
      switch n["kind"]?.string {
      case "raise": return "Your raise"
      case "punish": return "Place your kubb"
      default: return "Your throw"
      }
    }
    let verb =
      n["kind"]?.string == "raise"
      ? "raises" : n["kind"]?.string == "punish" ? "places a kubb" : "throws"
    return "\(nameOf(actor)) \(verb)"
  }

  private func refreshSeat() throws {
    guard state == .match else {
      mayAct = false
      return
    }
    let ctx = context()
    // an observer's seat has no side and no computer, whatever the room says
    let next =
      observing
      ? try JSONNode.parse(Self.noSeat)
      : try pitchCall("controlFor", [("ctx", ctx), ("me", .string(pitch.you))])
    let same = try pitchCall("sameControl", [("a", .raw(control)), ("b", .raw(next.raw))])
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
      try !observing
      && pitchCall("mayAct", [("need", .raw(need)), ("ctx", ctx), ("me", .string(pitch.you))]).bool
        == true
  }

  private func receive(_ event: PitchClient.Event) {
    defer { didReceive?(event) }
    do {
      switch event {
      case .document(_, let doc, _):
        if try !Self.started(doc) { toLobby() }
        try announce()
      case .state:
        try adoptJoin()
        try refreshSeat()
        try announce()
      case .members, .host:
        try announce()
        try refreshSeat()
        if state == .versionMismatch, head == nil, try !Self.started(pitch.document) {
          state = .lobby
          mismatch = nil
        }
      case .left:
        if pitch.isHost, !observing, state == .lobby {
          let present = JS.array(pitch.members.compactMap { $0["id"]?.string }.map(JS.string))
          Task { [weak self] in
            do { _ = try await self?.reduce("pruneTeams", fields: [("present", present)]) } catch {
              self?.lastError = String(describing: error)
            }
          }
        }
      case .message(let msg):
        switch msg["t"]?.string {
        case "start": try started(msg)
        case "act": try remote(msg)
        case "ok": if msg["re"]?.string == "act", let id = msg["id"]?.string { try acknowledged(id) }
        case "refused": if let id = msg["id"]?.string { try refused(id, why: msg["why"]?.string) }
        case "error":
          // an action the pitch would not take (too big): put this member back to the head
          if msg["re"]?.string == "act", let id = msg["id"]?.string { try refused(id, why: msg["code"]?.string) }
        case "cast":
          lastCast = msg.raw
          if present == nil, !mayAct, msg["d"]?["t"]?.string == "aim", state == .match,
            let aim = msg["d"]?["s"]
          {
            _ = try engine.call("showAim", json: aim.raw.text)
          }
        default: break
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

  static func started(_ doc: JSONText) throws -> Bool {
    try JSONNode.parse(doc)["started"]?.bool == true
  }

  private func toLobby() {
    guard state != .lobby || head != nil else { return }
    state = .lobby
    match = nil
    meta = nil
    head = nil
    headSnap = nil
    h0 = nil
    outstanding.removeAll()
    pitch.dropActs()
    mayAct = false
    control = .null
    mismatch = nil
    awaitingState = false
  }

  /// A match from its start (`start`, a whole `match` in a join): this member's engine
  /// put on it, its own outstanding actions dropped.
  private func begin(
    n: Int, seq: Int, h: String, over: Bool, meta m: JSONNode, h0 first: String?, snap: String,
    show: Bool
  ) throws {
    lastN = max(lastN, n)
    meta = m
    h0 = first
    head = (n, seq, h, over)
    headSnap = snap
    outstanding.removeAll()
    pitch.dropActs()
    awaitingState = false
    control = .null
    lastAim = nil
    // A match plays only on its own engine (kubb-engine docs/ROOM.md "Engines in one
    // match"): this build's engine of that major.minor when it carries one, checked by
    // that engine's own mayPlay; else the engine it has, which refuses it.
    let theirs = m["engine"]?.string
    let on = engines.carries(theirs) ? try engines.engine(Engine.majorMinor(theirs)!) : engine
    let probe = composite(snap: snap, seq: seq, hash: h, over: over)
    let check = try Self.pitchCall(
      on, "mayPlay", [("engine", .string(on.engineVersion)), ("match", .raw(probe?.raw ?? .null))])
    guard check["ok"]?.bool == true else {
      state = .versionMismatch
      mismatch = check.raw
      mayAct = false
      match = probe
      if show, let probe { try present?(.restore(probe)) }
      return
    }
    // A match holding a name or a line the game did not make (a forged start: the pitch
    // server cannot see inside the snapshot) is not shown or played. The engine judges
    // the whole snapshot (`names.check`), and it is adopted only through `restore`'s
    // strict door, which refuses it before anything changes. Its snapshot is hashed, so
    // its names cannot be put right here.
    func refuse() {
      state = .namesRefused
      mismatch = nil
      mayAct = false
      match = probe
    }
    guard names.check(snap: snap).allowed else { return refuse() }
    do {
      _ = try on.call("restore", json: Names.checkedRestore(snap))
    } catch EngineError.call(_, let message) where message.contains("names not allowed") {
      return refuse()
    }
    engine = on
    state = .match
    mismatch = nil
    match = probe
    try refreshSeat()
    if show, let probe { try present?(.restore(probe)) }
  }

  /// `start` from the host: the next match, from its first snapshot.
  private func started(_ msg: JSONNode) throws {
    guard let n = msg["n"]?.int, let h = Self.hashOf(msg["h"]), let snap = msg["snap"]?.string,
      let m = msg["meta"], m.kind == .object
    else { return }
    try begin(n: n, seq: 0, h: h, over: false, meta: m, h0: h, snap: snap, show: true)
  }

  static func hashOf(_ node: JSONNode?) -> String? {
    guard let node, !node.isNull else { return nil }
    return node.string ?? node.raw.text
  }

  /// A peer's action (or one of this member's own in a resume, by its id).
  private func remote(_ f: JSONNode) throws {
    guard let n = f["n"]?.int, let seq = f["seq"]?.int, let a = f["a"], let h = Self.hashOf(f["h"])
    else { return }
    remoteTs = f["ts"]?.int
    guard !awaitingState else { return }
    guard let current = head, n == current.n else {
      resync()
      return
    }
    if seq <= current.seq { return }
    guard seq == current.seq + 1 else {
      resync()
      return
    }
    let over = f["over"]?.bool == true
    if let first = outstanding.first {
      if first.id == f["id"]?.string {
        try confirm()
        return
      }
      // Two at once and the peer was first: this member's actions are dropped (the pitch
      // refuses them), the engine goes back to the head, and the peer's action is played.
      conflicts += 1
      try rollback()
    }
    if state == .versionMismatch {
      // A spectator that cannot play the match: the board tries it on the newest.
      head = (n, seq, h, over)
      try remake()
      if let match { try present?(.apply(action: a.raw, match: match)) }
      return
    }
    var agrees = false
    do {
      let out = try engine.call("apply", json: a.raw.text)
      agrees = try JSONNode.parse(out)["ok"]?.bool != false && engine.hash() == h
    } catch { agrees = false }
    guard agrees else {
      // This engine and the pitch disagree: ask for the whole pitch, and play nothing
      // until it comes.
      corrections += 1
      resync()
      return
    }
    applied += 1
    head = (n, seq, h, over)
    headSnap = try engine.call("snapshot")
    control = .null
    lastAim = nil
    try remake()
    try refreshSeat()
    if let match { try present?(.apply(action: a.raw, match: match)) }
  }

  /// The pitch stored this member's oldest outstanding action: it is the head now.
  private func confirm() throws {
    let p = outstanding.removeFirst()
    head = (p.n, p.seq, p.h, p.over)
    headSnap = p.snap
  }
  private func acknowledged(_ id: String) throws {
    guard outstanding.first?.id == id else { return }
    try confirm()
  }
  /// A refusal of one of this member's actions it has not already given up: back to
  /// the head, and the whole pitch asked for (the head it was refused with may be
  /// newer than any action this member has seen).
  private func refused(_ id: String, why: String?) throws {
    guard outstanding.contains(where: { $0.id == id }) else { return }
    try rollback()
    resync()
  }
  /// Back to the confirmed head: outstanding actions dropped, the board told.
  private func rollback() throws {
    outstanding.removeAll()
    pitch.dropActs()
    guard let headSnap, state == .match else { return }
    _ = try engine.call("restore", json: headSnap)
    control = .null
    try remake()
    try refreshSeat()
    if let match { try present?(.restore(match)) }
  }
  private func resync() {
    awaitingState = true
    mayAct = false
    pitch.resync()
  }

  /// The whole pitch (`joined` after each connect, `state` after a resync): the lobby,
  /// then the match, resumed from the actions missed or taken whole.
  private func adoptJoin() throws {
    guard let join = pitch.lastJoin else { return }
    awaitingState = false
    let m = join["match"]
    if let n = m?["n"]?.int { lastN = max(lastN, n) }
    guard try Self.started(pitch.document), let m, !m.isNull, let n = m["n"]?.int,
      let seq = m["seq"]?.int, let h = Self.hashOf(m["h"])
    else {
      toLobby()
      return
    }
    let over = m["over"]?.bool == true
    if m["full"]?.bool == false {
      // Resuming: exactly the actions missed (this member's own among them, by id).
      for act in m["acts"]?.items ?? [] {
        try remote(act)
        if awaitingState { return }
      }
      if let current = head, current.n == n, current.seq == seq, current.h != h {
        corrections += 1
        resync()
      }
      return
    }
    guard let meta = m["meta"], let snap = m["snap"]?.string else { return }
    if let current = head, current.n == n, self.meta != nil, state == .match {
      if let k = outstanding.firstIndex(where: { $0.seq == seq && $0.h == h }) {
        // the pitch has this member's actions up to k: they are the head now
        for _ in 0...k { try confirm() }
        return
      }
      if current.seq == seq && current.h == h {
        head?.over = over
        return
      }
    }
    adoptions += 1
    try begin(n: n, seq: seq, h: h, over: over, meta: meta, h0: Self.hashOf(m["h0"]), snap: snap, show: true)
  }

  /// Whether the match on the pitch is over and has start info a replay is made from:
  /// the pitch server keeps its replay (the web's winner card offers WATCH REPLAY, EMBED
  /// and a highlight reel only then). The reel card asks the API whether it is kept.
  public var finishedWithReplay: Bool { finishedReplay != nil }

  /// The finished match's identity (`n`, and its final hash), for the reel card to
  /// check the pitch's kept replay is of this match. Nil when there is none.
  public var finishedReplay: ReelMatch? {
    guard let head, head.over, outstanding.isEmpty, meta?["setup"].map({ $0.kind == .object }) == true
    else { return nil }
    return ReelMatch(n: head.n, hash: head.h)
  }

  /// Take a user action only in this member's seat. The engine validates the action.
  /// True once it is applied and sent; the pitch's answer is never waited for.
  @discardableResult public func take(_ action: JSONText, computer: Bool = false) async throws
    -> Bool
  {
    guard !observing, state == .match, pitch.status == .open, !starting, !awaitingState else {
      return false
    }
    try refreshSeat()
    let cpuThrow =
      try computer && (JSONNode.parse(need))["cpu"]?.bool == true
      && (JSONNode.parse(control))["cpu"]?.bool == true
      && (JSONNode.parse(action))["type"]?.string == "throw"
    guard mayAct || cpuThrow else { return false }
    let out = try call("apply", .raw(action))
    if out["ok"]?.bool == false { return false }
    try commit(action)
    return true
  }

  /// A frame can release a host-owned computer throw or this member's dial throw.
  /// No room bridge calls run per frame: `mayAct` and `control` are cached.
  public func frame(_ input: JSONText) async throws -> JSONText? {
    guard !observing, state == .match, pitch.status == .open, !starting, !awaitingState else {
      return nil
    }
    let n = try JSONNode.parse(need)
    let cpuControl = try JSONNode.parse(control)["cpu"]?.bool == true
    let cpu = n["cpu"]?.bool == true && cpuControl
    guard mayAct || cpu else { return nil }
    let aim = try engine.call("aimState").asJSON
    let out = try call("frame", .raw(input))
    if let action = out["action"] {
      // the throw's last aim reaches every watcher, past the thinning
      if mayAct { try castAim(aim, final: true) }
      try commit(action.raw)
    }
    return out.raw
  }

  /// One action this member made, already applied: kept outstanding and sent.
  private func commit(_ action: JSONText) throws {
    guard !observing, let n = matchNumber else { return }
    let seq = sequence + 1
    let snap = try engine.call("snapshot")
    let hash = try engine.hash()
    let over = try call("need")["kind"]?.string == "over"
    let id = PitchClient.randomID(12) + "-" + String(seq)
    outstanding.append(Outstanding(id: id, n: n, seq: seq, a: action, h: hash, snap: snap, over: over))
    pitch.act(id: id, n: n, seq: seq, a: action, h: hash, snap: snap, over: over)
    lastAim = nil
    try remake()
    try refreshSeat()
  }

  /// The clock: the seat kept fresh while nothing is on its way. The pitch decides the
  /// host itself (PROTOCOL.md section 4): there is no claim.
  public func tick(now: Int = Int(Date().timeIntervalSince1970 * 1000)) {
    guard pitch.status == .open else { return }
    do {
      if !starting { try refreshSeat() }
      onClock?(now)
    } catch { lastError = String(describing: error) }
  }

  /// This member's aim, cast while it changes, at most 15 a second (the web's aim.js
  /// AimSender): `{ t: "aim", s: <aimState>, k: <a count of this member's samples>,
  /// c: <this device's clock, ms> }`. `final`, the aim just before a release, goes at
  /// once and reaches every watcher past the thinning (`all`). A shout spends a slot.
  public func castAim(
    _ displayAim: JSONText? = nil, final: Bool = false,
    now: Int = Int(Date().timeIntervalSince1970 * 1000)
  ) throws {
    guard !observing, state == .match, mayAct, !starting else { return }
    guard final || now - lastAimAt >= Self.aimEvery - 1 else { return }
    let aim = try displayAim ?? engine.call("aimState").asJSON
    guard final || aim != lastAim else { return }
    aimCount += 1
    let d = JS.object([("t", .string("aim")), ("s", .raw(aim)), ("k", .int(aimCount)), ("c", .int(now))]).json
    if pitch.cast(d, all: final) {
      lastAim = aim
      lastAimAt = now
    }
  }
  @discardableResult public func shout(
    _ word: String, now: Int = Int(Date().timeIntervalSince1970 * 1000)
  ) -> Bool {
    guard !observing, ["NICE!", "OOH!", "TOK!", "UNLUCKY"].contains(word),
      lastShoutAt == nil || now - lastShoutAt! >= 700
    else { return false }
    if pitch.cast(JS.object([("t", .string("shout")), ("w", .string(word))]).json, all: true) {
      lastShoutAt = now
      lastAimAt = now  // a shout spends an aim slot: the two stay under the cast limit
      return true
    }
    return false
  }
}

extension String { fileprivate var asJSON: JSONText { JSONText(self) } }
