import Foundation
import KubbPitch

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
  /// The game had a last throw when the card opened: "A throw looked wrong" comes first.
  public var hasLastThrow: Bool {
    fields.contains { $0.0 == "lastThrow" && $0.1 != .null }
  }
  /// The web's REPORT_LIMITS (src/net/report.js), kept in step with the rooms server.
  public static let answerChars = 1000
  public static let feedbackChars = 2000

  /// A throw that looked wrong: `kind: "throw"`, the two answers and any pieces marked.
  public func message(happened: String, should: String, selected: Set<String> = []) throws
    -> JSONText
  {
    guard
      ![happened, should].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw PitchError("empty-report") }
    let clip = { (s: String) in String(s.unicodeScalars.prefix(Self.answerChars)) }
    return try message(
      typed: [
        ("kind", .string("throw")), ("happened", .string(clip(happened))),
        ("should", .string(clip(should))),
      ], selected: selected)
  }

  /// Anything else: `kind: "feedback"` and one `text`, trimmed, 1 to 2000 characters, and
  /// never a throw's answers or marked pieces.
  public func feedback(_ text: String) throws -> JSONText {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PitchError("empty-report") }
    return try message(
      typed: [
        ("kind", .string("feedback")),
        ("text", .string(String(trimmed.unicodeScalars.prefix(Self.feedbackChars)))),
      ], selected: [])
  }

  private func message(typed: [(String, JS)], selected: Set<String>) throws -> JSONText {
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
      result += typed
      if !dropped.isEmpty { result.append(("dropped", .array(dropped.map(JS.string)))) }
      let r = JS.object(result)
      if JS.object([("t", .string("report")), ("id", .int(1)), ("r", r)]).ascii.utf8.count <= 65536
      {
        return r.json
      }
      if pass < 3 { dropped.append(["history", "pieces", "after"][pass]) }
    }
    throw PitchError("too-big")
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
          // what the player sees in the menu, `0.2 (0.8.1)`, and the build number
          ("label", .string(versionLabel.text)),
          ("number", VersionLabel.bundleBuild.map(JS.string) ?? .null),
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
      let pitch = online.pitch
      // the pitch's code, its document's version, and the match's head as the client
      // holds it (the web's report.js): what joins the report to the recorded game
      fields += [("pitch", .string(pitch.code)), ("v", .int(pitch.version))]
      if let head = online.controller.head {
        fields.append(("match", .object([("n", .int(head.n)), ("seq", .int(head.seq))])))
      }
      ids = Set(pitch.members.compactMap { $0["id"]?.string })
      ids.insert(pitch.you)
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
