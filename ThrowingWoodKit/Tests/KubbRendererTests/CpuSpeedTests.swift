import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// The computer's turn against the computer (engine 1.4.0, `frame {dt, speed}` and
/// `cpuPlay`): watched at 1x, 2x or 4x, or skipped to the person's next throw. Solo only.
@MainActor struct CpuSpeedTests {
  private func folder() -> URL {
    URL.temporaryDirectory.appending(path: "cpu-" + UUID().uuidString)
  }

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

  /// A solo match (its seed random, as a player's), the throw to go off, played by the
  /// person to the computer's first throw.
  private func atComputersTurn(_ save: MatchSave? = nil) throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    try app.startSolo(name: "Mighty Maple", selections: app.options.withoutTogo, save: save)
    for _ in 0..<20000 {
      app.dismissHandoff()
      if app.need?.kind == "throw", app.need?.cpu == true, !app.playing, !app.raiseShowing { break }
      if app.playing {
        try app.skipPlayback()
      } else if app.canAim, app.need?.cpu != true {
        for p in try armPoints(app.dial) {
          app.sample(p)
          try app.tick(1.0 / 60)
        }
        app.sample(nil)
        try app.tick(1.0 / 60)
      } else {
        try app.tick(0.05)
      }
    }
    try #require(app.need?.kind == "throw" && app.need?.cpu == true)
    return app
  }

  @Test func theSpeedIsTheDevicesAndCycles() throws {
    let d = try #require(UserDefaults(suiteName: "cpu-\(UUID().uuidString)"))
    #expect(CpuSpeed.load(d) == 1)
    CpuSpeed.keep(4, in: d)
    #expect(CpuSpeed.load(d) == 4)
    CpuSpeed.keep(3, in: d)
    #expect(CpuSpeed.load(d) == 4)
    #expect([1, 2, 4].map(CpuSpeed.next(after:)) == [2, 4, 1])
    #expect(CpuSpeed.label(2) == "2X" && CpuSpeed.spoken(1) == "Normal" && CpuSpeed.spoken(4) == "4 times")
  }

  /// The button shows on the computer's turn of a solo match, and never on a practice or
  /// to a watcher; the speed changes only the pace, never what the computer throws.
  @Test func fasterIsTheSameTurnSooner() throws {
    var hashes: [Int: String] = [:]
    var ticks: [Int: Int] = [:]
    let snapshot = try atComputersTurn().engine.call("snapshot")
    // one time for both runs: each throw's stamp is the match's finish, which the hash
    // holds to the minute, so two runs either side of a minute would differ by that alone
    let now = Date()
    for speed in [1, 4] {
      let app = try PitchSession(appVersion: "test")
      app.clockNow = { now }
      try app.restore(snapshot, save: nil)
      app.dismissHandoff()
      #expect(app.computerTurn)
      app.cpuSpeed = speed
      var n = 0
      while app.need?.cpu == true || app.playing || app.raiseShowing {
        try app.tick(1.0 / 60)
        n += 1
        if n > 200_000 { break }
      }
      hashes[speed] = try app.engine.hash()
      ticks[speed] = n
      #expect(!app.computerTurn)
    }
    #expect(hashes[1] == hashes[4])
    let one = try #require(ticks[1]), four = try #require(ticks[4])
    let quarterish = Double(one) * 0.5
    #expect(Double(four) < quarterish, "4x took \(four) frames, 1x \(one)")
    // a practice has no computer's turn
    let practice = try PitchSession(appVersion: "test")
    try practice.practice()
    #expect(!practice.computerTurn && practice.fastFactor == 1)
  }

  /// SKIP plays the computer's turn at once (`cpuPlay`): its throws land in the kept trail
  /// one by one with their own hashes, the save is the engine's snapshot after them, and
  /// the match reopens from the save with its trail whole.
  @Test func skipKeepsEveryThrowInTheTrail() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let save = MatchSave(file: dir.appending(path: "solo-match.json"))
    let app = try atComputersTurn(save)
    // one time for the skipped and the watched turn (the finish is in the hash, as above)
    let now = Date()
    app.clockNow = { now }
    let before = try #require(save.readTrail()?.trail.entries.count)
    let start = try app.engine.call("snapshot")
    try app.skipComputer()
    #expect(app.need?.cpu != true && !app.playing && !app.computerTurn)
    #expect(try save.read() == app.engine.call("snapshot"))
    let after = try #require(save.readTrail()?.trail.entries.count)
    #expect(after > before)
    let again = try PitchSession(appVersion: "test")
    try again.restore(#require(try save.read()), save: save)
    #expect(again.trailComplete)
    #expect(try again.engine.hash() == app.engine.hash())
    // played through at its own pace instead, the computer makes the same turn
    let watched = try PitchSession(appVersion: "test")
    watched.clockNow = { now }
    try watched.restore(start, save: nil)
    watched.dismissHandoff()
    var n = 0
    while (watched.need?.cpu == true || watched.playing || watched.raiseShowing) && n < 200_000 {
      try watched.tick(1.0 / 60)
      n += 1
    }
    #expect(try watched.engine.hash() == app.engine.hash())
  }
}
