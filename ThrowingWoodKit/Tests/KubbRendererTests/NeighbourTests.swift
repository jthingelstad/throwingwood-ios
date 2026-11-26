import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
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
    n.want(.init(seed: 5))
    Self.run(n, seconds: 1) { n.live }
    #expect(n.live)
    #expect(n.engineStarted)
    #expect(n.field.pitches.count == 8)
    // the first throw: some pitch's recording starts playing
    Self.run(n, seconds: 30) { n.field.pitches.contains { $0.playing != nil } }
    let thrown = try #require(n.field.pitches.first { $0.playing != nil })
    let (pb, at) = try #require(thrown.playing)
    #expect(pb.recording.duration > 0.2)
    // mid-flight the thrown piece moves; as it leaves no hand holds it, so it is drawn
    // only once it is in the air (Calm.airborne from where it left)
    let mid = n.field.drawn(at: at + pb.recording.duration / 2, turned: false)
    let start = n.field.drawn(at: at, turned: false)
    let id = pb.recording.projectile.id
    let i = try #require(n.field.pitches.firstIndex { $0.id == thrown.id })
    #expect(start[i].pieces.first { $0.id == id } == nil)
    let p0 = try #require(pb.pieces(at: 0).first { $0.id == id })
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
      let w = TournamentNeighbours.want(look: look, inMatch: true, reduced: false, seed: 3)
      #expect((w != nil) == (look == "tournament"), "\(look ?? "nil")")
    }
    #expect(TournamentNeighbours.want(look: "tournament", inMatch: false, reduced: false, seed: 3) == nil)
    #expect(TournamentNeighbours.want(look: "tournament", inMatch: true, reduced: true, seed: 3) == nil)
    // the grid in every layout
    #expect(TournamentNeighbours.want(look: "tournament", inMatch: true, reduced: false, seed: 3) == .init(seed: 3, row: false))
    let n = TournamentNeighbours()
    for look in ["day", "beach", "night", "neon", "minnesota", "bw"] {
      n.want(TournamentNeighbours.want(look: look, inMatch: true, reduced: false, seed: 3))
      Self.run(n, seconds: 0.2)
    }
    n.want(TournamentNeighbours.want(look: "tournament", inMatch: true, reduced: true, seed: 3))
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
    n.want(.init(seed: 11))
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

  /// Kubbs a beat stands up rise one after another rather than pop: from where they lay
  /// (a raise) or from lying where they stand (a fresh pitch set out); batons just go.
  @Test func kubbsRiseRatherThanPop() {
    func kubb(_ id: String, _ x: Double, _ y: Double, lying: Bool) -> Piece {
      lying
        ? Piece(id: id, kind: "kubb", team: "B", x: x, y: y, z: 0.035, qw: 0.7071, qx: 0.7071, qy: 0, qz: 0)
        : Piece(id: id, kind: "kubb", team: "B", x: x, y: y, z: 0.075, qw: 1, qx: 0, qy: 0, qz: 0)
    }
    let before = [kubb("b1", 0, 6, lying: true), kubb("b2", 1, 6, lying: true), kubb("b3", -2, 8, lying: false)]
    let after = [kubb("b1", 0.1, 6, lying: false), kubb("b2", 1, 6.1, lying: false), kubb("b3", -2, 8, lying: false)]
    let rises = Calm.rises(from: before, to: after, at: 10)
    #expect(Set(rises.keys) == ["b1", "b2"])  // the one already standing stays
    let starts = rises.values.map(\.at).sorted()
    #expect(starts == [10, 10 + Calm.stagger])
    var f = NeighbourField()
    f.pitches = [.init(id: 1, offset: NeighbourPoint(x: 8, y: 0), items: before, teams: [:], phase: "rest", at: 0)]
    f.apply([NeighbourEvent(
      id: 1, phase: "raise", at: 10, side: "B", kind: nil, from: nil, recording: nil, items: after, teams: nil, winner: nil)])
    #expect(f.moving(10.2))
    func b1(_ t: Double) -> Piece { f.drawn(at: t, turned: false)[0].pieces.first { $0.id == "b1" }! }
    #expect(Neon.lying(b1(10)))
    let half = b1(10 + Calm.rise / 2)
    #expect(half.z > 0.035 && half.z < 0.075)
    #expect(!Neon.lying(b1(10 + Calm.rise)) && abs(b1(11).z - 0.075) < 1e-9)
    f.settle(12)
    #expect(!f.moving(12) && f.pitches[0].rises.isEmpty)
    // a fresh pitch: every standing kubb rises from lying where it stands, quicker
    let fresh = Calm.rises(from: [], to: [kubb("a1", 0, 0, lying: false), kubb("a2", 1, 0, lying: false)], at: 0, setup: true)
    #expect(fresh["a1"].map { Neon.lying($0.from) && abs($0.from.x) < 1e-9 && $0.length == Calm.setupRise } == true)
    #expect(fresh["a2"]?.at == Calm.setupStagger)
    // any other beat that carries items just changes them
    #expect(Calm.rises(from: [], to: after, at: 0).isEmpty)
  }

  /// No person is drawn at the Tournament, live or fixed, in any phase of a neighbour's
  /// match: the picture has no pixel of the people's skin or trousers (the colours the
  /// figures were drawn in, the web's palette.js TOURNAMENT.person).
  @Test func noPersonIsDrawnAtTheTournament() throws {
    let app = try SceneLooksTests.match("tournament")
    let n = TournamentNeighbours()
    n.want(.init(seed: 5))
    let skin: (UInt8, UInt8, UInt8) = (0xe9, 0xc3, 0x9b), trousers: (UInt8, UInt8, UInt8) = (0x2f, 0x3a, 0x4a)
    var phases = Set<String>()
    func count(_ size: CGSize, _ live: LiveNeighbours?, reduced: Bool = false) -> Int {
      let px = SceneLooksTests.pixels(SceneLooksTests.picture(size) { ctx in
        PitchRenderer.draw(
          in: ctx, size: size, camera: app.shownCamera, scene: app.scene, look: "tournament", reduced: reduced,
          neighbours: live)
      })
      var hits = 0
      for i in stride(from: 0, to: px.count - 3, by: 4) {
        let c = (px[i], px[i + 1], px[i + 2])
        if c == skin || c == trousers { hits += 1 }
      }
      return hits
    }
    for _ in 0..<12 {
      NeighbourTests.run(n, seconds: 20)
      phases.formUnion(n.field.pitches.map(\.phase))
      #expect(count(SceneLooksTests.upright, n.drawn(turned: false)) == 0)
      #expect(count(SceneLooksTests.side, n.drawn(turned: false)) == 0)
    }
    #expect(phases.count >= 3, "\(phases)")
    // the fixed pitches (Reduce Motion, before the field answers) and the wide view
    #expect(count(SceneLooksTests.upright, nil, reduced: true) == 0)
    #expect(try app.watchWide(size: SceneLooksTests.side, safe: ScreenInsets()))
    #expect(count(SceneLooksTests.side, n.drawn(turned: false)) == 0)
    n.close()
  }

  /// The neighbours' sounds (the web's neighbour-sound.js, from engine 0.16.0's `hits` and
  /// `landing`): a knock at each body's first hit, as loud as it was hard, a louder one for
  /// the king, a quiet tap for a kubb left standing, a softer, lower one where the thrown
  /// piece lands; quieter with distance (the pitch beside about 10 dB under the player's knock,
  /// the far row fainter), panned by where the pitch lies, at most `voices` at once (the
  /// faintest dropped), silent round the player's own knock and when the field is not live.
  @Test func neighbourSoundsAreQuietFarAndCapped() throws {
    let json = #"""
      {"frameDt":0.04,"frames":5,"duration":0.2,"poseScale":1000,
       "projectile":{"id":"baton1","kind":"baton"},
       "bodies":[
        {"id":"baton1","kind":"baton","start":0,"frames":5,"poses":[0,0,1200,1000,0,0,0, 0,2000,900,1000,0,0,0, 0,4000,400,1000,0,0,0, 0,6000,30,1000,0,0,0, 0,6200,22,1000,0,0,0]},
        {"id":"b3","kind":"kubb","team":"B","start":3,"frames":2,"poses":[0,8000,75,1000,0,0,0, 0,8100,35,707,707,0,0],"toppleT":0.14},
        {"id":"b4","kind":"kubb","team":"B","start":3,"frames":1,"poses":[0,8000,75,1000,0,0,0]},
        {"id":"king","kind":"king","start":4,"frames":1,"poses":[0,4000,150,1000,0,0,0],"toppleT":0.18}],
       "hits":[{"t":0.13,"id":"b3","strength":0.6},{"t":0.135,"id":"b4","strength":0.2},
               {"t":0.15,"id":"b3","strength":1},{"t":0.17,"id":"king","strength":1},
               {"t":0.16,"id":"baton1","strength":0.5}],
       "landing":{"t":0.11,"strength":0.4}}
      """#
    let r = try JSONDecoder().decode(NeighbourRecording.self, from: Data(json.utf8))
    let cues = NeighbourSounds.cues(r, at: 100)
    // engine 0.16.0's `hits` and `landing` (the web's rule): the landing at `landing.t`;
    // each body once, at its first hit (b3's second hit is not heard again); b3 toppled, as
    // loud as its hit was hard; b4, struck and left standing, a tap at 0.45 of that; the
    // king 1.5 times; nothing for the thrown piece's own contact
    #expect(cues.map(\.kind) == [.land, .hit, .tap, .king])
    #expect(zip(cues.map(\.time), [100.11, 100.13, 100.135, 100.17]).allSatisfy { abs($0 - $1) < 1e-9 })
    let lv = cues.map(\.level)
    #expect(abs(lv[0] - (0.35 + 0.65 * 0.4)) < 1e-12)
    #expect(abs(lv[1] - (0.35 + 0.65 * 0.6)) < 1e-12)
    #expect(abs(lv[2] - (0.35 + 0.65 * 0.2) * 0.45) < 1e-12)
    #expect(lv[3] == 1)
    #expect(abs(NeighbourSounds.gain(distance: 8, kind: .king, level: 1) - 0.22 * 1.5) < 1e-12)
    #expect(abs(NeighbourSounds.gain(distance: 8, kind: .tap, level: lv[2]) - 0.22 * lv[2]) < 1e-12)
    #expect(NeighbourSound(kind: .tap, gain: 0.1, pan: 0).rate > NeighbourSound(kind: .hit, gain: 0.1, pan: 0).rate)
    // a recording without them (none struck, no landing listed) still knocks at a topple
    let bare = #"""
      {"frameDt":0.04,"frames":1,"duration":0.2,"poseScale":1000,"projectile":{"id":"baton1","kind":"baton"},
       "bodies":[{"id":"b2","kind":"kubb","start":0,"frames":1,"poses":[0,8000,35,707,707,0,0],"toppleT":0.1}]}
      """#
    let old = NeighbourSounds.cues(try JSONDecoder().decode(NeighbourRecording.self, from: Data(bare.utf8)), at: 0)
    #expect(old == [NeighbourCue(time: 0.1, kind: .hit)])
    // levels: the web's, against the player's own 0.8 x 0.9
    let own = 0.8 * 0.9
    #expect(NeighbourSounds.gain(distance: 8, kind: .hit) == 0.22)
    #expect(abs(NeighbourSounds.gain(distance: hypot(8, 12), kind: .hit) - 0.22 * pow(8 / hypot(8, 12), 1.5)) < 1e-12)
    #expect(NeighbourSounds.gain(distance: 8, kind: .king) < own)
    #expect(NeighbourSounds.gain(distance: 8, kind: .land) < NeighbourSounds.gain(distance: 8, kind: .hit))
    #expect(NeighbourSounds.gain(distance: 12, kind: .hit) < NeighbourSounds.gain(distance: 8, kind: .hit) * 0.6)
    #expect(NeighbourSounds.gain(distance: 60, kind: .land) == 0)  // under the floor: not played
    #expect(NeighbourSound(kind: .land, gain: 0.1, pan: 0).rate < NeighbourSound(kind: .hit, gain: 0.1, pan: 0).rate)
    // left and right as the camera looks
    let app = try SceneLooksTests.match("tournament")
    #expect(NeighbourSounds.pan(x: -8, y: 4, camera: app.camera) < -0.3)
    #expect(NeighbourSounds.pan(x: 8, y: 4, camera: app.camera) > 0.3)
    // at most `voices`: a free voice, else the faintest when the new one is louder
    #expect(NeighbourSounds.voice(gains: [0.1, nil, 0.2], gain: 0.05) == 1)
    #expect(NeighbourSounds.voice(gains: [0.1, 0.05, 0.2], gain: 0.08) == 1)
    #expect(NeighbourSounds.voice(gains: [0.1, 0.05, 0.2], gain: 0.04) == nil)
    // a live field: its cues come due on its clock, each once; quiet round the player's
    // own knock; none once closed
    let n = TournamentNeighbours()
    n.want(.init(seed: 5))
    var heard: [NeighbourSound] = []
    for _ in 0..<(60 * 40) {
      n.tick(1.0 / 60)
      n.drain()
      heard += n.sounds(session: app)
    }
    #expect(!heard.isEmpty)
    #expect(heard.allSatisfy { $0.gain <= NeighbourSounds.near * NeighbourSounds.king && $0.gain < own })
    app.knockAge = 0
    var quiet: [NeighbourSound] = []
    for _ in 0..<(60 * 40) {
      n.tick(1.0 / 60)
      n.drain()
      app.knockAge = 0  // the player's own knock, sounding all along
      quiet += n.sounds(session: app)
    }
    #expect(quiet.isEmpty)
    n.close()
    n.tick(1.0 / 60)
    #expect(n.sounds(session: app).isEmpty)
    // Reduce Motion and other scenes: no field, so no sound
    #expect(TournamentNeighbours.want(look: "tournament", inMatch: true, reduced: true, seed: 5) == nil)
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
  static func field() -> TournamentNeighbours {
    let n = TournamentNeighbours()
    n.want(.init(seed: 5))
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
    // the grid in every layout, upright and on its side
    let grid = Self.field()
    #expect(grid.live)
    func draw(_ size: CGSize, _ n: TournamentNeighbours?, turned: Bool = false) -> CGContext {
      SceneLooksTests.picture(size) { ctx in
        PitchRenderer.draw(
          in: ctx, size: size, camera: app.shownCamera, scene: app.scene, look: "tournament",
          neighbours: n?.drawn(turned: turned))
      }
    }
    let up = SceneLooksTests.upright, side = SceneLooksTests.side
    SceneLooksTests.keep(draw(up, grid), "tournament-live-aim")
    SceneLooksTests.keep(draw(side, grid), "tournament-live-aim-landscape")
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
      cost(up, grid), cost(up, nil), cost(side, grid), cost(side, nil)))
    #expect(try app.watchWide(size: side, safe: ScreenInsets()))
    SceneLooksTests.keep(draw(side, grid), "tournament-live-wide")
    grid.close()
  }
}

/// The live field turns with the frame the board draws in, decided in one place
/// (`PitchSession.viewFrame(of:)`): the thrower's for an aim, the defender's for a raise or
/// a punishment kubb, the match's own for a finished one, reopened or not.
@MainActor struct NeighbourFrameTests {
  static func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/solo/\(name)", withExtension: "json"))
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The frame the pitch itself is drawn in, read from its pieces, not from the session:
  /// a team's base kubbs still on a baseline stand on the near one (y 0) in that team's
  /// frame and on the far one (y 8) in the other's. nil when no base kubb says.
  static func pitchFrame(_ items: [Piece]) -> String? {
    var a = 0, b = 0
    for p in items where p.kind == "kubb" && abs(p.x) <= 2.6 {
      let near = abs(p.y) < 0.35, far = abs(p.y - 8) < 0.35
      guard near || far, let team = p.team else { continue }
      if (team == "A") == near { a += 1 } else { b += 1 }
    }
    return a == b ? nil : (a > b ? "A" : "B")
  }

  /// The field's frame agrees with what the board draws: by the pieces for an aim or a
  /// finished match, and by where the work is for a raise (the kubb lies in the raiser's
  /// own half, nearer its baseline) or a punishment kubb (it goes in that half).
  static func agree(_ app: PitchSession, _ label: String) throws {
    let n = try #require(app.need, "\(label)")
    let field = app.scene.frameSide ?? "A"
    #expect(app.scene.neighboursTurned == (field == "B"), "\(label)")
    switch n.kind {
    case "raise":
      #expect(field == n.side, "\(label): raise in \(n.side ?? "?")'s frame, field \(field)")
      #expect(try #require(n.pose).y < 4, "\(label)")
    case "punish":
      #expect(field == n.side, "\(label): punish in \(n.side ?? "?")'s frame, field \(field)")
      let b = try #require(n.bounds)
      #expect(b.yMin >= -0.05 && b.yMax <= 4.05, "\(label)")
    default:
      if let seen = pitchFrame(app.scene.items) { #expect(field == seen, "\(label): pitch in \(seen)'s frame, field \(field)") }
    }
  }

  /// A match walked from a raise through every raise and punishment kubb to the next
  /// throws, the computer's included: the field's frame is the pitch's at every view.
  @Test func theFieldTurnsWithEveryScreen() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(Self.fixture("raise"), save: nil)
    let size = CGSize(width: 390, height: 844)
    var seen = Set<String>()
    var throwsSeen = 0
    for step in 0..<20000 {
      let n = try #require(app.need)
      if !app.playing {
        try Self.agree(app, "step \(step) \(n.kind) \(n.side ?? "-")")
        seen.insert("\(n.kind) \(n.side ?? "-")")
      }
      if n.kind == "raise", !app.playing {
        let i = try #require(n.ends?.firstIndex { $0.ok != false })
        #expect(try app.raiseTap(i))
      } else if n.kind == "punish", !app.playing {
        let b = try #require(n.bounds)
        // try spots across the allowed ground until one is legal
        var placed = false
        for y in stride(from: b.yMin + 0.3, through: b.yMax - 0.1, by: 0.4) where !placed {
          for x in stride(from: b.xMin + 0.2, through: b.xMax - 0.2, by: 0.5) where !placed {
            guard let at = app.groundPoint(x: x, y: y, in: size) else { continue }
            try app.movePunishment(to: at, size: size)
            if app.placement?.ok == true {
              try app.placePunishment()
              placed = true
            }
          }
        }
        #expect(placed)
      } else if n.kind == "throw", n.cpu != true, !app.playing {
        throwsSeen += 1
        if throwsSeen > 1 { break }
        // the person's throw: the engine plays it for this test
        _ = try app.engine.call("setControl", json: #"{"sides":[],"cpu":true}"#)
        try app.adopt(app.read("view"))
      } else if n.kind == "over" {
        break
      } else {
        try app.tick(1.0 / 60)
      }
    }
    // the raises and the punishment kubb in Team A's frame, the computer's throw in Team
    // B's and the person's next in Team A's
    #expect(seen.isSuperset(of: ["raise A", "punish A", "throw B", "throw A"]), "\(seen.sorted())")
  }

  /// A finished match whose last throw was Team B's, reopened: on a fresh launch, and on
  /// a session that showed a Team A pitch before. The field is in Team B's frame, as the
  /// engine restores the pitch.
  @Test func aFinishedMatchReopensInItsOwnFrame() throws {
    let over = try Self.fixture("over")
    for before in [nil, "aim"] {
      let app = try PitchSession(appVersion: "test")
      if let before { try app.restore(Self.fixture(before), save: nil) }
      try app.restore(over, save: nil)
      #expect(app.need?.kind == "over")
      #expect(app.scene.frameSide == "B", "after \(before ?? "a fresh launch")")
      #expect(Self.pitchFrame(app.scene.items) == "B")
      #expect(app.scene.neighboursTurned)
      try Self.agree(app, "over after \(before ?? "launch")")
      // a practice after it is Team A's again; the wide view is never turned
      try app.practice(scene: "tournament")
      #expect(app.scene.frameSide == nil && !app.scene.neighboursTurned)
    }
    let app = try PitchSession(appVersion: "test")
    try app.restore(over, save: nil)
    #expect(try app.watchWide(size: CGSize(width: 844, height: 390), safe: ScreenInsets()))
    #expect(!app.scene.neighboursTurned)
  }
}

extension NeighbourFrameTests {
  /// A watcher (no side, the wide view on) at Team B's raise and punishment kubb: those
  /// scenes keep their close camera on the need's poses, which the engine gives in the
  /// defender's frame in every view, so the field turns with them; the rest of the wide
  /// view is the world frame.
  @Test func aWatchedRaiseTurnsWithTheDefender() throws {
    func options(_ cpu: String, _ raising: String) -> String {
      #"{"mode":"match","seed":5,"cpu":\#(cpu),"raising":"\#(raising)","first":"A","start":{"year":2026,"month":11,"day":19,"hour":9,"min":0},"teams":{"A":{"name":"North","players":[{"name":"North"}]},"B":{"name":"South","players":[{"name":"South"}]}}}"#
    }
    // the computer's throws for both sides, then a match that raises by hand played with them
    let cpu = try Engine(appVersion: "test")
    _ = try cpu.call("new", json: options(#""both""#, "auto"))
    var acts: [String] = []
    for _ in 0..<200_000 where acts.count < 80 {
      let out = try JSONNode.parse(cpu.call("frame", json: #"{"dt":0.05}"#))
      if let a = out["action"], !a.isNull { acts.append(a.raw.text) }
      if out["need"]?["kind"]?.string == "over" { break }
    }
    let prep = try Engine(appVersion: "test")
    _ = try prep.call("new", json: options("[]", "hand"))
    var k = 0
    var watched = Set<String>()
    let side = CGSize(width: 844, height: 390)
    for _ in 0..<800 where watched.count < 2 {
      let need = try JSONNode.parse(prep.call("view"))["need"]
      let kind = need?["kind"]?.string, who = need?["side"]?.string
      if (kind == "raise" || kind == "punish"), who == "B", !watched.contains(kind!) {
        // a watcher's board at this moment: no side, the wide view on
        let app = try PitchSession(appVersion: "test")
        try app.restore(prep.call("snapshot"), save: nil)
        _ = try app.engine.call("setControl", json: #"{"sides":[],"cpu":false}"#)
        app.watching = true
        _ = try app.watchWide(size: side, safe: ScreenInsets())
        try app.adopt(app.read("view"))
        // a raise on the engine's held camera (1.4.0) or the punishment's close one
        #expect(app.scene.wide && (app.scene.stillZoom != nil || app.scene.heldRaise == true), "\(kind!)")
        #expect(app.scene.frameSide == "B" && app.scene.neighboursTurned, "watched \(kind!)")
        try Self.agree(app, "watched \(kind!) B")
        watched.insert(kind!)
      }
      switch kind {
      case "throw":
        guard k < acts.count else { break }
        _ = try prep.call("apply", json: acts[k])
        k += 1
      case "raise": _ = try prep.call("apply", json: #"{"type":"raise"}"#)
      case "punish":
        let c = try #require(need?["cursor"])
        _ = try prep.call("apply", json: #"{"type":"punish","x":\#(c["x"]!.double!),"y":\#(c["y"]!.double!)}"#)
      default: break
      }
    }
    #expect(watched.contains("raise"), "\(watched)")
    // a watched aim in the wide view is the world frame, never turned
    let app = try PitchSession(appVersion: "test")
    try app.restore(prep.call("snapshot"), save: nil)
    app.watching = true
    _ = try app.watchWide(size: side, safe: ScreenInsets())
    if app.need?.kind == "throw" { #expect(!app.scene.neighboursTurned) }
  }
}
