import Foundation
import KubbEngine

// Generated names (kubb-engine docs/NAMES.md, its docs/SESSION.md "Names"; the owner,
// 2026-11-21: no typed name anywhere): every player and team name is made from the
// engine's word lists, never typed. This is the app's door to the engine's `names.*`
// calls, and the one place a name that arrives from outside (a pitch, a kept match, a
// shared replay) is checked before it is shown. The web's src/game/names.js, call for
// call.
//
// A name is kept and sent as its text. Slots are 0-based and parts `{ shape, words }`,
// as the engine has them. A side of one player is named after that player, so a team
// name there is checked as a player's (`teamPasses`).

/// A name's words as the engine gives them: its shape's id (`adj`; for a team also
/// `wood` or `the`) and one word per slot.
public struct NameParts: Equatable, Sendable {
  public var shape: String
  public var words: [String]
  public init(shape: String, words: [String]) {
    self.shape = shape
    self.words = words
  }
  var js: JS { .object([("shape", .string(shape)), ("words", .array(words.map(JS.string)))]) }
  init?(_ node: JSONNode?) {
    guard let node, let shape = node["shape"]?.string, node["words"]?.kind == .array else { return nil }
    self.shape = shape
    words = node["words"]!.items.map { $0.string ?? "" }
  }
}

/// What `names.valid` says of a text: a generated name of the kind (`ok`, with its
/// parts), or one of the engine's own names for no name (`isDefault`: "Computer",
/// "Team A", "Player 1" and so on).
public struct NameCheck: Equatable, Sendable {
  public let ok: Bool
  public let isDefault: Bool
  public let parts: NameParts?
  /// What a boundary takes: a generated name or a default.
  public var passes: Bool { ok || isDefault }
}

public enum NameKind: String, Sendable { case player, team }

@MainActor public final class Names {
  public let engine: Engine
  private let seed: () -> Int
  private var checked: [NameKind: [String: NameCheck]] = [:]
  private var prefixes: [String: String?]?

  /// `seed` is this device's own randomness (the system's generator) unless a test
  /// gives its own.
  public init(engine: Engine, seed: @escaping () -> Int = Names.randomSeed) {
    self.engine = engine
    self.seed = seed
  }

  /// A whole-number seed from the system's random source (arc4random on Apple's
  /// platforms), as the web takes one from crypto.getRandomValues.
  nonisolated public static func randomSeed() -> Int {
    var g = SystemRandomNumberGenerator()
    return Int(g.next() & 0x7fff_ffff)
  }

  /// The engine's names for no name (its names.words `defaults`): "Player n" for a
  /// member, n its place on its side (1 to 6), and "Team A" / "Team B" for a side.
  nonisolated public static func playerDefault(_ n: Int) -> String { "Player \(max(1, min(6, n)))" }
  /// A computer seat with no name the engine passes (the engine's docs/PITCH.md: "shown as
  /// `Computer`").
  nonisolated public static let computer = "Computer"
  nonisolated public static func teamDefault(_ side: String) -> String { "Team \(side == "B" ? "B" : "A")" }

  private func call(_ name: String, _ args: [(String, JS)]) throws -> JSONNode {
    try JSONNode.parse(engine.call("names." + name, json: JS.object(args).ascii))
  }

  /// A name drawn from this device's randomness; `keep` holds locked words (a nil word is
  /// open). Nil only when the kept words make no name.
  public func roll(_ kind: NameKind, keep: (shape: String, words: [String?])? = nil) throws
    -> (text: String, parts: NameParts)?
  {
    var args: [(String, JS)] = [("kind", .string(kind.rawValue)), ("seed", .int(seed()))]
    if let keep {
      args.append(
        ("keep", .object([("shape", .string(keep.shape)), ("words", .array(keep.words.map { $0.map(JS.string) ?? .null }))])))
    }
    let r = try call("roll", args)
    guard let text = r["text"]?.string, let parts = NameParts(r["parts"]) else { return nil }
    return (text, parts)
  }

  /// The next word in `slot` that makes a name with the others (`dir` 1 or -1).
  public func step(_ kind: NameKind, _ parts: NameParts, slot: Int, dir: Int = 1) throws -> (text: String, parts: NameParts)? {
    let r = try call("step", [("kind", .string(kind.rawValue)), ("parts", parts.js), ("slot", .int(slot)), ("dir", .int(dir))])
    guard r["moved"]?.bool == true, let text = r["text"]?.string, let p = NameParts(r["parts"]) else { return nil }
    return (text, p)
  }

  /// Every word `slot` can take with the other words as they are, in `step`'s order.
  public func choices(_ kind: NameKind, _ parts: NameParts, slot: Int) throws -> [String] {
    try call("choices", [("kind", .string(kind.rawValue)), ("parts", parts.js), ("slot", .int(slot))])["words"]?
      .items.compactMap(\.string) ?? []
  }

  /// The text for parts, or nil when they make no name.
  public func make(_ kind: NameKind, _ parts: NameParts) throws -> String? {
    try call("make", [("kind", .string(kind.rawValue)), ("parts", parts.js)])["text"]?.string
  }

  /// `names.valid`, kept per text.
  public func valid(_ kind: NameKind, _ text: String?) -> NameCheck {
    guard let text else { return NameCheck(ok: false, isDefault: false, parts: nil) }
    if let v = checked[kind]?[text] { return v }
    let r = try? call("valid", [("kind", .string(kind.rawValue)), ("text", .string(text))])
    let v = NameCheck(ok: r?["ok"]?.bool == true, isDefault: r?["default"]?.bool == true, parts: NameParts(r?["parts"]))
    if (checked[kind]?.count ?? 0) > 512 { checked[kind] = [:] }
    checked[kind, default: [:]][text] = v
    return v
  }

  /// A generated name or a default: what a boundary takes.
  public func passes(_ kind: NameKind, _ text: String?) -> Bool { valid(kind, text).passes }

  /// A team's name: a team name, or on a side of one player that player's name.
  public func teamPasses(_ text: String?, players: Int = 2) -> Bool {
    passes(.team, text) || (players == 1 && passes(.player, text))
  }

  /// The text when it passes, else the fallback (the default for its place).
  public func shown(_ kind: NameKind, _ text: String?, fallback: String) -> String {
    passes(kind, text) ? text! : fallback
  }

  /// Every name of a kind (`names.all`): for measuring, never on a screen.
  public func all(_ kind: NameKind) throws -> [String] {
    try call("all", [("kind", .string(kind.rawValue))])["names"]?.items.compactMap(\.string) ?? []
  }

  /// The literal first word of a shape ("The" for a team's `the`), or nil: shown as text,
  /// not a slot.
  public func prefix(_ kind: NameKind, shape: String) -> String? {
    if prefixes == nil {
      var out: [String: String?] = [:]
      if let shapes = try? call("words", [])["shapes"] {
        for k in [NameKind.player, .team] {
          for s in shapes[k.rawValue]?.items ?? [] {
            if let id = s["id"]?.string { out[k.rawValue + "/" + id] = s["prefix"]?.string }
          }
        }
      }
      prefixes = out
    }
    return prefixes?[kind.rawValue + "/" + shape] ?? nil
  }

  /// What the engine's `names.check` says of a whole snapshot, replay or pitch document
  /// (kubb-engine docs/SESSION.md "A match from outside"): `allowed` when every name and
  /// sentence it could ever show passes and its copies agree. `refusedFrom` holds the raw
  /// paths of what is refused, to match against this client's own paths (a lobby's
  /// `members[i].me.name`, `teamNames.A`), never to show: a forged path can carry
  /// submitted text. `places` are the safe paths, for a log line.
  public struct MatchCheck: Sendable {
    public let allowed: Bool
    public let refusedFrom: Set<String>
    public let places: [String]
  }

  private func check(_ args: [(String, JS)]) -> MatchCheck {
    guard let r = try? call("check", args) else {
      return MatchCheck(allowed: false, refusedFrom: [], places: [])
    }
    let refused = (r["refused"]?.items ?? []) + (r["mismatches"]?.items ?? [])
    return MatchCheck(
      allowed: r["allowed"]?.bool == true,
      refusedFrom: Set(refused.compactMap { $0["from"]?.string }),
      places: refused.compactMap { $0["place"]?.string })
  }

  /// `restore`'s strict door for a snapshot someone else sent (kubb-engine docs/SESSION.md
  /// "A match from outside"): `{ snap, names: "check" }`, refused by the engine before
  /// anything changes when `names.check` does not allow it. The device's own kept match
  /// uses the plain `restore`.
  nonisolated public static func checkedRestore(_ snap: String) -> String {
    JS.object([("snap", .string(snap)), ("names", .string("check"))]).ascii
  }

  /// A snapshot from outside (a pitch's), its text: the engine walks it whole.
  public func check(snap: String) -> MatchCheck { check([("snap", .string(snap))]) }
  /// A replay or kept match from outside (a sealed pitch's kept replay, a share's start
  /// and log), as raw JSON: its `start` or `setup`, and `snap`, `players`, `log` when it
  /// has them.
  public func check(replay: JSONText) -> MatchCheck { check([("replay", .raw(replay))]) }
  /// A pitch's document and members (`[{ id, me }]`): the host's `teamNames`, the match
  /// header's players and every member's name.
  public func check(document: JSONText, members: JSONText) -> MatchCheck {
    check([("document", .raw(document)), ("members", .raw(members))])
  }


  /// Two members with one name told apart in a lobby: the second shows "II", the third
  /// "III", by the order given (the web's apartNames). Never changes a name.
  nonisolated public static func apart(_ list: [(id: String, name: String)]) -> [String: String] {
    let numerals = ["", " II", " III", " IV", " V", " VI", " VII", " VIII"]
    var seen: [String: Int] = [:]
    var out: [String: String] = [:]
    for (id, name) in list {
      let k = seen[name, default: 0]
      seen[name] = k + 1
      out[id] = name + (k < numerals.count ? numerals[k] : " \(k + 1)")
    }
    return out
  }
}
