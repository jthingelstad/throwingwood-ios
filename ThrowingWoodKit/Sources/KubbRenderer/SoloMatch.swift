import Foundation
import KubbEngine
import KubbPitch

public struct MatchOption: Decodable, Identifiable, Sendable {
  public let id, label: String
  public let choices: [[String]]
  init(id: String, label: String, choices: [[String]]) {
    self.id = id
    self.label = label
    self.choices = choices
  }
  public init(from decoder: Decoder) throws {
    var row = try decoder.unkeyedContainer()
    id = try row.decode(String.self)
    label = try row.decode(String.self)
    choices = try row.decode([[String]].self)
  }
}

/// The options card for one scene (the engine's `pitch.optionRows({ scene })`, since
/// 0.14): the Scene row first with the engine's names, a Surface row only where the
/// scene leaves one (Black & White), no Kubbs row while no scene allows two sets, and
/// the scene's own surface and set (`defaults`) for a card that changes scene.
public struct SceneCard: Sendable {
  public let scene: String
  public let rows: [MatchOption]
  public let defaults: [String: String]
}

public struct SoloOptions {
  /// Every option the engine takes (`MATCH_OPTIONS`: the Scene row first since 0.14, and
  /// every surface and set it plays), as values a match may be started with.
  public let rows: [MatchOption], defaults: [String: String]
  public let nameLimit: Int
  /// The throw levels (`LEVELS`): the computer's, Kid first since 0.15. A person has
  /// none (engine 0.13).
  public let levels: [String]
  /// A person's throw levels (engine 1.3's `THROW_LEVELS`: easy, standard, hard); empty
  /// on an engine before it, which has one meter for everyone.
  public let throwLevels: [String]
  /// The engine takes the computer's level as a match option (`computer`, since 0.9).
  public let takesComputer: Bool
  /// The engine takes a scene (`scene` in OPTION_DEFAULTS, since 0.9): the Scene row shows.
  public let takesScene: Bool
  /// Each scene's card, from the engine (`pitch.optionRows`), by scene id.
  public let cards: [String: SceneCard]
  init(engine: Engine) throws {
    struct Constants: Decodable {
      let MATCH_OPTIONS: [MatchOption], LEVELS: [String], OPTION_DEFAULTS: [String: String],
        NAME_MAX: Int
      let THROW_LEVELS: [String]?
    }
    struct Reply<T: Decodable>: Decodable { let value: T }
    struct Card: Decodable {
      let scene: String, rows: [MatchOption], defaults: [String: String]
    }
    let c = try JSONDecoder().decode(Reply<Constants>.self, from: Data(engine.call("pitch.constants").utf8))
      .value
    levels = c.LEVELS
    takesComputer = c.MATCH_OPTIONS.contains { $0.id == "computer" }
    takesScene = SceneID.taken(by: c.OPTION_DEFAULTS)
    rows = c.MATCH_OPTIONS
    // the throw to go is on by default (the product's default; the engine's is off, so
    // its older matches and hashes stay as they were: kubb-engine docs/SESSION.md)
    defaults = c.OPTION_DEFAULTS.filter { d in c.MATCH_OPTIONS.contains { $0.id == d.key } }
      .merging(["computer": "club", "scene": "day"]) { old, _ in old }
      .merging(c.MATCH_OPTIONS.contains { $0.id == "togo" } ? ["togo": "on"] : [:]) { _, new in new }
    throwLevels = c.THROW_LEVELS ?? []
    nameLimit = c.NAME_MAX
    var cards = [String: SceneCard]()
    for scene in c.MATCH_OPTIONS.first(where: { $0.id == "scene" })?.choices.map({ $0[0] }) ?? [] {
      let card = try JSONDecoder().decode(
        Reply<Card>.self,
        from: Data(engine.call("pitch.optionRows", json: JS.object([("scene", .string(scene))]).ascii).utf8)
      ).value
      cards[scene] = SceneCard(scene: card.scene, rows: card.rows, defaults: card.defaults)
    }
    self.cards = cards
  }

  /// The card for `scene`; an id the engine does not list is Park's, as it reads it.
  public func card(_ scene: String?) -> SceneCard? {
    cards[scene ?? "day"] ?? cards["day"]
  }

  /// The order of the rows on an options card (the 1.0 design, direction A, scene first):
  /// Scene (its picture tiles), Surface right under it where the scene leaves one (it is
  /// part of the scene's choice), then Throw to go (engine 1.4.0, the engine's place for it,
  /// just before Computer), Computer, Opening, Raising and Wind. A row the engine adds that
  /// is not named here goes last; there is no Kubbs row while no scene allows two sets.
  /// Throw to go (engine 1.4.0) beside Opening, both say how the match begins; under
  /// Computer, so picking Kid (which takes it away) never moves the row being touched.
  public static let cardOrder = ["scene", "surface", "computer", "opening", "togo", "raising", "wind", "set"]
  public static func ordered(_ rows: [MatchOption]) -> [MatchOption] {
    rows.sorted { (cardOrder.firstIndex(of: $0.id) ?? 99) < (cardOrder.firstIndex(of: $1.id) ?? 99) }
  }
  /// The card's rows for the chosen scene, in `cardOrder`.
  ///
  /// A Kid match has no throw to go (the engine never plays one there), so its row goes
  /// while Computer is Kid rather than offer a choice that does nothing.
  public func cardRows(_ selections: [String: String]) -> [MatchOption] {
    let kid = (selections["computer"] ?? defaults["computer"]) == "kid"
    return Self.ordered(card(selections["scene"])?.rows ?? []).filter { !(kid && $0.id == "togo") }
  }
  /// The selections a match starts with: through the scene (core/scenes' resolve), so a
  /// surface or set the scene does not allow is its own. `PitchSession.startSolo` applies
  /// it, and `keep` and `load` write and read it.
  public func starting(_ selections: [String: String]) -> [String: String] {
    var s = selections
    guard takesScene else { return s }
    let scene = cards[s["scene"] ?? ""] != nil ? s["scene"]! : "day"
    let entry = SceneID.entry(scene)
    s["scene"] = scene
    s["surface"] = entry.resolve(s["surface"].flatMap(Surface.init(rawValue:))).rawValue
    s["set"] = entry.resolve(set: s["set"])
    return s
  }
  /// The selections after the player picks scene `id` on a card: the new scene's rows,
  /// and its surface and set, the ones chosen kept where it allows them, else its defaults
  /// (the web's throughScene: Black & White keeps the sand a player chose before Beach).
  public func choosing(scene id: String, _ selections: [String: String]) -> [String: String] {
    var s = selections
    s["scene"] = id
    return starting(s)
  }

  /// The card's selections kept on the device (`solo.option.<id>`): the defaults, then
  /// each kept value this engine still offers (the computer's level was kept as
  /// `solo.option.level` before it was the engine's `computer` option, 0.9), all through
  /// the scene (a surface or set kept from before may come back as the scene's).
  public func load(_ defaults: UserDefaults) -> [String: String] {
    var selections = self.defaults
    for row in rows {
      let keys = row.id == "computer" ? ["solo.option.computer", "solo.option.level"] : ["solo.option." + row.id]
      if let saved = keys.lazy.compactMap({ defaults.string(forKey: $0) }).first,
        row.choices.contains(where: { $0.first == saved })
      {
        selections[row.id] = saved
      }
    }
    return starting(selections)
  }

  /// A started match's selections kept for the next card, as it started (through the
  /// scene, so an older kept surface or set does not linger unseen).
  public func keep(_ selections: [String: String], in defaults: UserDefaults) {
    for (key, value) in starting(selections) { defaults.set(value, forKey: "solo.option." + key) }
  }
}

public struct MatchNeed: Decodable {
  public struct Setup: Decodable {
    /// The thrower: since engine 0.17 a computer player in a team has `cpu` and its
    /// `level` ("Bold Birch · computer · Pro"); `key` is its member id (a seat's id).
    public struct Player: Decodable {
      public let name: String
      public let cpu: Bool?
      public let level, key: String?
      /// A person's throw level (engine 1.3): "easy" or "hard", absent for standard: the
      /// width of the meter's bars (ThrowChoice).
      public let `throw`: String?
      /// The player's id in the match (engine 1.4's togo `throwers`, a raise's `players`).
      public let id: String?
    }
    public let n, of: Int
    public let projectile, label: String
    public let thrower: Player?
    /// The king shot (from the baseline, even in a Kid match).
    public let kingShot: Bool?
    /// What the engine raised and placed itself just before this throw (engine 0.16.0,
    /// kubb-engine docs/SESSION.md "need"): on the first throw need after it, else nil.
    let settled: Settled?
  }
  /// The engine's own raises and the punishment kubbs it placed, in the order done
  /// (`setup.settled`). Every pose is in the raiser's view frame (raiseInfo's frame and
  /// shape), or, in the wide view, the world frame (`frame: "world"`): drawn as given,
  /// never compared with the pitch or turned.
  struct Settled: Decodable {
    struct Entry: Decodable {
      /// "raise" or "punish".
      let kind: String
      let id: String
      /// The side that raised or placed it (the defender).
      let side: String?
      /// The end it stands on, as a raise action names it: 1 the +axis end, 2 the -axis.
      let which: Int?
      let lying, standing, pose: Pose?
      /// "world" in the wide view.
      let frame: String?
      /// The pitch round it in the same frame (the engine's next release; 0.16.0 gives
      /// none, and the board draws the king alone round the kubbs meanwhile).
      let others: [Other]?
      let king: Pose?
      /// The orientation it stands at in the next throw's world, in the same frame (engine
      /// 1.0.0: its seat in the turf, up to 3 degrees off plumb; nil when it stands plumb,
      /// as on the grid).
      let seat: Seat?
    }
    struct Seat: Decodable {
      let qw, qx, qy, qz: Double
    }
    let list: [Entry]?
  }
  public struct Handoff: Decodable {
    public struct Taken: Decodable { public let base, field: Int }
    public let toName: String, turn, kubbs, batons: Int, baseText: [String]
    public let fromName: String?, took: Taken?
    /// The sides the card goes to and from, and the base kubbs standing: { from's, to's }.
    public let to, from: String?, base: [Int]?
    /// The turn opens with a computer player (engine 0.17): its name and level.
    public let thrower: String?, throwerCpu: Bool?, throwerLevel: String?
  }
  public struct Card: Decodable { public let handoff: Handoff? }
  public struct Winner: Decodable {
    public let winner, winnerName: String, turns: Int, hits, thrown, minutes: Int?
  }
  public struct Pose: Decodable {
    let x, y: Double, angle: Double?, standing: Bool?
    init(x: Double, y: Double, angle: Double?, standing: Bool?) {
      (self.x, self.y, self.angle, self.standing) = (x, y, angle, standing)
    }
  }
  public struct End: Decodable {
    let pose: Pose
    public let which: Int, ok: Bool?, why: String?
  }
  struct Other: Decodable { let id: String, pose: Pose }
  /// A field kubb still lying in a raise (engine 1.4.0, `lying`, in id order, the first
  /// being `kubb`): any of them may be raised next, each with its own ends and choice.
  public struct Lying: Decodable {
    public let id: String
    let pose: Pose
    let choices, ends: [End]?
    let `default`: Int?
  }
  struct Bounds: Decodable { let xMin, xMax, yMin, yMax: Double }
  struct Last: Decodable { let short: String? }
  public let resignPending: String?
  /// A Kid match (engine 0.15): the Kid rules for both sides, the Kid meter for a person.
  public let kid: Bool?
  public let kind: String, side, team: String?, cpu: Bool?, setup: Setup?
  public let turn, n, of: Int?, teams: [String: String]?, standing: [String: Int]?
  public let card: Card?, winner: Winner?, how, short: String?
  public internal(set) var ends: [End]?
  var choices: [End]?, others: [Other]?, pose: Pose?, kubb: String?
  let king: Pose?
  /// The engine's choice when no end is named (a one-based index into `choices`): the end
  /// an automatic raise stands the kubb on.
  var `default`: Int?
  let cursor: GroundMark?, bounds: Bounds?, keepOut: [GroundMark]?, last: Last?
  /// Engine 1.4.0: every field kubb still lying (a raise in any order), the one camera the
  /// whole raise is drawn through (kind "raise" at the raiser's end, "end" at the viewer's
  /// for the other side's), and the frame every pose is in (the viewer's with `setView`).
  public let lying: [Lying]?
  let camera: Camera?
  public let frame: String?
  /// The raising side's players (engine 1.4.0): any of them may raise.
  public let players: [Setup.Player]?
  /// The throw to go (engine 1.4.0, kind "togo"): the round, the sides still to throw,
  /// whose baton is in, each side's thrower, the sides the engine throws for, and the last
  /// round's verdict when this round is a rethrow.
  public let round: Int?, owe: [String]?, thrown: [String: Bool]?
  public let throwers: [String: Setup.Player]?, computer: [String: Bool]?
  public let again: ThrowResult?

  /// A baton is aimed under this need: a throw, or a baton to go set up on this device
  /// (engine 1.4.0; while it waits for the other team's, `side` is nil and nothing aims).
  public var aims: Bool { kind == "throw" || (kind == "togo" && side != nil) }

  /// The raise need as it is for lying kubb `id` (engine 1.4.0's `lying`): its pose, ends,
  /// choices and default in the top-level fields the raise screen reads. Itself when `id`
  /// is the first or not lying.
  func picking(_ id: String?) -> MatchNeed {
    guard let id, id != kubb, let e = lying?.first(where: { $0.id == id }) else { return self }
    var n = self
    // the first kubb lies among the others now, and the picked one leaves them
    n.others = (others ?? []).filter { $0.id != id } + (kubb.flatMap { k in pose.map { Other(id: k, pose: $0) } }.map { [$0] } ?? [])
    n.kubb = e.id
    n.pose = e.pose
    n.ends = e.ends
    n.choices = e.choices
    n.default = e.default
    return n
  }
}

/// The match's game file as the engine writes it, but for a Duration that cannot be true
/// (the web's sheet.js UNKNOWN_DURATION): a stamped match ended within its first minute
/// says `[Duration "0m"]`, and a stamp from a clock gone wrong says more than
/// `MatchClock.maxMinutes`; those lines are left out of what is shown, copied and saved.
/// A match no action stamped has no Duration line at all (engine 0.18.0).
public struct ScoreSheet: Decodable {
  public let shown: [String], text, name: String, done: Bool
  enum CodingKeys: CodingKey { case shown, text, name, done }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    shown = try c.decode([String].self, forKey: .shown).filter { !Self.unknownDuration($0) }
    text = try c.decode(String.self, forKey: .text).split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !Self.unknownDuration(String($0)) }.joined(separator: "\n")
    name = try c.decode(String.self, forKey: .name)
    done = try c.decode(Bool.self, forKey: .done)
  }
  /// `[Duration "<n>m"]` with n under 1 or over `MatchClock.maxMinutes`.
  static func unknownDuration(_ line: String) -> Bool {
    guard line.hasPrefix("[Duration \""), line.hasSuffix("m\"]") else { return false }
    let n = Int(line.dropFirst(11).dropLast(3)) ?? 0
    return n < 1 || n > MatchClock.maxMinutes
  }
}

public struct PlacementCheck: Decodable {
  public let ok: Bool, label: String?
  /// Why a raise was refused (engine 1.4.0: "not raising", "not lying", "no end", "that end").
  public var why: String? = nil
}

/// The local save contains precisely the tagged session's snapshot text.
public struct MatchSave {
  public let file: URL
  public init(file: URL) { self.file = file }
  public func read() throws -> String? {
    do { return try String(contentsOf: file, encoding: .utf8) } catch let e as CocoaError
      where e.code == .fileReadNoSuchFile
    { return nil }
  }
  public func write(_ snapshot: String) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(snapshot.utf8).write(to: file, options: .atomic)
  }
  /// Home after a win: the save and its trail go; the finished match stays.
  public func clear() throws {
    clearTrail()
    do { try FileManager.default.removeItem(at: file) } catch let e as CocoaError
      where e.code == .fileNoSuchFile
    { return }
  }
}
