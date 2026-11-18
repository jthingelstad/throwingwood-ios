import Foundation
import KubbRooms

/// Capture on opening the card. Actions may keep arriving while the player types.
public struct PitchReport {
  let fields: [(String, JS)]
  let ids: [String]
  let start, before, now: String
  let actions: [JSONText]
  let pieces: [JS]
  public func message(happened: String, should: String) throws -> JSONText {
    guard
      ![happened, should].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw RoomError("empty-report") }
    var dropped: [String] = []
    for pass in 0...3 {
      let snapshots = JS.object([
        ("start", pass == 0 ? .string(start) : .null),
        ("before", .string(before)), ("now", pass < 3 ? .string(now) : .null),
      ])
      var text = JS.object(
        fields + [
          ("snapshots", snapshots),
          ("actions", pass == 0 ? .array(actions.map(JS.raw)) : .null),
          ("pieces", pass < 2 ? .array(pieces) : .null),
        ]
      ).ascii
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
    let view = try JSONNode.parse(board.engine.call("frameView"))
    let need = view["need"]
    let keys = [
      "kind", "side", "turn", "throws", "cpu", "practice", "drill", "surface", "winner", "how",
      "resignPending",
    ]
    var summary: [(String, JS)] = keys.compactMap { k in
      need?[k].flatMap { $0.isNull ? nil : (k, .raw($0.raw)) }
    }
    if let last = need?["last"]?["text"] { summary.append(("last", .raw(last.raw))) }
    let rec = try JSONNode.parse(board.engine.call("recording"))
    let lastThrow = actions.last { (try? JSONNode.parse($0)["type"]?.string) == "throw" }
    let phase =
      board.playing
      ? "play"
      : (board.need?.kind == "throw"
        ? "aim"
        : (board.acceptsInput || board.need?.kind == "over" ? board.need?.kind ?? "wait" : "wait"))
    let fields: [(String, JS)] = [
      ("mode", .string("pitch")), ("client", .string("ios")),
      ("engine", .string(room.engineVersion)),
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
      ("phase", .string(phase)), ("need", .object(summary)), ("level", .string(level)),
      ("room", .string(room.code)), ("v", .int(room.version)),
      (
        "match",
        .object([("n", .int(controller.matchNumber ?? 0)), ("seq", .int(controller.sequence))])
      ),
      ("last", .raw(actions.last ?? .null)),
      (
        "lastThrow",
        lastThrow.map {
          .object([
            ("action", .raw($0)), ("result", .raw(rec["result"]?.raw ?? .null)),
            ("seq", .raw(rec["seq"]?.raw ?? .null)),
          ])
        } ?? .null
      ),
      ("options", .raw(try JSONNode.parse(trailNow)["opts"]?.raw ?? .null)),
    ]
    var ids = Set(room.members.compactMap { $0["id"]?.string })
    for team in try JSONNode.parse(trailNow)["opts"]?["teams"]?.members ?? [] {
      for player in team.value["players"]?.items ?? [] {
        if let id = player["key"]?.string,
          id.range(of: "^[A-Za-z0-9_-]{8,40}$", options: .regularExpression) != nil
        {
          ids.insert(id)
        }
      }
    }
    let pieces: [JS] = (view["items"]?.items ?? []).map { p in
      var values = ["id", "kind", "team", "toppled"].compactMap { k in
        p[k].map { (k, JS.raw($0.raw)) }
      }
      for k in ["x", "y", "z", "qw", "qx", "qy", "qz"] {
        if let v = p[k]?.double { values.append((k, .number((v * 10000).rounded() / 10000))) }
      }
      return .object(values)
    }
    return PitchReport(
      fields: fields, ids: ids.sorted { ($0.count, $0) > ($1.count, $1) },
      start: trailStart, before: trailBefore, now: trailNow, actions: actions, pieces: pieces)
  }
}
