import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

extension SoloOptions {
  /// The card's defaults with the throw to go off (engine 1.4.0; the card's default is
  /// on): for a test about the match after it, which starts on turn 1's throw.
  var withoutTogo: [String: String] { defaults.merging(["togo": "off"]) { $1 } }
}

/// The throw to go (engine 1.4.0, kubb-engine docs/SESSION.md "The throw to go"): each team
/// throws one baton at the king, the nearer that leaves it standing throws first.
@MainActor struct TogoTests {
  private func armPoints(_ d: DialState) throws -> [CGPoint] {
    let dt = 1.0 / 60
    let back = try #require(d.powerLo.flatMap { lo in d.powerHi.map { (lo + $0) / 2 } })
    let stop = try #require(d.releaseLo.flatMap { lo in d.releaseHi.map { (lo + $0) / 2 } })
    var a = -5.0
    var angles = [0.0, a]
    while a > -back {
      a = max(-back, a - 400 * dt)
      angles.append(a)
    }
    while a < stop {
      a = min(stop, a + 2400 * dt)
      angles.append(a)
    }
    return angles.map { a in CGPoint(x: sin(a * .pi / 180), y: cos(a * .pi / 180)) }
  }

  /// The card's default is on, and the row sits after Opening; a Kid match has none.
  @Test func theCardOffersItOnByDefault() throws {
    let app = try PitchSession(appVersion: "test")
    #expect(app.options.defaults["togo"] == "on")
    let rows = app.options.cardRows(app.options.defaults).map(\.id)
    let opening = try #require(rows.firstIndex(of: "opening"))
    #expect(rows.firstIndex(of: "togo") == opening + 1)
    var kid = app.options.defaults
    kid["computer"] = "kid"
    #expect(!app.options.cardRows(kid).map(\.id).contains("togo"))
    // a Kid match starts on its first throw, whatever the kept switch says
    try app.startSolo(name: "Mighty Maple", selections: kid, save: nil)
    #expect(app.need?.kind == "throw")
  }

  /// Against the computer: the person's baton, then the computer's at once (blind, so the
  /// person sees nothing of theirs before the verdict), and the verdict's words; a throw
  /// again goes round once more, and the match then starts on the first throw.
  @Test func aSoloMatchOpensOnTheThrowToGo() throws {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "Mighty Maple", selections: app.options.defaults, save: nil)
    #expect(app.need?.kind == "togo" && app.togoToThrow && !app.togoWaiting)
    app.dismissHandoff()
    var verdicts: [ThrowResult] = []
    for _ in 0..<4 where app.need?.kind == "togo" {
      #expect(app.canAim)
      for p in try armPoints(app.dial) {
        app.sample(p)
        try app.tick(1.0 / 60)
      }
      app.sample(nil)
      try app.tick(1.0 / 60)
      var ticks = 0
      while app.result?.togo != true && ticks < 4000 {
        try app.tick(1.0 / 60)
        ticks += 1
      }
      let r = try #require(app.result)
      #expect(r.togo == true && r.A != nil && r.B != nil)
      verdicts.append(r)
      // the flag names the side that throws first or says to throw again
      let flag = try #require(r.headline)
      if r.how == "again" {
        #expect(flag == "THROW AGAIN")
      } else {
        #expect(flag == (r.first == "A" ? "YOU THROW FIRST" : "COMPUTER THROWS FIRST"))
      }
      ticks = 0
      while app.need?.kind == "togo" && !app.canAim && ticks < 4000 {
        try app.tick(1.0 / 60)
        ticks += 1
      }
      if app.need?.kind != "togo" { break }
      app.dismissHandoff()
    }
    #expect(!verdicts.isEmpty)
    #expect(app.need?.kind == "throw", "the match goes on to its first throw")
    // the decided side throws first (`first` of the last verdict)
    let last = try #require(verdicts.last)
    if last.how != "again" { #expect(app.need?.side == last.first) }
  }

  /// The verdict's words, the screen's own: each baton's distance, the king knocked over,
  /// a tie, both knocked over.
  @Test func theVerdictsWords() throws {
    func result(_ json: String, viewer: String? = "A") throws -> ThrowResult {
      var r = try JSONDecoder().decode(ThrowResult.self, from: Data(json.utf8))
      r.togo = true
      r.togoTeams = ["A": "Mighty Maple", "B": "Computer"]
      r.togoViewer = viewer
      return r
    }
    let closer = try result(#"{"first":"B","how":"closer","A":{"gap":0.88},"B":{"gap":0.42}}"#)
    #expect(closer.headline == "COMPUTER THROWS FIRST")
    #expect(closer.shownRest == "0.42 m against 0.88 m")
    let mine = try result(#"{"first":"A","how":"closer","A":{"gap":0},"B":{"gap":0.3}}"#)
    #expect(mine.headline == "YOU THROW FIRST" && mine.shownRest == "touching against 0.30 m")
    let king = try result(#"{"first":"B","how":"king","A":{"gap":0,"toppled":true},"B":{"gap":1}}"#)
    #expect(king.headline == "COMPUTER THROWS FIRST" && king.shownRest == "You knocked the king over")
    let tie = try result(#"{"how":"again","why":"tie","A":{"gap":0.5},"B":{"gap":0.5}}"#)
    #expect(tie.headline == "THROW AGAIN" && tie.shownRest == "A tie: both just as close")
    let both = try result(#"{"how":"again","why":"both king","A":{"toppled":true},"B":{"toppled":true}}"#)
    #expect(both.headline == "THROW AGAIN" && both.shownRest == "Both knocked the king over")
    // a watcher has no side of its own: the team's name
    let watched = try result(#"{"first":"A","how":"closer","A":{"gap":0.1},"B":{"gap":0.2}}"#, viewer: nil)
    #expect(watched.headline == "MIGHTY MAPLE THROWS FIRST")
    #expect(TogoWords.waiting(for: "Computer") == "Waiting for Computer")
  }

  /// A match with the throw to go is kept and reopened on it, and its replay holds it.
  @Test func aKeptMatchReopensOnTheThrowToGo() throws {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "Mighty Maple", selections: app.options.defaults, save: nil)
    let snapshot = try app.engine.call("snapshot")
    let again = try PitchSession(appVersion: "test")
    try again.restore(snapshot, save: nil)
    #expect(again.need?.kind == "togo" && again.togoToThrow)
    #expect(try again.engine.hash() == app.engine.hash())
  }
}
