import Foundation
import KubbEngine
import KubbPitch
import Testing
import simd

@testable import KubbRenderer

/// A watched raise online, every row of docs/ONLINE.md "A watched raise online": what each
/// kind of watch allows (RaiseWatch), what the seat decides with it (Seat.decide), and the
/// board going through the states.
@MainActor struct RaiseWatchTests {
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  @Test func eachWatchAllowsWhatTheTableSays() {
    // (blocks input, seat may act, holds an unsent action, remote aim, banner, applies incoming)
    let table: [(RaiseWatch, Bool, Bool, Bool, Bool, Bool, Bool)] = [
      (.none, false, true, false, true, true, true),
      (.ownLeadIn, true, true, true, false, false, false),
      (.ownTipping, true, true, false, false, false, false),
      (.arriving, true, false, false, false, false, false),
      (.engine, true, false, false, false, false, false),
    ]
    for (w, input, seat, unsent, aim, banner, incoming) in table {
      #expect(w.blocksInput == input, "\(w)")
      #expect(w.seatMayAct == seat, "\(w)")
      #expect(w.holdsUnsentAction == unsent, "\(w)")
      #expect(w.drawsRemoteAim == aim, "\(w)")
      #expect(w.showsBanner == banner, "\(w)")
      #expect(w.appliesIncoming == incoming, "\(w)")
    }
  }

  private func decide(
    _ w: RaiseWatch, mayAct: Bool = true, writing: Bool = false, queueEmpty: Bool = true, current: Bool = true
  ) -> Seat {
    Seat.decide(
      current: current, writing: writing, queueEmpty: queueEmpty, starting: false, caughtUpSeq: true,
      mayAct: mayAct, watch: w)
  }

  /// The seat's decision for every row with an outcome.
  @Test func theSeatFollowsTheTable() {
    // nothing watched: as before
    #expect(decide(.none) == Seat(caughtUp: true, acceptsInput: true, dropUnsentRaise: false, banner: false))
    #expect(decide(.none, mayAct: false).banner)
    // Codex on PR #46: a shout or a member's coming and going during this device's own
    // lead-in seats again; the raise it scheduled keeps its authority and is sent
    #expect(decide(.ownLeadIn) == Seat(caughtUp: true, acceptsInput: true, dropUnsentRaise: false, banner: false))
    // the authority truly lost (moved off the team, the seat changed, the pitch gone):
    // the unsent raise is dropped before it is applied
    #expect(decide(.ownLeadIn, mayAct: false).dropUnsentRaise)
    #expect(decide(.ownLeadIn, current: false).dropUnsentRaise)
    // another member's action arrived during it: the match moved on, so it is dropped too
    #expect(decide(.ownLeadIn, queueEmpty: false).dropUnsentRaise)
    // its action sent and being written: input waits for the write; nothing to drop
    #expect(decide(.ownTipping, writing: true) == Seat(caughtUp: false, acceptsInput: false, dropUnsentRaise: false, banner: false))
    #expect(decide(.ownTipping).acceptsInput)
    // another member's raise, or the engine's: nothing may act on the need shown, no banner
    for w in [RaiseWatch.arriving, .engine] {
      #expect(decide(w) == Seat(caughtUp: false, acceptsInput: false, dropUnsentRaise: false, banner: false), "\(w)")
      #expect(!decide(w, mayAct: false).banner, "\(w)")
    }
  }

  /// This device's own AUTO ALL, its actions captured where OnlinePitch would submit them:
  /// lead-in (nothing sent), tipping (its action sent once), between kubbs (nothing
  /// watched), the next kubb straight to tipping (no lead-in after the first).
  @Test func anOwnRaiseGoesThroughItsStates() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    var sent: [String] = []
    app.onlineAction = { sent.append($0.text) }
    app.raiseRest()
    try app.tick(0.02)
    #expect(app.raiseWatch == .ownLeadIn && sent.isEmpty)
    var seen: [RaiseWatch] = [app.raiseWatch]
    for _ in 0..<200 where app.need?.kind == "raise" {
      try app.tick(0.02)
      if seen.last != app.raiseWatch { seen.append(app.raiseWatch) }
    }
    #expect(seen == [.ownLeadIn, .ownTipping, .none, .ownTipping, .none], "\(seen)")
    // engine 1.4: each names the kubb it raises, the engine's next (the web's game.raise)
    #expect(sent == [#"{"type":"raise","kubb":"b1"}"#, #"{"type":"raise","kubb":"b2"}"#], "\(sent)")
  }

  /// The unsent raise dropped (authority lost) and a resync during the lead-in: nothing
  /// sent, the engine untouched, the kubb lying; once sent, nothing is dropped.
  @Test func anUnsentRaiseIsDroppedCleanly() throws {
    for ending in ["authority lost", "resync"] {
      let app = try PitchSession(appVersion: "test")
      try app.restore(fixture("raise-many"), save: nil)
      var sent = 0
      app.onlineAction = { _ in sent += 1 }
      let hash = try app.engine.hash()
      app.raiseRest()
      try app.tick(0.02)
      #expect(app.raiseWatch == .ownLeadIn)
      if ending == "authority lost" {
        app.acceptsInput = false
        app.dropUnsentRaise()
      } else {
        app.resetPresentation()
      }
      #expect(app.raiseWatch == .none, "\(ending)")
      for _ in 0..<60 { try app.tick(0.02) }
      let after = try app.engine.hash()
      #expect(sent == 0 && after == hash, "\(ending)")
      #expect(app.need?.kind == "raise" && app.need?.n == 1, "\(ending)")
    }
    // tipping: its action is gone already; dropping does nothing
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    app.onlineAction = { _ in }
    try app.raiseWatched()
    #expect(app.raiseWatch == .ownTipping)
    app.dropUnsentRaise()
    #expect(app.raiseWatch == .ownTipping)
  }

  /// Another member's raise and the engine's are their own kinds of watch.
  @Test func arrivingAndEngineRaisesAreTheirOwnWatch() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("raise-many"), save: nil)
    _ = try app.engine.call("apply", json: #"{"type":"raise"}"#)
    try app.watchRaise(end: 0)
    #expect(app.raiseWatch == .arriving)
    for _ in 0..<60 where app.raiseShowing { try app.tick(0.02) }
    #expect(app.raiseWatch == .none)
    let n = try #require(app.need)
    let id = try #require(n.kubb), pose = try #require(n.pose), end = try #require(n.ends?.first)
    let clip = StoodShow.Kubb(
      id: id, lying: pose.piece(id: id),
      standing: MatchNeed.Pose(x: end.pose.x, y: end.pose.y, angle: end.pose.angle, standing: true).piece(id: id),
      toward: simd_normalize(V2(end.pose.x - pose.x, end.pose.y - pose.y)))
    app.stoodShow = StoodShow(kubbs: [clip], before: [], after: try app.read("view"))
    #expect(app.raiseWatch == .engine)
  }
}
