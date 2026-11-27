import CoreGraphics
import Foundation
import KubbEngine
import QuartzCore
import Testing
import simd

@testable import KubbRenderer

/// The home screen's match: the computer against the computer on an engine of its own, on
/// its own queue, in the Park scene, as scenery; nothing of it reaches the player's match,
/// the kept options or anything stored, and it runs only while home shows.
@MainActor struct HomeMatchTests {
  /// Ticks at 60 Hz, waiting on the queue whenever it has nothing to show yet, until
  /// `until` holds or `seconds` pass.
  static func run(_ h: HomeMatch, seconds: Double, until: () -> Bool = { false }) {
    for _ in 0..<Int(seconds * 60) {
      h.tick(1.0 / 60)
      if !h.ready { h.drain() }
      if until() { return }
    }
  }

  /// It plays: a throw made on its queue comes, flies and rests, and the next follows
  /// with little wait between them, in the Park scene, through the thrower's camera.
  @Test func itPlaysThrowAfterThrow() throws {
    let h = HomeMatch(appVersion: "test")
    #expect(!h.engineStarted)
    h.want(.on)
    let t0 = CACurrentMediaTime()
    h.drain()
    Self.run(h, seconds: 5) { h.ready }
    let first = CACurrentMediaTime() - t0
    #expect(h.ready)
    #expect(h.engineStarted)
    #expect(SceneID.shown(h.scene?.look) == "day")
    #expect(h.scene?.surface == .grass)
    // half a minute of the match on the screen (waiting on the queue as the screen would
    // not, so this measures the pace and not the machine)
    var moving = 0, frames = 0
    for _ in 0..<(30 * 60) {
      h.drain()
      if h.tick(1.0 / 60) { moving += 1 }
      frames += 1
    }
    print("home: first throw ready in \(Int(first * 1000)) ms; \(h.throwsMade) throws made; \(moving) of \(frames) frames moved")
    #expect(h.throwsMade >= 6)
    // little idle time: most frames move something
    #expect(Double(moving) / Double(frames) > 0.6)
    h.want(.off)
    #expect(!h.ready)
    h.drain()
    #expect(!h.engineStarted)
  }

  /// On only while home shows; paused (kept, still) in the background on home; off
  /// everywhere else and always under Reduce Motion, where no engine is ever made.
  @Test func itRunsOnlyWhileHomeShows() throws {
    #expect(HomeMatch.state(home: true, background: false, reduced: false) == .on)
    #expect(HomeMatch.state(home: true, background: true, reduced: false) == .paused)
    #expect(HomeMatch.state(home: false, background: false, reduced: false) == .off)
    #expect(HomeMatch.state(home: true, background: false, reduced: true) == .off)
    #expect(HomeMatch.state(home: true, background: true, reduced: true) == .off)
    let reduced = HomeMatch(appVersion: "test")
    reduced.want(HomeMatch.state(home: true, background: false, reduced: true))
    for _ in 0..<30 { reduced.tick(1.0 / 60) }
    reduced.drain()
    #expect(!reduced.engineStarted && !reduced.ready && reduced.throwsMade == 0)

    // paused: the picture holds and nothing more is made
    let h = HomeMatch(appVersion: "test", seed: 3)
    h.want(.on)
    #expect(h.play(toThrow: 2, at: 0.3))
    h.want(.paused)
    h.drain()
    let made = h.throwsMade, match = h.shownMatch
    for _ in 0..<120 { #expect(!h.tick(1.0 / 60)) }
    h.drain()
    #expect(h.throwsMade == made && h.shownMatch == match && h.ready)
    // and on again it goes on from there
    h.want(.on)
    #expect(h.play(toThrow: 3, at: 0.1))
    // off lets the engine go; on again is a new match on a new Lua state
    h.want(.off)
    h.drain()
    #expect(!h.engineStarted)
    h.want(.on)
    Self.run(h, seconds: 5) { h.ready }
    #expect(h.ready && h.engineStarted)
    h.want(.off)
  }

  /// One seed is one picture: the review pictures' moment is the same every time.
  @Test func aSeedIsTheSameMatch() throws {
    func moment() throws -> [Double] {
      let h = HomeMatch(appVersion: "test", seed: 7)
      h.want(.on)
      #expect(h.play(toThrow: 3, at: 0.45))
      let s = try #require(h.scene), c = try #require(h.camera)
      defer { h.want(.off) }
      return s.items.flatMap { [$0.x, $0.y, $0.z] } + [c.px, c.py, c.pz]
    }
    #expect(try moment() == moment())
  }

  /// Scenery only: a whole match and the start of the next change nothing kept on the
  /// device (the options, the name, the meter, throwsMade and the coach's counts, the
  /// kept solo match) and leave the player's own session as it was.
  @Test func itKeepsNothing() throws {
    let defaults = UserDefaults.standard
    let before = defaults.dictionaryRepresentation().filter { Self.kept($0.key) }.mapValues { "\($0)" }
    let player = try PitchSession(appVersion: "test")
    try player.startSolo(name: "Mighty Maple", selections: player.options.defaults, save: nil)
    let snapshot = try player.engine.call("snapshot")
    let saveDir = URL.applicationSupportDirectory.appending(path: "solo-match.json")
    let saved = try? Data(contentsOf: saveDir)
    let h = HomeMatch(appVersion: "test", seed: 11, maxTurns: 2)
    h.want(.on)
    var matches = Set<Int>()
    for _ in 0..<(60 * 60 * 6) {
      if h.waiting { h.drain() }
      h.tick(1.0 / 60)
      if let m = h.shownMatch { matches.insert(m) }
      if matches.count >= 2 { break }
    }
    h.want(.off)
    // a match ends and the next starts by itself, with no card
    #expect(matches.count >= 2)
    let after = defaults.dictionaryRepresentation().filter { Self.kept($0.key) }.mapValues { "\($0)" }
    #expect(after == before)
    #expect(try player.engine.call("snapshot") == snapshot)
    #expect((try? Data(contentsOf: saveDir)) == saved)
  }

  /// The keys the app keeps on the device.
  static func kept(_ key: String) -> Bool {
    ["pitch.", "solo.", "home.", "names.", "player."].contains { key.hasPrefix($0) }
  }
}
