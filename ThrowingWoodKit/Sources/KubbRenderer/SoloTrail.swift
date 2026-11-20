import Foundation
import KubbRooms

// The solo match's replay trail on disk (docs/MATCH.md "The replay trail"): the match's
// first snapshot and every committed action since, so a match against the computer can
// be played again from its start (the engine's `replayLoad({ start, log })`) after the
// app has been closed. It lives beside the save and never leaves the device.
//
// The trail being played is JSON lines, appended one action at a time:
//
//   {"v":1,"engine":"0.7.2","complete":true,"start":"<snapshot>","h":"<hash>"}
//   {"a":<action>,"h":"<hash after it>"}
//   ...
//
// A line is written whole with one append and read only if it ends in a newline and
// parses, so a kill mid-write loses at most that line. The hash after each action is
// the engine's (FNV-1a of the snapshot) and lines the trail up with the save on resume.
// When the match ends the trail becomes the finished match, one JSON file written
// atomically, and stays until the next solo match ends.

struct TrailEntry: Equatable {
  let action: JSONText
  let hash: String
}

/// The trail of the solo match being played, as read from disk.
struct SoloTrail {
  var engine: String
  /// The trail begins at the match's first snapshot. False for a match resumed from a
  /// save the trail did not line up with (a save from an earlier build).
  var complete: Bool
  var start: String
  var startHash: String
  var entries: [TrailEntry]
  var lastHash: String { entries.last?.hash ?? startHash }
}

/// The last finished solo match, kept until the next solo match ends.
public struct FinishedSoloMatch {
  public static let version = 1
  /// The engine release the match was played on.
  public let engine: String
  /// The log runs from the match's first snapshot. Only a complete match can be replayed
  /// (and so shared): an incomplete one starts where an older build's save left it.
  public let complete: Bool
  public let winner: String
  /// Throw actions in the log.
  public let throwCount: Int
  /// The level the match was set up with, and the name typed for the player's side.
  public let level: String?
  public let name: String?
  /// The first snapshot the log starts from, exactly as the engine wrote it.
  public let start: String
  let entries: [TrailEntry]

  /// The replay's log as `replayLoad` takes it: `{ "a": <action> }` each, no hashes.
  public var log: [JSONText] { entries.map { JS.object([("a", .raw($0.action))]).json } }
  /// `{ "start": ..., "log": [...] }`: the argument of the engine's `replayLoad`.
  public var replay: JSONText {
    JS.object([("start", .string(start)), ("log", .array(log.map(JS.raw)))]).json
  }

  var json: JSONText {
    JS.object([
      ("v", .int(Self.version)), ("engine", .string(engine)), ("complete", .bool(complete)),
      ("winner", .string(winner)), ("throws", .int(throwCount)),
      ("level", level.map(JS.string) ?? .null), ("name", name.map(JS.string) ?? .null),
      ("start", .string(start)),
      ("log", .array(entries.map { JS.object([("a", .raw($0.action)), ("h", .string($0.hash))]) })),
    ]).json
  }

  init(trail: SoloTrail, winner: String) {
    engine = trail.engine
    complete = trail.complete
    self.winner = winner
    start = trail.start
    entries = trail.entries
    throwCount = trail.entries.count {
      (try? JSONNode.parse($0.action)["type"]?.string) == "throw"
    }
    let opts = try? JSONNode.parse(trail.start)["opts"]
    name = opts?["teams"]?["A"]?["name"]?.string
    level = opts?["teams"]?["A"]?["players"]?.items.first?["level"]?.string
  }

  init?(json text: String) {
    guard let d = try? JSONNode.parse(text), d["v"]?.int == Self.version,
      let engine = d["engine"]?.string, let complete = d["complete"]?.bool,
      let winner = d["winner"]?.string, let throwCount = d["throws"]?.int,
      let start = d["start"]?.string, let log = d["log"], log.kind == .array
    else { return nil }
    var entries: [TrailEntry] = []
    for e in log.items {
      guard let a = e["a"], a.kind == .object, let h = e["h"]?.string else { return nil }
      entries.append(TrailEntry(action: a.raw, hash: h))
    }
    self.engine = engine
    self.complete = complete
    self.winner = winner
    self.throwCount = throwCount
    level = d["level"]?.string
    name = d["name"]?.string
    self.start = start
    self.entries = entries
  }
}

extension MatchSave {
  /// The trail of the match being played, beside the save (`solo-match-trail.jsonl`).
  var trailFile: URL { sibling("trail.jsonl") }
  /// The last finished match (`solo-match-finished.json`).
  var finishedFile: URL { sibling("finished.json") }

  private func sibling(_ suffix: String) -> URL {
    file.deletingLastPathComponent().appending(
      path: file.deletingPathExtension().lastPathComponent + "-" + suffix)
  }

  /// The last finished solo match, if one is kept and readable.
  public func finishedMatch() -> FinishedSoloMatch? {
    (try? String(contentsOf: finishedFile, encoding: .utf8)).flatMap(FinishedSoloMatch.init(json:))
  }

  /// A new trail from `start`, replacing any other, written atomically.
  func beginTrail(start: String, hash: String, engine: String, complete: Bool) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let head = JS.object([
      ("v", .int(1)), ("engine", .string(engine)), ("complete", .bool(complete)),
      ("start", .string(start)), ("h", .string(hash)),
    ])
    try Data((head.ascii + "\n").utf8).write(to: trailFile, options: .atomic)
  }

  /// One committed action and the hash after it: a single append of one line.
  func appendTrail(_ action: JSONText, hash: String) throws {
    let line = JS.object([("a", .raw(action)), ("h", .string(hash))]).ascii + "\n"
    let handle = try FileHandle(forWritingTo: trailFile)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
  }

  /// The trail on disk and where each whole line ends; nil if missing or unreadable.
  /// An unfinished last line (a write cut short) is left out.
  func readTrail() -> (trail: SoloTrail, ends: [Int])? {
    guard let data = try? Data(contentsOf: trailFile) else { return nil }
    let bytes = [UInt8](data)
    var lines: [JSONNode] = [], ends: [Int] = []
    var from = 0, length = 0
    while let nl = bytes[from...].firstIndex(of: UInt8(ascii: "\n")) {
      guard let node = try? JSONNode.parse(String(decoding: bytes[from..<nl], as: UTF8.self))
      else { break }
      lines.append(node)
      from = nl + 1
      length = from
      ends.append(length)
    }
    // A line that does not parse is only forgivable as the last thing in the file.
    if length < bytes.count, bytes[length...].contains(UInt8(ascii: "\n")) { return nil }
    guard let head = lines.first, head["v"]?.int == 1, let engine = head["engine"]?.string,
      let complete = head["complete"]?.bool, let start = head["start"]?.string,
      let h0 = head["h"]?.string
    else { return nil }
    var entries: [TrailEntry] = []
    for line in lines.dropFirst() {
      guard let a = line["a"], a.kind == .object, let h = line["h"]?.string else { return nil }
      entries.append(TrailEntry(action: a.raw, hash: h))
    }
    return (
      SoloTrail(engine: engine, complete: complete, start: start, startHash: h0, entries: entries),
      ends
    )
  }

  /// The trail lined up with the save whose match hashes to `hash`, on this engine: cut
  /// back to the action that made the save (an append the save never caught up with goes)
  /// and to whole lines. Nil when it does not line up.
  func resumeTrail(hash: String, engine: String) -> SoloTrail? {
    guard let read = readTrail(), read.trail.engine == engine else { return nil }
    var trail = read.trail
    if trail.lastHash != hash {
      guard
        let i = trail.entries.lastIndex(where: { $0.hash == hash })
          ?? (trail.startHash == hash ? -1 : nil)
      else { return nil }
      trail.entries.removeSubrange((i + 1)...)
    }
    let length = read.ends[trail.entries.count]
    do {
      let handle = try FileHandle(forWritingTo: trailFile)
      defer { try? handle.close() }
      try handle.truncate(atOffset: UInt64(length))
    } catch { return nil }
    return trail
  }

  /// The match ended: its trail becomes the last finished match (written atomically, in
  /// place of the one before), and the trail file goes.
  func finishTrail(winner: String) throws {
    guard let trail = readTrail()?.trail else { return }
    let finished = FinishedSoloMatch(trail: trail, winner: winner)
    try Data(finished.json.text.utf8).write(to: finishedFile, options: .atomic)
    clearTrail()
  }

  func clearTrail() {
    try? FileManager.default.removeItem(at: trailFile)
  }
}
