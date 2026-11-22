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
    defaults = c.OPTION_DEFAULTS.filter { d in c.MATCH_OPTIONS.contains { $0.id == d.key } }
      .merging(["computer": "club", "scene": "day"]) { old, _ in old }
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
  /// part of the scene's choice), then Computer, Opening, Raising and Wind. A row the
  /// engine adds that is not named here goes last; there is no Kubbs row while no scene
  /// allows two sets.
  public static let cardOrder = ["scene", "surface", "computer", "opening", "raising", "wind", "set"]
  public static func ordered(_ rows: [MatchOption]) -> [MatchOption] {
    rows.sorted { (cardOrder.firstIndex(of: $0.id) ?? 99) < (cardOrder.firstIndex(of: $1.id) ?? 99) }
  }
  /// The card's rows for the chosen scene, in `cardOrder`.
  public func cardRows(_ selections: [String: String]) -> [MatchOption] {
    Self.ordered(card(selections["scene"])?.rows ?? [])
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
    public struct Player: Decodable { public let name: String }
    public let n, of: Int
    public let projectile, label: String
    public let thrower: Player?
    /// The king shot (from the baseline, even in a Kid match).
    public let kingShot: Bool?
  }
  public struct Handoff: Decodable {
    public struct Taken: Decodable { public let base, field: Int }
    public let toName: String, turn, kubbs, batons: Int, baseText: [String]
    public let fromName: String?, took: Taken?
    /// The sides the card goes to and from, and the base kubbs standing: { from's, to's }.
    public let to, from: String?, base: [Int]?
  }
  public struct Card: Decodable { public let handoff: Handoff? }
  public struct Winner: Decodable {
    public let winner, winnerName: String, turns: Int, hits, thrown, minutes: Int?
  }
  public struct Pose: Decodable { let x, y: Double, angle: Double?, standing: Bool? }
  public struct End: Decodable {
    let pose: Pose
    public let which: Int, ok: Bool?, why: String?
  }
  struct Other: Decodable { let id: String, pose: Pose }
  struct Bounds: Decodable { let xMin, xMax, yMin, yMax: Double }
  struct Last: Decodable { let short: String? }
  public let resignPending: String?
  /// A Kid match (engine 0.15): the Kid rules for both sides, the Kid meter for a person.
  public let kid: Bool?
  public let kind: String, side, team: String?, cpu: Bool?, setup: Setup?
  public let turn, n, of: Int?, teams: [String: String]?, standing: [String: Int]?
  public let card: Card?, winner: Winner?, how, short: String?
  public let ends: [End]?
  let choices: [End]?, others: [Other]?, pose, king: Pose?, kubb: String?
  let cursor: GroundMark?, bounds: Bounds?, keepOut: [GroundMark]?, last: Last?
}

public struct ScoreSheet: Decodable {
  public let shown: [String], text, name: String, done: Bool
}

public struct PlacementCheck: Decodable { public let ok: Bool, label: String? }

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
