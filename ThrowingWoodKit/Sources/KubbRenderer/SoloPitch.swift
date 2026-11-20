import CoreGraphics
import Foundation
import KubbRooms

extension PitchSession {
  public func practice() throws {
    resetPresentation()
    trail = ReportTrail()
    need = nil
    save = nil
    trailKept = false
    trailComplete = false
    try adopt(read("new", #"{"mode":"practice","surface":"grass"}"#))
  }

  public func startSolo(name: String, selections: [String: String], save: MatchSave?) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let player = trimmed.isEmpty ? "You" : String(trimmed.prefix(options.nameLimit))
    let level = selections["level"] ?? options.defaults["level"]!
    let time = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
    var setup: [String: Any] = selections
    setup.merge([
      "mode": "match", "cpu": "B", "first": "A", "seed": Int.random(in: 0..<2_147_483_648),
      "teams": [
        "A": ["name": player, "players": [["name": player, "level": level]]],
        "B": ["name": "Computer", "players": [["name": "Computer", "level": level]]],
      ],
      "start": [
        "year": time.year!, "month": time.month!, "day": time.day!, "hour": time.hour!,
        "min": time.minute!,
      ],
    ]) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: setup)
    try openMatch("new", json: String(decoding: data, as: UTF8.self), save: save)
    try checkpoint()
  }

  public func restore(_ snapshot: String, save: MatchSave?) throws {
    try openMatch("restore", json: snapshot, save: save)
  }

  func openMatch(_ method: String, json: String, save: MatchSave?) throws {
    let view: ViewOutput = try read(method, json)
    _ = try engine.call("setControl", json: #"{"sides":["A"],"cpu":true}"#)
    resetPresentation()
    autoRaise = AutoRaise()
    trail = ReportTrail(snapshot: try engine.call("snapshot"))
    self.save = save
    need = view.need
    keepTrail(resuming: method == "restore")
    try adopt(read("view"))
  }

  /// The replay trail on disk (SoloTrail.swift). A restore picks up the trail that lines
  /// up with the save; without one the match plays on, its trail starting here and
  /// marked incomplete. Nothing about the trail ever stops play.
  func keepTrail(resuming: Bool) {
    trailKept = false
    trailComplete = false
    guard let save, let start = trail.start, let hash = try? engine.hash() else { return }
    if resuming, let kept = save.resumeTrail(hash: hash, engine: engine.engineVersion) {
      trailKept = true
      trailComplete = kept.complete
      // killed between the last save and keeping the finished match
      if need?.kind == "over" { finishTrail() }
      return
    }
    // a finished match's save (the app closed on the winner card): its trail is kept
    guard need?.kind != "over" else { return }
    do {
      try save.beginTrail(start: start, hash: hash, engine: engine.engineVersion, complete: !resuming)
      trailKept = true
      trailComplete = !resuming
    } catch {}
  }

  private func finishTrail() {
    guard trailKept, let save else { return }
    trailKept = false
    guard let n: MatchNeed = try? read("need"), n.kind == "over", let winner = n.winner?.winner
    else { return }
    try? save.finishTrail(winner: winner)
  }

  func checkpoint() throws {
    if let save { try save.write(engine.call("snapshot")) }
  }

  func committed(_ action: JSONText) throws {
    if let onlineAction {
      try onlineAction(action)
    } else {
      let snapshot = need != nil ? try engine.call("snapshot") : nil
      trail.append(action, snapshot: snapshot)
      if let save, let snapshot {
        // the trail first: a save it has not caught up with could never be replayed
        if trailKept {
          do {
            try save.appendTrail(action, hash: engine.hash())
          } catch { trailKept = false }
        }
        try save.write(snapshot)
        if trailKept, (try? JSONNode.parse(engine.call("need"))["kind"]?.string) == "over" {
          finishTrail()
        }
      }
    }
  }

  public func dismissHandoff() {
    handoff = nil
    revision += 1
  }
  public func sheet() throws -> ScoreSheet { try read("sheet") }

  public func togglePlan() throws {
    guard canAim else { return }
    try cancelInput()
    plan.toggle()
    revision += 1
  }

  public func beginDial() {
    plan = false
    revision += 1
  }

  public func useLevel(_ level: String) throws {
    guard
      options.rows.first(where: { $0.id == "level" })?.choices.contains(where: { $0.first == level }
      ) == true
    else { return }
    levelOverride = level
    if !playing, need?.kind == "throw", need?.cpu == false {
      let args = try JSONEncoder().encode(["level": level])
      try replan("setLevel", String(decoding: args, as: UTF8.self))
    }
    revision += 1
  }

  public func resign() throws {
    guard need != nil, need?.kind != "over" else { return }
    let action = JSONText(#"{"type":"resign","side":"A"}"#)
    let r: PlacementCheck = try read("apply", action.text)
    if r.ok {
      if !playing { try adopt(read("view")) }
      try committed(action)
    }
  }

  public func stancePoint(in size: CGSize) -> CGPoint? {
    scene.thrower.flatMap { scene.projection(size, camera).project($0.point) }
  }

  public func stance(at point: CGPoint, size: CGSize) throws {
    guard canAim, let g = scene.projection(size, camera).ground(point) else { return }
    try replan("setStance", #"{"x":\#(g.x),"y":\#(g.y)}"#)
  }

  public func adjustPlan(arc: Bool, step: Int) throws {
    guard canAim else { return }
    try replan(arc ? "stepArc" : "stepSide", #"{"step":\#(step)}"#)
  }

  /// Raises the kubb on an end, or by the engine's choice. False when refused.
  @discardableResult public func raise(end: Int? = nil) throws -> Bool {
    guard acceptsInput, need?.kind == "raise" else { return false }
    if let end {
      guard need?.ends?.contains(where: { $0.which == end && $0.ok != false }) == true,
        let index = need?.choices?.firstIndex(where: { $0.which == end })
      else { return false }
      return try applyPlacement(#"{"type":"raise","choice":\#(index+1)}"#)
    } else {
      return try applyPlacement(#"{"type":"raise"}"#)
    }
  }

  public func movePunishment(to point: CGPoint, size: CGSize) throws {
    guard acceptsInput, let b = need?.bounds, let g = scene.projection(size, camera).ground(point)
    else { return }
    cursor = GroundMark(x: max(b.xMin, min(b.xMax, g.x)), y: max(b.yMin, min(b.yMax, g.y)))
    try settleScene()
    revision += 1
  }

  public func placePunishment() throws {
    guard acceptsInput, need?.kind == "punish", placement?.ok == true, let c = cursor else {
      return
    }
    try applyPlacement(#"{"type":"punish","x":\#(c.x),"y":\#(c.y)}"#)
  }

  @discardableResult private func applyPlacement(_ json: String) throws -> Bool {
    let response: PlacementCheck = try read("apply", json)
    guard response.ok else {
      placement = response
      revision += 1
      return false
    }
    try committed(JSONText(json))
    try adopt(read("view"))
    return true
  }
}
