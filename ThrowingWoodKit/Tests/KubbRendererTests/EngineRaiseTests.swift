import CoreGraphics
import Foundation
import KubbEngine
import Testing
import simd

@testable import KubbRenderer

/// The raises the engine makes itself and the punishment kubbs it places (engine 0.16.0's
/// `need.setup.settled`), watched from its list alone: in its order, in the frame it gives
/// (the raiser's view frame; the world frame in the wide view), the king alone round them
/// in the thrower's view until the engine gives each entry its own surroundings.
@MainActor struct EngineRaiseTests {
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  /// A real throw view with `settled` put on its need's setup (the engine's shape).
  private func view(_ app: PitchSession, settled: [[String: Any]]) throws -> ViewOutput {
    var v = try #require(try JSONSerialization.jsonObject(with: Data(app.engine.call("view").utf8)) as? [String: Any])
    var need = try #require(v["need"] as? [String: Any])
    var setup = try #require(need["setup"] as? [String: Any])
    setup["settled"] = ["raised": 1, "punished": 1, "list": settled]
    need["setup"] = setup
    v["need"] = need
    return try JSONDecoder().decode(ViewOutput.self, from: JSONSerialization.data(withJSONObject: v))
  }

  private let raise: [String: Any] = [
    "kind": "raise", "id": "b3", "side": "B", "which": 2,
    "lying": ["x": 0.5, "y": 2.0, "standing": false, "angle": 0.3],
    "standing": ["x": 0.4, "y": 1.9, "standing": true, "angle": 0.3],
    "displaced": false, "crowded": false,
  ]
  private let punish: [String: Any] = [
    "kind": "punish", "id": "b4", "side": "B", "pose": ["x": -0.6, "y": 3.1, "standing": true, "angle": 0],
  ]

  @Test func theListIsPlayedInItsOrderWithAPunishmentKubbPlacedLast() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    let v = try view(app, settled: [raise, punish])
    let r = try #require(StoodShow.engineRaised(v))
    #expect(r.kubbs.map(\.id) == ["b3", "b4"])
    // end 2: the -axis end of the lying pose's own axis
    #expect(abs(r.kubbs[0].toward.x + cos(0.3)) < 1e-12 && abs(r.kubbs[0].toward.y + sin(0.3)) < 1e-12)
    #expect(!r.kubbs[0].placed && r.kubbs[1].placed)
    #expect(r.kubbs.allSatisfy { $0.frame == "B" })
    // the thrower's view: the king alone round them
    #expect(r.others.map(\.id) == ["king"])
    #expect(app.beginStoodShow(view: v))
    #expect(app.raiseNews?.text == "A kubb stood up and a punishment kubb placed.")
    var punishSeenBefore = false, punishStood = false
    var progress = 0.0
    var raisedEnd: Piece?
    for _ in 0..<600 where app.stoodShow != nil {
      let k = app.stoodShow!.k
      if k == 0 && app.scene.items.contains(where: { $0.id == "b4" }) { punishSeenBefore = true }
      let r = try #require(app.engineRaising)
      #expect(r.k == k + 1 && r.of == 2 && r.side == "B" && r.placed == (k == 1))
      if k == 1 {
        raisedEnd = app.scene.items.first { $0.id == "b3" }
        if let p = app.scene.items.first(where: { $0.id == "b4" }), !Neon.lying(p) { punishStood = true }
      }
      #expect(app.scene.frameSide == "B")
      let p = try #require(app.engineRaiseProgress)
      #expect(p >= progress && p <= 1)
      progress = p
      #expect(app.scene.footprints == nil)
      try app.tick(1.0 / 60)
    }
    #expect(!punishSeenBefore && punishStood)
    // the raised kubb stands where the engine stood it while the next plays
    let b3 = try #require(raisedEnd)
    #expect(b3.x == 0.4 && b3.y == 1.9 && !Neon.lying(b3))
    #expect(app.stoodShow == nil && app.need?.kind == "throw" && app.engineRaising == nil)
    #expect(HeaderWords.engineRaise(turn: 3, k: 1, of: 2, placed: false) == "Turn 3 · raise 1 of 2")
    #expect(HeaderWords.engineRaise(turn: 3, k: 2, of: 2, placed: true) == "Turn 3 · punishment kubb")
  }

  @Test func theWideViewDrawsTheWorldFrameWithTheViewsPieces() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    var world = raise, worldPunish = punish
    world["frame"] = "world"
    worldPunish["frame"] = "world"
    let v = try view(app, settled: [world, worldPunish])
    let r = try #require(StoodShow.engineRaised(v, wide: true))
    #expect(r.kubbs.allSatisfy { $0.frame == "A" })
    #expect(r.others.map(\.id) == v.items.map(\.id))
    // a list not all in the world frame keeps the king alone round it
    let mixed = try #require(StoodShow.engineRaised(try view(app, settled: [world, punish]), wide: true))
    #expect(mixed.others.map(\.id) == ["king"])
    #expect(mixed.kubbs.map(\.frame) == ["A", "B"])
  }

  /// The place the engine's next release fills: an entry's own `others` and `king` are the
  /// pitch round that kubb.
  @Test func anEntrysOwnSurroundingsAreDrawnWhenGiven() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    var e = raise
    e["others"] = [["id": "b1", "pose": ["x": 1.0, "y": 2.5, "standing": false, "angle": 0]]]
    e["king"] = ["x": 0.0, "y": 4.0, "standing": true, "angle": 0]
    let r = try #require(StoodShow.engineRaised(try view(app, settled: [e])))
    #expect(r.kubbs[0].around?.map(\.id) == ["b1", "king"])
    let s = StoodShow(kubbs: r.kubbs, before: r.others, after: try view(app, settled: [e]))
    #expect(Set(s.items(reduced: false).map(\.id)) == ["b1", "king", "b3"])
  }

  /// A real match in the watcher's wide view: the engine turns the list to the world frame
  /// (`frame: "world"`), and the show draws it there, round the view's own pieces.
  @Test func aWatchersWideViewWatchesTheEnginesRaises() throws {
    let app = try PitchSession(appVersion: "test")
    try app.openMatch("new", json: #"{"mode":"match","seed":11,"cpu":"both"}"#, save: nil)
    app.watching = true
    #expect(try app.watchWide(size: CGSize(width: 852, height: 393), safe: ScreenInsets()))
    var seen = false
    for _ in 0..<(60 * 60 * 3) where !seen {
      try app.tick(1.0 / 60)
      guard let s = app.stoodShow else { continue }
      seen = true
      let list = try #require(s.after.need.setup?.settled?.list)
      #expect(list.allSatisfy { $0.frame == "world" })
      #expect(s.kubbs.allSatisfy { $0.frame == "A" })
      #expect(s.before.map(\.id) == s.after.items.map(\.id))
      #expect(app.scene.frameSide == "A" && !app.scene.neighboursTurned)
    }
    #expect(seen)
  }

  /// Engine 1.0.0's seat: a kubb standing plumb leans up to its surface's seat in the turf,
  /// and each entry carries the `seat` it will stand at. A real match on grass, the
  /// computer raising for both sides: every watched raise and punishment kubb ends on the
  /// pose the next throw's items draw it at (its seat, resting on its lowest corner), so
  /// nothing steps when the board moves on; the tip itself starts plumb.
  @Test func anEngineRaiseEndsOnItsSeat() throws {
    let app = try PitchSession(appVersion: "test")
    try app.openMatch("new", json: #"{"mode":"match","seed":11,"cpu":"both"}"#, save: nil)
    app.watching = true
    var checked = 0
    for _ in 0..<(60 * 60 * 3) where checked == 0 {
      try app.tick(1.0 / 60)
      guard let show = app.stoodShow else { continue }
      let list = try #require(show.after.need.setup?.settled?.list)
      #expect(list.contains { $0.seat != nil }, "grass seats a standing kubb")
      for (k, kb) in show.kubbs.enumerated() {
        let entry = try #require(list.first { $0.id == kb.id })
        var s = show
        s.k = k
        s.age = s.total - 1e-9
        let end = s.shown(reduced: false)
        // the next throw's items are in its thrower's frame: turned half round about the
        // pitch's centre (core/frame) when that is not the raiser's (test only)
        var drawn = try #require(show.after.items.first { $0.id == kb.id })
        if kb.frame != show.after.need.side {
          let q = simd_quatd(angle: .pi, axis: V3(0, 0, 1)) * drawn.rotation
          (drawn.x, drawn.y) = (-drawn.x, 8 - drawn.y)
          (drawn.qw, drawn.qx, drawn.qy, drawn.qz) = (q.real, q.imag.x, q.imag.y, q.imag.z)
        }
        #expect(abs(end.x - drawn.x) < 1e-6 && abs(end.y - drawn.y) < 1e-6, "\(kb.id) where it stands")
        #expect(abs(end.z - drawn.z) < 1e-4, "\(kb.id) on its lowest corner")
        #expect(abs(abs(simd_dot(end.rotation.vector, drawn.rotation.vector)) - 1) < 1e-9, "\(kb.id) at its seat")
        if entry.seat != nil {
          // seated, it is off plumb by at most 3 degrees
          let up = end.rotation.act(V3(0, 0, 1)).z
          #expect(up < 1 && up >= cos(3 * Double.pi / 180))
          // and the tip ends plumb before it settles
          let top = StoodShow.tilt(kb, t: 1)
          #expect(abs(top.rotation.act(V3(0, 0, 1)).z - 1) < 1e-9)
        }
        // under Reduce Motion it stands at its seat at once
        s.age = s.lead + s.beat * 0.75
        #expect(abs(abs(simd_dot(s.shown(reduced: true).rotation.vector, drawn.rotation.vector)) - 1) < 1e-9)
        checked += 1
      }
    }
    #expect(checked > 0)
  }

  /// Engine 1.0.0's seat in the pieces the board draws while nothing plays: the view's
  /// standing kubbs already lean as the throw's world builds them, so the first frame of
  /// a throw (the player's or the other side's) draws each where the aim drew it.
  @Test func standingKubbsLeanAndDoNotStepAtAThrowsFirstFrame() throws {
    let board = try PitchSession(appVersion: "test")
    let before: ViewOutput = try board.read("view")
    let url = try #require(Bundle.module.url(forResource: "clean", withExtension: "json", subdirectory: "Fixtures/feel"))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let action = try JSONSerialization.data(withJSONObject: #require(object["action"]))
    struct Applied: Decodable { let recording: Recording }
    let applied: Applied = try board.read("apply", String(decoding: action, as: UTF8.self))
    let first = Playback(applied.recording).pieces(at: 0)
    var leaning = 0
    for k in before.items where k.kind == "kubb" {
      let up = k.rotation.act(V3(0, 0, 1)).z
      guard up > 0.9 else { continue }  // standing
      if up < 1 - 1e-9 { leaning += 1 }
      // grass seats a kubb up to 2 degrees
      #expect(up >= cos(2 * Double.pi / 180) - 1e-9, "\(k.id)")
      let f = try #require(first.first { $0.id == k.id })
      #expect(simd_length(f.center - k.center) < 1e-3, "\(k.id) where the aim drew it")
      #expect(abs(abs(simd_dot(f.rotation.vector, k.rotation.vector)) - 1) < 1e-5, "\(k.id) at the aim's lean")
    }
    #expect(leaning > 0)
  }
}
