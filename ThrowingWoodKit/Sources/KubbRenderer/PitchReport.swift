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
  /// "A" or "B" for a kubb that has a team, else nil.
  public let team: String?
  public let toppled: Bool
  /// The piece's orientation (core/quat), the identity when the pose has none.
  public let qw, qx, qy, qz: Double
  let pose: JS

  init?(_ piece: JSONNode) {
    guard let id = piece["id"]?.string, let kind = piece["kind"]?.string,
      let x = piece["x"]?.double, let y = piece["y"]?.double
    else { return nil }
    self.id = id
    self.kind = kind
    self.x = x
    self.y = y
    team = piece["team"]?.string
    toppled = piece["toppled"]?.bool == true
    qw = piece["qw"]?.double ?? 1
    qx = piece["qx"]?.double ?? 0
    qy = piece["qy"]?.double ?? 0
    qz = piece["qz"]?.double ?? 0
    var values = ["id", "kind", "team", "toppled"].compactMap { key in
      piece[key].map { (key, JS.raw($0.raw)) }
    }
    for key in ["x", "y", "z", "qw", "qx", "qy", "qz"] {
      if let n = piece[key]?.double { values.append((key, .number((n * 10000).rounded() / 10000))) }
    }
    pose = .object(values)
  }
}

/// Where the player painted on the report's picture of the pitch, in the frame and metres
/// of its pieces (x across, y along): a brush radius and strokes of points.
public struct ReportPaint: Equatable, Sendable {
  public var brush: Double
  public var strokes: [[CGPoint]]
  public init(brush: Double, strokes: [[CGPoint]] = []) {
    self.brush = brush
    self.strokes = strokes
  }

  /// The api's limits (backend/api/API.md "report", the web's src/net/paint.js).
  public static let maxStrokes = 32
  public static let maxPoints = 800
  public static let brushRange = 0.05...1.0
  public static let xRange = -6.0...6.0
  public static let yRange = -4.0...12.0

  public var points: Int { strokes.reduce(0) { $0 + $1.count } }
  /// Is there room for another point (and, `newStroke`, another stroke)?
  public func hasRoom(newStroke: Bool) -> Bool {
    points < Self.maxPoints && (!newStroke || strokes.count < Self.maxStrokes)
  }

  /// The paint as the message carries it (the web's normalizePaint): numbers to 2
  /// decimals, x and y clamped, a point the same as the one before it left out, the
  /// strokes after the 32nd and the points after the 800th left off, empty strokes
  /// dropped. nil when nothing is painted.
  public var wire: JS? {
    func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }
    var left = Self.maxPoints
    var out: [[(Double, Double)]] = []
    for s in strokes {
      if out.count >= Self.maxStrokes || left <= 0 { break }
      var pts: [(Double, Double)] = []
      for p in s {
        if pts.count >= left { break }
        let x = Double(p.x), y = Double(p.y)
        guard x.isFinite, y.isFinite else { continue }
        let q = (r2(clamp(x, Self.xRange)), r2(clamp(y, Self.yRange)))
        if let last = pts.last, last == q { continue }
        pts.append(q)
      }
      if pts.isEmpty { continue }
      left -= pts.count
      out.append(pts)
    }
    if out.isEmpty { return nil }
    let b = r2(clamp(brush.isFinite ? brush : Self.brushRange.lowerBound, Self.brushRange))
    return .object([
      ("brush", .number(b)),
      ("strokes", .array(out.map { .array($0.map { .array([.number($0.0), .number($0.1)]) }) })),
    ])
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

  /// A throw that looked wrong: `kind: "throw"`, the two answers and any paint.
  public func message(happened: String, should: String, paint: ReportPaint? = nil) throws
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
      ], paint: paint)
  }

  /// Anything else: `kind: "feedback"` and one `text`, trimmed, 1 to 2000 characters, and
  /// never a throw's answers; any paint, as a throw's.
  public func feedback(_ text: String, paint: ReportPaint? = nil) throws -> JSONText {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PitchError("empty-report") }
    return try message(
      typed: [
        ("kind", .string("feedback")),
        ("text", .string(String(trimmed.unicodeScalars.prefix(Self.feedbackChars)))),
      ], paint: paint)
  }

  /// `paint`, when anything is painted: `{ brush, strokes }` in the frame and metres of
  /// `pieces` (backend/api/API.md "report"). A painted report's `pieces` are the ones its
  /// picture showed (`candidates`: the last throw's rest when there is one) and are never
  /// dropped to fit, so a reader puts the strokes on the pieces the player saw (the web's
  /// src/net/report.js). No piece is picked by name any more: no `selectedPieces`.
  private func message(typed: [(String, JS)], paint: ReportPaint?) throws -> JSONText {
    var dropped: [String] = []
    let painted = paint?.wire
    var typed = typed
    if let painted { typed.append(("paint", painted)) }
    let shown = painted == nil ? pieces : candidates.map(\.pose)
    // what goes first to fit: the history, the pieces (never when painted), the after
    let drops = ["history", "pieces", "after"].filter { painted == nil || $0 != "pieces" }
    for pass in 0...drops.count {
      let cut = Set(drops.prefix(pass))
      var contents = fields
      let ops = !cut.contains("history") ? JS.array(trail.actions.map(JS.raw)) : .null
      if let now = trail.now {
        contents += [
          ("actions", ops),
          (
            "snapshots",
            .object([
              ("start", !cut.contains("history") ? trail.start.map(JS.string) ?? .null : .null),
              ("before", trail.before.map(JS.string) ?? .null),
              ("now", !cut.contains("after") ? .string(now) : .null),
            ])
          ),
        ]
      } else {
        let short = cut.contains("history")
        let initialSurface = short && practiceBefore == nil ? surface : "grass"
        var practice: [(String, JS)] = [("opts", .object([("surface", .string(initialSurface))]))]
        if short, let practiceBefore {
          practice += [("before", .string(practiceBefore)), ("ops", .null)]
        } else {
          practice.append(("ops", !short ? ops : .array([])))
        }
        contents.append(("practice", .object(practice)))
      }
      contents.append(("pieces", !cut.contains("pieces") ? .array(shown) : .null))
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
      if pass < drops.count { dropped.append(drops[pass]) }
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
