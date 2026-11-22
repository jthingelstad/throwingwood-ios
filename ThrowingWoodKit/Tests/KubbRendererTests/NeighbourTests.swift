import CoreGraphics
import Foundation
import KubbEngine
import Testing
import simd
import QuartzCore

@testable import KubbRenderer

/// The Tournament's live neighbours (engine 0.15.1): a second engine of their own, opened,
/// advanced on the match clock, played back through `Playback` and closed, and nothing of
/// it reaching the player's match.
@MainActor struct NeighbourTests {
  /// Ticks the field at 60 Hz, waiting on its queue after each frame so a test sees every
  /// answer at once (the app never waits), until `until` holds or `seconds` pass.
  static func run(_ n: TournamentNeighbours, seconds: Double, until: () -> Bool = { false }) {
    for _ in 0..<Int(seconds * 60) {
      n.tick(1.0 / 60)
      n.drain()
      if until() { return }
    }
  }

  /// The second engine opens, advances to a first throw, plays it back to where the
  /// engine's own `view` says the pitch stands, and closes.
  @Test func theFieldOpensPlaysAThrowAndCloses() throws {
    let n = TournamentNeighbours()
    #expect(!n.engineStarted)
    n.want(.init(seed: 5, row: false))
    Self.run(n, seconds: 1) { n.live }
    #expect(n.live)
    #expect(n.engineStarted)
    #expect(n.field.pitches.count == 8)
    // the first throw: some pitch's recording starts playing
    Self.run(n, seconds: 30) { n.field.pitches.contains { $0.playing != nil } }
    let thrown = try #require(n.field.pitches.first { $0.playing != nil })
    let (pb, at) = try #require(thrown.playing)
    #expect(pb.recording.duration > 0.2)
    // mid-flight the thrown piece moves
    let mid = n.field.drawn(at: at + pb.recording.duration / 2, turned: false)
    let start = n.field.drawn(at: at, turned: false)
    let id = pb.recording.projectile.id
    let i = try #require(n.field.pitches.firstIndex { $0.id == thrown.id })
    let p0 = try #require(start[i].pieces.first { $0.id == id })
    let p1 = try #require(mid[i].pieces.first { $0.id == id })
    #expect(simd_distance(p0.center, p1.center) > 0.3)
    // played to its end: the items are the engine's, to the millimetre
    Self.run(n, seconds: 5) { n.clock >= at + pb.recording.duration + 0.05 }
    let mine = try #require(n.field.pitches.first { $0.id == thrown.id })
    #expect(mine.playing == nil)
    let view = try #require(
      try n.onEngine { e in
        try JSONDecoder().decode(
          NeighbourPitchState.self, from: Data(e.call("neighbours.view", json: #"{"id":\#(thrown.id)}"#).utf8))
      })
    #expect(view.recording == nil)
    let theirs = Dictionary(uniqueKeysWithValues: view.items.map { ($0.id, $0) })
    #expect(Set(theirs.keys) == Set(mine.items.map(\.id)))
    for p in mine.items {
      let q = try #require(theirs[p.id])
      #expect(simd_distance(p.center, q.center) < 0.0015, "\(p.id)")
    }
    n.close()
    #expect(n.open == nil)
    #expect(!n.live)
    #expect(n.drawn(turned: false) == nil)
    // no answer from before the close arrives after it
    n.tick(1.0 / 60)
    n.drain()
    n.tick(1.0 / 60)
    #expect(!n.live)
    #expect(n.cost.calls > 0)
  }

  /// Only the Tournament, only in a match, practice or watched match, never under Reduce
  /// Motion; and a field that is never wanted never makes its engine.
  @Test func theFieldIsOnlyForTheTournament() throws {
    for look in SceneID.catalogue.map(\.id) + [nil, "moon"] {
      let w = TournamentNeighbours.want(look: look, inMatch: true, reduced: false, seed: 3, row: false)
      #expect((w != nil) == (look == "tournament"), "\(look ?? "nil")")
    }
    #expect(TournamentNeighbours.want(look: "tournament", inMatch: false, reduced: false, seed: 3, row: false) == nil)
    #expect(TournamentNeighbours.want(look: "tournament", inMatch: true, reduced: true, seed: 3, row: false) == nil)
    #expect(
      TournamentNeighbours.want(look: "tournament", inMatch: true, reduced: false, seed: 3, row: true)
        == .init(seed: 3, row: true))
    let n = TournamentNeighbours()
    for look in ["day", "beach", "night", "neon", "minnesota", "bw"] {
      n.want(TournamentNeighbours.want(look: look, inMatch: true, reduced: false, seed: 3, row: false))
      Self.run(n, seconds: 0.2)
    }
    n.want(TournamentNeighbours.want(look: "tournament", inMatch: true, reduced: true, seed: 3, row: false))
    Self.run(n, seconds: 0.2)
    #expect(!n.engineStarted)
    #expect(n.open == nil)
    // the renderer leaves a live field out under Reduce Motion and in another scene (the
    // watcher's wide view, where the fixed pitches beside are in view)
    let size = CGSize(width: 844, height: 390)
    let app = try SceneLooksTests.match("tournament")
    #expect(try app.watchWide(size: size, safe: ScreenInsets()))
    let live = LiveNeighbours(pitches: [])
    func draw(_ look: String, reduced: Bool, _ l: LiveNeighbours?) -> [UInt8] {
      SceneLooksTests.pixels(SceneLooksTests.picture(size) { ctx in
        PitchRenderer.draw(in: ctx, size: size, camera: app.shownCamera, scene: app.scene, look: look, reduced: reduced, neighbours: l)
      })
    }
    #expect(draw("tournament", reduced: true, live) == draw("tournament", reduced: true, nil))
    #expect(draw("day", reduced: false, live) == draw("day", reduced: false, nil))
    #expect(draw("tournament", reduced: false, live) != draw("tournament", reduced: false, nil))
  }

  /// The player's match plays to the same hashes with the neighbours running beside it,
  /// their queue calling their engine while the player's engine plays.
  @Test func thePlayersMatchIsUntouched() throws {
    let options = #"{"mode":"match","seed":11,"cpu":"both","maxTurns":2}"#
    func play(beside n: TournamentNeighbours?) throws -> [String] {
      let e = try Engine(appVersion: "test")
      _ = try e.call("new", json: options)
      var hashes: [String] = []
      for i in 0..<900 {
        _ = try e.call("frame", json: #"{"dt":0.05}"#)
        if let n {
          n.tick(0.05)
          if i % 30 == 0 { n.drain() }
        }
        if i % 10 == 0 { hashes.append(try e.hash()) }
      }
      return hashes
    }
    let alone = try play(beside: nil)
    let n = TournamentNeighbours()
    n.want(.init(seed: 11, row: false))
    let beside = try play(beside: n)
    n.drain()
    #expect(n.live)
    #expect(n.cost.calls > 10)
    #expect(alone == beside)
    n.close()
  }

  /// A neighbour's recording decodes and plays through `Playback`: from the pitch's items
  /// (the thrown piece added at its first pose) to its last poses.
  @Test func aNeighbourRecordingPlaysThroughPlayback() throws {
    let json = #"""
      {"frameDt":0.04,"frames":3,"duration":0.12,"poseScale":1000,
       "projectile":{"id":"baton1","kind":"baton"},
       "bodies":[
        {"id":"baton1","kind":"baton","start":0,"frames":4,"poses":[0,0,600,1000,0,0,0, 0,1000,700,1000,0,0,0, 0,2000,500,1000,0,0,0, 0,3000,22,707,707,0,0],"toppleT":null},
        {"id":"b3","kind":"kubb","team":"B","start":2,"frames":2,"poses":[0,8000,75,1000,0,0,0, 0,8100,35,707,707,0,0],"toppleT":0.1}]}
      """#
    let r = try JSONDecoder().decode(NeighbourRecording.self, from: Data(json.utf8))
    let items = [
      Piece(id: "b3", kind: "kubb", team: "B", x: 0, y: 8, z: 0.075, qw: 1, qx: 0, qy: 0, qz: 0),
      Piece(id: "king", kind: "king", team: nil, x: 0, y: 4, z: 0.15, qw: 1, qx: 0, qy: 0, qz: 0),
    ]
    let pb = Playback(r.recording(items: items))
    let first = pb.pieces(at: 0)
    #expect(first.count == 3)
    let baton = try #require(first.first { $0.id == "baton1" })
    #expect(abs(baton.z - 0.6) < 1e-9 && baton.kind == "baton")
    // halfway between frames 1 and 2
    let mid = pb.pieces(at: 0.06)
    #expect(abs(try #require(mid.first { $0.id == "baton1" }).y - 1.5) < 1e-9)
    // the kubb stays where the items have it until its track starts
    #expect(abs(try #require(mid.first { $0.id == "b3" }).y - 8) < 1e-9)
    let end = pb.pieces(at: r.duration)
    #expect(abs(try #require(end.first { $0.id == "baton1" }).y - 3) < 1e-9)
    #expect(abs(try #require(end.first { $0.id == "b3" }).y - 8.1) < 1e-9)
    #expect(try #require(end.first { $0.id == "king" }).y == 4)
    #expect(pb.feedback.isEmpty)
  }

  /// Team B's view turns the whole field half round about the player's pitch centre.
  @Test func theFieldTurnsForTeamB() {
    var f = NeighbourField()
    f.pitches = [
      .init(
        id: 1, offset: NeighbourPoint(x: 8, y: 12),
        items: [Piece(id: "a1", kind: "kubb", team: "A", x: -2, y: 0, z: 0.075, qw: 1, qx: 0, qy: 0, qz: 0)],
        teams: [:], phase: "rest", at: 0)
    ]
    let plain = f.drawn(at: 0, turned: false)[0], turned = f.drawn(at: 0, turned: true)[0]
    let a = plain.pieces.first { $0.id == "a1" }!, b = turned.pieces.first { $0.id == "a1" }!
    // drawn at (-(ox + x), 8 - (oy + y))
    #expect(plain.dx + a.x == 6 && plain.dy + a.y == 12)
    #expect(turned.dx + b.x == -6 && turned.dy + b.y == -4)
    #expect(abs(b.qz) == 1)
  }
}

/// The live field drawn on a real Tournament match: the thrower's view upright and on its
/// side, Team B's view, and the watcher's wide view, with a neighbour beside mid-throw.
/// `SCENE_LOOKS_OUT=<dir>` keeps each picture; the drawing's cost is printed.
@MainActor struct NeighbourLooksTests {
  /// A field run until pitch 1 or 2 (beside the player's) has a throw half way.
  static func field(row: Bool) -> TournamentNeighbours {
    let n = TournamentNeighbours()
    n.want(.init(seed: 5, row: row))
    NeighbourTests.run(n, seconds: 60) {
      n.field.pitches.prefix(2).contains { p in
        guard let (pb, at) = p.playing else { return false }
        return n.clock - at > pb.recording.duration * 0.35
      }
    }
    return n
  }

  @Test func theLiveFieldIsDrawn() throws {
    let app = try SceneLooksTests.match("tournament")
    let grid = Self.field(row: false), row = Self.field(row: true)
    #expect(grid.live && row.live)
    func draw(_ size: CGSize, _ n: TournamentNeighbours?, turned: Bool = false) -> CGContext {
      SceneLooksTests.picture(size) { ctx in
        PitchRenderer.draw(
          in: ctx, size: size, camera: app.shownCamera, scene: app.scene, look: "tournament",
          neighbours: n?.drawn(turned: turned))
      }
    }
    let up = SceneLooksTests.upright, side = SceneLooksTests.side
    SceneLooksTests.keep(draw(up, grid), "tournament-live-aim")
    SceneLooksTests.keep(draw(side, row), "tournament-live-aim-landscape")
    SceneLooksTests.keep(draw(side, grid), "tournament-live-aim-landscape-grid")
    SceneLooksTests.keep(draw(up, grid, turned: true), "tournament-live-aim-teamB")
    #expect(SceneLooksTests.pixels(draw(up, grid)) != SceneLooksTests.pixels(draw(up, nil)))
    // what the field adds to a frame's drawing, at the phone's 2x
    func cost(_ size: CGSize, _ n: TournamentNeighbours?) -> Double {
      let reps = 30
      var best = Double.infinity
      for _ in 0..<3 {
        let t0 = CACurrentMediaTime()
        for _ in 0..<reps { _ = draw(size, n) }
        best = min(best, (CACurrentMediaTime() - t0) * 1000 / Double(reps))
      }
      return best
    }
    print(String(format: "neighbours draw: upright %.2f ms (fixed %.2f), on its side %.2f ms (fixed %.2f)",
      cost(up, grid), cost(up, nil), cost(side, row), cost(side, nil)))
    #expect(try app.watchWide(size: side, safe: ScreenInsets()))
    SceneLooksTests.keep(draw(side, grid), "tournament-live-wide")
    SceneLooksTests.keep(draw(side, row), "tournament-live-wide-row")
    grid.close()
    row.close()
  }
}
