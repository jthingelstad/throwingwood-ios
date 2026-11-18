import Foundation
import KubbRooms

struct ReportTrail {
  var start: String?
  var before: String?
  var now: String?
  var actions: [JSONText] = []

  init(snapshot: String? = nil) {
    start = snapshot
    before = snapshot
    now = snapshot
  }

  mutating func append(_ action: JSONText, snapshot: String? = nil) {
    before = now
    now = snapshot
    actions.append(action)
  }
}

public struct ReportPiece: Identifiable {
  public let id, kind: String
  public let x, y: Double
  let pose: JS

  init?(_ piece: JSONNode) {
    guard let id = piece["id"]?.string, let kind = piece["kind"]?.string,
      let x = piece["x"]?.double, let y = piece["y"]?.double
    else { return nil }
    self.id = id
    self.kind = kind
    self.x = x
    self.y = y
    var values = ["id", "kind", "team", "toppled"].compactMap { key in
      piece[key].map { (key, JS.raw($0.raw)) }
    }
    for key in ["x", "y", "z", "qw", "qx", "qy", "qz"] {
      if let n = piece[key]?.double { values.append((key, .number((n * 10000).rounded() / 10000))) }
    }
    pose = .object(values)
  }
}

/// Capture on opening the card. Actions may keep arriving while the player types.
public struct PitchReport {
  var fields: [(String, JS)]
  let ids: [String]
  let trail: ReportTrail
  public let candidates: [ReportPiece]
  let pieces: [JS]
  let practiceBefore: String?
  let surface: String
  public func message(happened: String, should: String, selected: Set<String> = []) throws
    -> JSONText
  {
    guard
      ![happened, should].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw RoomError("empty-report") }
    var dropped: [String] = []
    for pass in 0...3 {
      var contents = fields
      let ops = pass == 0 ? JS.array(trail.actions.map(JS.raw)) : .null
      if let now = trail.now {
        contents += [
          ("actions", ops),
          (
            "snapshots",
            .object([
              ("start", pass == 0 ? trail.start.map(JS.string) ?? .null : .null),
              ("before", trail.before.map(JS.string) ?? .null),
              ("now", pass < 3 ? .string(now) : .null),
            ])
          ),
        ]
      } else {
        let initialSurface = pass > 0 && practiceBefore == nil ? surface : "grass"
        var practice: [(String, JS)] = [("opts", .object([("surface", .string(initialSurface))]))]
        if pass > 0, let practiceBefore {
          practice += [("before", .string(practiceBefore)), ("ops", .null)]
        } else {
          practice.append(("ops", pass == 0 ? ops : .array([])))
        }
        contents.append(("practice", .object(practice)))
      }
      contents.append(("pieces", pass < 2 ? .array(pieces) : .null))
      let marked = candidates.filter { selected.contains($0.id) }.map(\.pose)
      if !marked.isEmpty { contents.append(("selectedPieces", .array(marked))) }
      var text = JS.object(contents).ascii
      for (i, id) in ids.enumerated() {
        text = text.replacingOccurrences(of: id, with: "member\(i+1)")
      }
      var result = try JSONNode.parse(text).members.map { ($0.key, JS.raw($0.value.raw)) }
      let clip = { (s: String) in String(s.unicodeScalars.prefix(1000)) }
      result += [("happened", .string(clip(happened))), ("should", .string(clip(should)))]
      if !dropped.isEmpty { result.append(("dropped", .array(dropped.map(JS.string)))) }
      let r = JS.object(result)
      if JS.object([("t", .string("report")), ("id", .int(1)), ("r", r)]).ascii.utf8.count <= 65536
      {
        return r.json
      }
      if pass < 3 { dropped.append(["history", "pieces", "after"][pass]) }
    }
    throw RoomError("too-big")
  }
}

extension OnlinePitch {
  public func captureReport(size: CGSize, scale: Double) throws -> PitchReport {
    try board.captureReport(size: size, scale: scale, online: self)
  }
}

extension PitchSession {
  public func captureReport(size: CGSize, scale: Double) throws -> PitchReport {
    try captureReport(size: size, scale: scale, online: nil)
  }

  fileprivate func captureReport(size: CGSize, scale: Double, online: OnlinePitch?) throws
    -> PitchReport
  {
    let view = try JSONNode.parse(engine.call("frameView"))
    let need = view["need"]
    let keys = [
      "kind", "side", "turn", "throws", "cpu", "practice", "drill", "surface", "winner", "how",
      "resignPending",
    ]
    var summary: [(String, JS)] = keys.compactMap { k in
      need?[k].flatMap { $0.isNull ? nil : (k, .raw($0.raw)) }
    }
    if let last = need?["last"]?["text"] { summary.append(("last", .raw(last.raw))) }
    let rec = try JSONNode.parse(engine.call("reportThrow"))
    let lastThrow = trail.actions.last { (try? JSONNode.parse($0)["type"]?.string) == "throw" }
    let phase =
      playing
      ? "play"
      : (need?["kind"]?.string == "throw"
        ? "aim"
        : (acceptsInput || self.need?.kind == "over" ? self.need?.kind ?? "wait" : "wait"))
    var fields: [(String, JS)] = [
      ("mode", .string(online != nil ? "pitch" : (trail.now == nil ? "practice" : "solo"))),
      ("client", .string("ios")),
      ("engine", .string(engine.engineVersion)),
      ("at", .int(Int(Date().timeIntervalSince1970 * 1000))),
      (
        "build",
        .object([
          ("version", .string(appVersion)),
          (
            "commit",
            (Bundle.main.object(forInfoDictionaryKey: "ThrowingWoodCommit") as? String).map(
              JS.string) ?? .null
          ), ("lua", .null),
        ])
      ),
      (
        "viewport",
        .object([
          ("w", .int(Int(size.width.rounded()))), ("h", .int(Int(size.height.rounded()))),
          ("dpr", .number(scale)),
        ])
      ),
      ("phase", .string(phase)), ("need", .object(summary)),
      ("level", .raw(view["aim"]?["plan"]?["level"]?.raw ?? .null)),
      ("last", .raw(trail.actions.last ?? .null)),
      (
        "lastThrow",
        lastThrow.map {
          .object([
            ("action", .raw($0)), ("result", .raw(rec["result"]?.raw ?? .null)),
            ("seq", .raw(rec["seq"]?.raw ?? .null)),
          ])
        } ?? .null
      ),
    ]
    var ids = Set<String>()
    if let online {
      let room = online.room
      fields += [
        ("room", .string(room.code)), ("v", .int(room.version)),
        (
          "match",
          .object([
            ("n", .int(online.controller.matchNumber ?? 0)), ("seq", .int(online.displayedSeq)),
          ])
        ),
      ]
      ids = Set(room.members.compactMap { $0["id"]?.string })
      ids.insert(room.you)
    }
    if let snapshot = trail.now {
      fields.append(("options", .raw(try JSONNode.parse(snapshot)["opts"]?.raw ?? .null)))
      if online != nil {
        for snap in Set([trail.start, trail.before, trail.now].compactMap { $0 }) {
          for team in try JSONNode.parse(snap)["opts"]?["teams"]?.members ?? [] {
            for player in team.value["players"]?.items ?? [] {
              if let id = player["key"]?.string,
                id.range(of: "^[A-Za-z0-9_-]{8,40}$", options: .regularExpression) != nil
              {
                ids.insert(id)
              }
            }
          }
        }
      }
    }
    let current = (view["items"]?.items ?? []).compactMap(ReportPiece.init)
    let seq = try lastThrow.flatMap { try JSONNode.parse($0)["seq"]?.int }
    let candidates =
      seq != nil && seq == rec["seq"]?.int
      ? (rec["items"]?.items ?? []).compactMap(ReportPiece.init) : current
    return PitchReport(
      fields: fields, ids: ids.sorted { ($0.count, $0) > ($1.count, $1) },
      trail: trail, candidates: candidates, pieces: current.map(\.pose),
      practiceBefore: seq != nil && seq == rec["seq"]?.int ? rec["practiceBefore"]?.string : nil,
      surface: view["surface"]?.string ?? "grass")
  }
}
