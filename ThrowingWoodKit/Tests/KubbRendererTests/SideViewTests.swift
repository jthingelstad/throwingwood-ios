import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// The view from the player's side (engine 1.4.0, `setView {side, box}`) and a raise in any
/// order (`need.lying`, the held raise camera).
@MainActor struct SideViewTests {
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  /// The box the engine fits its end and raise cameras to stays inside the safe area,
  /// under the header and over the raise panel, on every review phone, both ways.
  @Test func theBoxIsInsideTheScreen() {
    for p in WideLayoutTests.phones + [(name: "16e upright", size: CGSize(width: 375, height: 667), safe: ScreenInsets(top: 20))] {
      let w = p.size.width, h = p.size.height
      let k = min(w / 400, h / 240)
      let ox = (w - 400 * k) / 2, oy = (h - 240 * k) / 2
      let b = SideView.box(size: p.size, safe: p.safe)
      let left = CGFloat(b.left) * k + ox, right = CGFloat(b.right) * k + ox
      let top = CGFloat(b.top) * k + oy, bottom = CGFloat(b.bottom) * k + oy
      #expect(left >= p.safe.left && right <= w - p.safe.right, "\(p.name)")
      #expect(top >= p.safe.top + SideView.headerRoom - 1e-6, "\(p.name)")
      #expect(bottom <= h - p.safe.bottom, "\(p.name)")
      #expect(bottom - top > 100, "\(p.name): room for the pitch")
    }
  }

  /// A solo match: the player's own throw keeps the thrower's camera; the computer's is
  /// seen from the player's end (the engine's "end" camera); a watcher keeps the wide view.
  @Test func theComputersThrowsAreSeenFromThePlayersEnd() throws {
    let size = CGSize(width: 390, height: 844), safe = ScreenInsets(top: 47, bottom: 34)
    let mine = try PitchSession(appVersion: "test")
    try mine.restore(fixture("aim"), save: nil)
    #expect(mine.handoff != nil)
    mine.dismissHandoff()
    mine.sideView(size: size, safe: safe)
    #expect(mine.camera.kind != "end" && mine.need?.cpu != true)
    // the card put away stays away when the camera moves (the first frame, a turn of the phone)
    #expect(mine.handoff == nil)
    mine.sideView(size: CGSize(width: 844, height: 390), safe: ScreenInsets(left: 47, bottom: 21, right: 47))
    #expect(mine.handoff == nil)
    let cpu = try PitchSession(appVersion: "test")
    try cpu.restore(fixture("computer"), save: nil)
    #expect(cpu.need?.cpu == true)
    cpu.sideView(size: size, safe: safe)
    #expect(cpu.camera.kind == "end")
    // the same screen again sends nothing new
    let hash = try cpu.engine.hash()
    cpu.sideView(size: size, safe: safe)
    #expect(try cpu.engine.hash() == hash && cpu.camera.kind == "end")
    // a watcher has no side: the engine's own view
    let watcher = try PitchSession(appVersion: "test")
    try watcher.restore(fixture("computer"), save: nil)
    watcher.watching = true
    watcher.sideView(size: size, safe: safe)
    #expect(watcher.camera.kind != "end")
  }

  /// A throw this device aims for the other side (a host standing in for a player who
  /// left) is seen from the thrower's end, since the aim calls take the thrower's frame;
  /// the next throw of the player's own side's is from the player's end again.
  @Test func aStandInThrowIsSeenFromTheThrowersEnd() throws {
    let size = CGSize(width: 390, height: 844), safe = ScreenInsets(top: 47, bottom: 34)
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    let other = try #require(app.need?.side)
    let own = other == "A" ? "B" : "A"
    app.playerSide = { own }
    app.dismissHandoff()
    app.acceptsInput = true
    #expect(app.need?.kind == "throw" && app.need?.cpu != true)
    app.sideView(size: size, safe: safe)
    #expect(app.sideViewOn && app.camera.kind != "end")
    // without the stand-in's hand the same throw is the other side's, from the player's end
    app.acceptsInput = false
    app.sideView(size: size, safe: safe)
    #expect(app.camera.kind == "end")
  }

  /// The computer's throw seen from the player's end is drawn in the player's frame: the
  /// recording's poses are the thrower's, so the pieces come from the engine's `showAt`,
  /// turned (core/frame: (x, y) -> (-x, 8 - y)), as the wide view's do.
  @Test func theComputersThrowIsDrawnOnThePlayersPitch() throws {
    func firstFrame(side: Bool) throws -> [String: Piece] {
      let app = try PitchSession(appVersion: "test")
      try app.restore(fixture("computer"), save: nil)
      if side { app.sideView(size: CGSize(width: 390, height: 844), safe: ScreenInsets(top: 47, bottom: 34)) }
      #expect(app.sideViewOn == side)
      for _ in 0..<2000 where !app.playing {
        app.dismissHandoff()
        try app.tick(1.0 / 60)
      }
      try #require(app.playing && app.playbackCpu)
      return Dictionary(app.scene.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    let thrower = try firstFrame(side: false), player = try firstFrame(side: true)
    #expect(!thrower.isEmpty && Set(thrower.keys) == Set(player.keys))
    for (id, a) in thrower {
      let b = try #require(player[id])
      #expect(abs(b.x + a.x) < 1e-6 && abs(b.y - (8 - a.y)) < 1e-6, "\(id)")
    }
  }

  /// The held raise camera on a phone on its side with a tall bar (the largest text sizes):
  /// the scene moves up by any shortfall, so every lying kubb, the one picked and its ends
  /// stay above the bar, visible and touchable (WideLayout.stillLift).
  @Test func aTallBarNeverCoversTheHeldRaise() throws {
    let size = CGSize(width: 844, height: 390), safe = ScreenInsets(left: 47, bottom: 21, right: 47)
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    _ = try app.engine.call("setControl", json: #"{"sides":["A","B"],"cpu":false}"#)
    try app.adopt(app.read("view"))
    app.sideView(size: size, safe: safe)
    try #require(app.scene.heldRaise == true)
    for floor in [96.0, 140, 170, 280] {
      app.stillFloor = floor
      let top = size.height - floor
      let shapes = app.lyingShapes(in: size).map(\.shape)
      let picked = try #require(app.raiseGeometry(in: size))
      for s in shapes + [picked] {
        for p in s.outline { #expect(p.y <= top + 0.5, "bar \(floor): \(p.y) under \(top)") }
      }
      for e in app.raiseEnds(in: size) { #expect(e.label.y + RaiseTouch.numberR <= top + 0.5, "bar \(floor)") }
    }
  }

  /// A raise in any order: the other lying kubbs are drawn to pick, a tap on one picks
  /// it (its ends and numbers move to it), and VoiceOver can pick each by name.
  @Test func anyLyingKubbMayBeRaisedNext() throws {
    let size = CGSize(width: 390, height: 844), safe = ScreenInsets(top: 47, bottom: 34)
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    _ = try app.engine.call("setControl", json: #"{"sides":["A","B"],"cpu":false}"#)
    try app.adopt(app.read("view"))
    app.sideView(size: size, safe: safe)
    app.acceptsInput = true
    let need = try #require(app.need)
    let lying = try #require(need.lying)
    try #require(lying.count > 1)
    #expect(need.camera != nil && app.scene.heldRaise == true)
    let first = try #require(app.raiseNeed?.kubb)
    let others = app.lyingShapes(in: size)
    // no number covers a kubb still to pick (this fixture's next kubb lies where end 2's
    // number would go)
    let clearance = RaiseTouch.numberR + 8 - 0.01
    for o in others {
      let c = CGPoint.between(o.shape.caps[0], o.shape.caps[1], 0.5)
      for e in app.raiseEnds(in: size) { #expect(e.label.distance(to: c) >= clearance * 0.9, "\(o.id)") }
    }
    #expect(others.count == lying.count - 1 && !others.contains { $0.id == first })
    #expect(app.otherLyingNames().count == others.count)
    // a tap on the picked kubb itself picks nothing
    let g = try #require(app.raiseGeometry(in: size))
    #expect(try app.pickLying(at: .between(g.caps[0], g.caps[1], 0.5), size: size) == nil)
    // a tap on another picks it, and sends nothing
    let hash = try app.engine.hash()
    let next = try #require(others.first)
    let at = CGPoint.between(next.shape.caps[0], next.shape.caps[1], 0.5)
    #expect(try app.pickLying(at: at, size: size) != nil)
    let unsent = try app.engine.hash()
    #expect(app.raiseNeed?.kubb == next.id && unsent == hash)
    // its numbers are apart enough to tell which is which
    let ends = app.raiseEnds(in: size)
    let gap = RaiseTouch.numberR * 2 + 4
    #expect(ends.count == 2 && ends[0].label.distance(to: ends[1].label) >= gap)
    // and VoiceOver picks the first one back by its id
    try app.pickLying(id: first)
    #expect(app.raiseNeed?.kubb == first)
    // standing it sends the raise of the kubb picked, on an end the rules allow
    let i = try #require(app.raiseEnds(in: size).firstIndex { $0.ok })
    #expect(try app.raiseTap(i))
    #expect(try app.engine.hash() != hash)
  }

  /// A team-mate's AUTO (a raise naming no kubb) is watched on the engine's first kubb,
  /// not the one this device had picked (Codex on PR #61).
  @Test func anArrivingRaiseNamingNoKubbIsTheEnginesFirst() throws {
    let size = CGSize(width: 390, height: 844), safe = ScreenInsets(top: 47, bottom: 34)
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    _ = try app.engine.call("setControl", json: #"{"sides":["A","B"],"cpu":false}"#)
    try app.adopt(app.read("view"))
    app.sideView(size: size, safe: safe)
    app.acceptsInput = true
    let first = try #require(app.need?.kubb)
    let other = try #require(app.lyingShapes(in: size).first)
    try app.pickLying(id: other.id)
    #expect(app.raiseNeed?.kubb == other.id)
    _ = app.raiseEnd(of: JSONText(#"{"type":"raise"}"#))
    #expect(app.raiseNeed?.kubb == first)
    // one naming its kubb is watched on that kubb
    _ = app.raiseEnd(of: JSONText(#"{"type":"raise","kubb":"\#(other.id)"}"#))
    #expect(app.raiseNeed?.kubb == other.id)
  }

  /// AUTO with another kubb picked raises that kubb, on the engine's end: it names the
  /// kubb (the web's game.raise), where a raise naming none would stand the engine's first.
  @Test func autoRaisesTheKubbPicked() throws {
    let size = CGSize(width: 390, height: 844), safe = ScreenInsets(top: 47, bottom: 34)
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    _ = try app.engine.call("setControl", json: #"{"sides":["A","B"],"cpu":false}"#)
    try app.adopt(app.read("view"))
    app.sideView(size: size, safe: safe)
    app.acceptsInput = true
    let other = try #require(app.lyingShapes(in: size).first)
    let first = try #require(app.need?.kubb)
    try app.pickLying(id: other.id)
    try app.raiseWatched()
    #expect(app.raiseShowing)
    for _ in 0..<600 where app.raiseShowing { try app.tick(1.0 / 30) }
    // the kubb picked stands; the engine's first still lies
    let lying = (app.need?.lying ?? []).map(\.id)
    #expect(!app.raiseShowing && app.need?.kind == "raise")
    #expect(!lying.contains(other.id) && lying.contains(first))
  }

  /// A watched raise (AUTO here) keeps the per-kubb camera, close enough to see the kubb
  /// tip up: the held camera is for raising by hand (Codex on PR #61).
  @Test func aWatchedRaiseKeepsTheCloseCamera() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    app.sideView(size: CGSize(width: 390, height: 844), safe: ScreenInsets(top: 47, bottom: 34))
    #expect(app.scene.heldRaise == true)
    try app.raiseWatched()
    #expect(app.raiseShowing)
    #expect(app.scene.heldRaise != true && app.scene.stillZoom != nil && app.camera.kind != "raise")
  }

  /// A watcher on a tall screen keeps the free camera: the wide view's own camera there
  /// is of kind "end" too (Codex on PR #61).
  @Test func aWatcherUprightKeepsTheFreeCamera() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("computer"), save: nil)
    app.watching = true
    let size = CGSize(width: 375, height: 667), safe = ScreenInsets(top: 20)
    app.sideView(size: size, safe: safe)
    #expect(try app.watchWide(size: size, safe: safe))
    #expect(app.wideOn && app.freeOn)
  }

  /// A number on another lying kubb moves both square to their line, the same way, keeping
  /// their order along it.
  @Test func numbersStepOffAnotherKubb() {
    let e = { (i: Int, l: CGPoint) in
      RaiseEndPoint(index: i, which: i + 1, footprint: l, label: l, ok: true, lit: false, why: nil)
    }
    let ends = [e(0, CGPoint(x: 100, y: 100)), e(1, CGPoint(x: 140, y: 100))]
    let other = CGPoint(x: 141, y: 102)
    let out = RaiseTouch.clear(ends, of: [other])
    let r = RaiseTouch.numberR + 8 - 0.01
    #expect(out.allSatisfy { $0.label.distance(to: other) >= r })
    #expect(out[0].label.y == out[1].label.y && out[0].label.y < 100, "up the screen, together")
    #expect(out[0].label.x == 100 && out[1].label.x == 140)
    // nothing near: nothing moves
    #expect(RaiseTouch.clear(ends, of: [CGPoint(x: 300, y: 300)]).map(\.label) == ends.map(\.label))
  }

  /// Two numbers drawn on one spot are pushed apart along the kubb.
  @Test func numbersOnOneSpotArePushedApart() {
    let e = { (i: Int, l: CGPoint, f: CGPoint) in
      RaiseEndPoint(index: i, which: i + 1, footprint: f, label: l, ok: true, lit: false, why: nil)
    }
    let same = CGPoint(x: 100, y: 100)
    let out = RaiseTouch.apart([e(0, same, CGPoint(x: 98, y: 100)), e(1, same, CGPoint(x: 102, y: 100))])
    let gap = RaiseTouch.numberR * 2 + 4
    #expect(out[0].label.distance(to: out[1].label) >= gap)
    #expect(out[0].label.x < out[1].label.x && abs(out[0].label.y - 100) < 1e-9)
    // numbers already apart stay where they are
    let far = [e(0, CGPoint(x: 0, y: 0), .zero), e(1, CGPoint(x: 200, y: 0), .zero)]
    #expect(RaiseTouch.apart(far).map(\.label) == far.map(\.label))
  }
}
