import Foundation
import KubbEngine

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

public struct SoloOptions {
  public let rows: [MatchOption], defaults: [String: String]
  public let nameLimit: Int
  /// The throw levels (`LEVELS`): the computer's. A person has none (engine 0.13).
  public let levels: [String]
  /// The engine takes the computer's level as a match option (`computer`, since 0.9).
  /// On an older engine the row is the app's own, and its value goes on the
  /// computer's player entry instead.
  public let takesComputer: Bool
  /// The engine takes a scene (`scene` in OPTION_DEFAULTS, since 0.9): the Scene row shows.
  public let takesScene: Bool
  init(engine: Engine) throws {
    struct Constants: Decodable {
      let MATCH_OPTIONS: [MatchOption], LEVELS: [String], OPTION_DEFAULTS: [String: String],
        NAME_MAX: Int
    }
    struct Reply: Decodable { let value: Constants }
    let c = try JSONDecoder().decode(Reply.self, from: Data(engine.call("room.constants").utf8))
      .value
    levels = c.LEVELS
    takesComputer = c.MATCH_OPTIONS.contains { $0.id == "computer" }
    // The computer's level leads, as before: the engine's row on 0.9, the app's own
    // before it. The Scene row (the client labels it, as the web's SCENE_ROW) comes
    // last, on an engine that takes a scene.
    let computer =
      c.MATCH_OPTIONS.first { $0.id == "computer" }
      ?? MatchOption(id: "computer", label: "Computer", choices: c.LEVELS.map { [$0, $0.capitalized] })
    takesScene = SceneID.taken(by: c.OPTION_DEFAULTS)
    let rows =
      [computer] + c.MATCH_OPTIONS.filter { $0.id != "computer" && $0.id != "scene" }
      + (takesScene ? [SceneID.row] : [])
    self.rows = rows
    defaults = c.OPTION_DEFAULTS.filter { d in rows.contains { $0.id == d.key } }
      .merging(["computer": "club"]) { old, _ in old }
    nameLimit = c.NAME_MAX
  }
}

public struct MatchNeed: Decodable {
  public struct Setup: Decodable {
    public struct Player: Decodable { public let name: String }
    public let n, of: Int
    public let projectile, label: String
    public let thrower: Player?
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
