import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch

extension PitchSession {
  /// A new practice pitch on `surface`, in `scene` (the practice menu's Scene, a
  /// look only: the engine keeps it from the start and has no setter, so a new
  /// scene is a new practice, as on the web). The day, an unknown id or an
  /// engine that takes no scene: no scene is sent.
  public func practice(scene: String? = nil, surface: Surface = .grass) throws {
    try useEngine(minor: nil)  // practice is always on the newest
    resetPresentation()
    trail = ReportTrail()
    need = nil
    save = nil
    trailKept = false
    trailComplete = false
    let look = scene.flatMap { options.takesScene && SceneID.drawn.contains($0) ? $0 : nil }
    try adopt(
      read(
        "new",
        #"{"mode":"practice","surface":"\#(surface.rawValue)""#
          + (look.map { #","scene":"\#($0)""# } ?? "") + "}"))
  }

  /// `level` is the player's kept level (ThrowLevel: 0.13 keeps it and throws every
  /// person on one meter; an older carried engine throws by it); `selections["computer"]`
  /// is the computer's, the set-up's per-game choice (and the player's when no
  /// level is given). On 0.9 it is the match's `computer` option; on an older
  /// engine it goes on the computer's player entry, as it always did.
  public func startSolo(
    name: String, level: String? = nil, selections: [String: String], save: MatchSave?
  ) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let player = trimmed.isEmpty ? "You" : String(trimmed.prefix(options.nameLimit))
    let computer = selections["computer"] ?? options.defaults["computer"]!
    let level = level ?? computer
    let time = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
    var setup: [String: Any] = selections.filter { options.rows.map(\.id).contains($0.key) }
    var cpu: [String: Any] = ["name": "Computer"]
    if !options.takesComputer {
      setup["computer"] = nil
      cpu["level"] = computer
    }
    setup.merge([
      "mode": "match", "cpu": "B", "first": "A", "seed": Int.random(in: 0..<2_147_483_648),
      "teams": [
        "A": ["name": player, "players": [["name": player, "level": level]]],
        "B": ["name": "Computer", "players": [cpu]],
      ],
      "start": [
        "year": time.year!, "month": time.month!, "day": time.day!, "hour": time.hour!,
        "min": time.minute!,
      ],
    ]) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: setup)
    try useEngine(minor: nil)  // a new match is always on the newest
    try openMatch("new", json: String(decoding: data, as: UTF8.self), save: save)
    try checkpoint()
  }

  /// Puts a kept match back on the pitch, on its own engine. `engine` (a version, or its
  /// major.minor) wins when the caller knows it (a shared match's kept replay). Otherwise
  /// one rule, in order, each only when the save is proven to be that match (the save,
  /// restored on that engine, hashes to a hash the file holds): (1) the kept trail's
  /// engine (SoloTrail.swift), (2) the finished-match file's engine (the app reopened on
  /// the winner card), (3) the newest. A trail or finished file from another match names
  /// nothing here, and only an engine this build carries is used; a save written before
  /// the trail plays on the newest, as it always did.
  public func restore(_ snapshot: String, save: MatchSave?, engine: String? = nil) throws {
    func carried(_ named: String?) -> String? {
      Engine.majorMinor(named).flatMap { Engine.carried.contains($0) ? $0 : nil }
    }
    /// The save's hash on `minor`, or nil when that engine cannot restore it.
    func hash(on minor: String) -> String? {
      guard (try? useEngine(minor: minor)) != nil,
        (try? self.engine.call("restore", json: snapshot)) != nil
      else { return nil }
      return try? self.engine.hash()
    }
    var mm = carried(engine)
    if engine == nil, let save {
      if let trail = save.readTrail()?.trail, let named = carried(trail.engine),
        let h = hash(on: named),
        h == trail.lastHash || h == trail.startHash || trail.entries.contains(where: { $0.hash == h })
      {
        mm = named
      } else if let finished = save.finishedMatch(), let named = carried(finished.engine),
        let key = finished.finalHash, hash(on: named) == key
      {
        mm = named
      }
    }
    try useEngine(minor: mm)
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
    guard options.levels.contains(level) else { return }
    levelOverride = level
    // practice (no need) sets its level for good; a match, the throw in hand
    if !playing, need == nil || (need?.kind == "throw" && need?.cpu == false) {
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
