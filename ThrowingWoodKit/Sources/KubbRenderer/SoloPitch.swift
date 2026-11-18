import CoreGraphics
import Foundation
import KubbRooms

extension PitchSession {
  public func practice() throws {
    resetPresentation()
    need = nil
    save = nil
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
    self.save = save
    need = view.need
    try adopt(read("view"))
  }

  func checkpoint() throws {
    if let save { try save.write(engine.call("snapshot")) }
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

  public func toggleWalk() throws {
    guard canAim else { return }
    try cancelInput()
    walking.toggle()
    walkAxis = .zero
    revision += 1
  }

  public func walk(drag: CGPoint) {
    func axis(_ delta: CGFloat) -> CGFloat {
      guard abs(delta) > 8 else { return 0 }
      return (delta < 0 ? -1 : 1) * min(1, (abs(delta) - 8) / 60)
    }
    walkAxis = CGPoint(x: axis(drag.x), y: -axis(drag.y))
  }

  public func beginDial() {
    plan = false
    walking = false
    walkAxis = .zero
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
    let r: PlacementCheck = try read("apply", #"{"type":"resign","side":"A"}"#)
    if r.ok {
      if !playing { try adopt(read("view")) }
      try checkpoint()
    }
  }

  public func endLabels(in size: CGSize) -> [(Int, CGPoint)] {
    let p = scene.projection(size, camera)
    return (need?.ends ?? []).compactMap { e in
      p.project(V3(e.pose.x, e.pose.y, 0)).map { (e.which, $0) }
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

  public func raise(end: Int? = nil) throws {
    guard acceptsInput, need?.kind == "raise" else { return }
    if let end {
      guard need?.ends?.contains(where: { $0.which == end && $0.ok == true }) == true,
        let index = need?.choices?.firstIndex(where: { $0.which == end })
      else { return }
      try applyPlacement(#"{"type":"raise","choice":\#(index+1)}"#)
    } else {
      try applyPlacement(#"{"type":"raise"}"#)
    }
  }

  public func raise(at point: CGPoint, size: CGSize) throws {
    let projection = scene.projection(size, camera)
    let hits = (need?.ends ?? []).compactMap { end -> (Int, Double)? in
      guard let p = projection.project(V3(end.pose.x, end.pose.y, 0)) else { return nil }
      return (end.which, p.distance(to: point))
    }
    if let hit = hits.min(by: { $0.1 < $1.1 }), hit.1 <= 44 { try raise(end: hit.0) }
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

  private func applyPlacement(_ json: String) throws {
    let response: PlacementCheck = try read("apply", json)
    guard response.ok else {
      placement = response
      revision += 1
      return
    }
    try onlineAction?(JSONText(json))
    try checkpoint()
    try adopt(read("view"))
  }
}
