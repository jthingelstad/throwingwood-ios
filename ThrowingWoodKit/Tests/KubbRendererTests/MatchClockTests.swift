import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// A match's length (engine 0.18.0, kubb-engine docs/SESSION.md "Actions", `at`; the web's
/// src/game/clock.js): the start carries the starting host's UTC offset, every action the
/// app makes carries its stamp on that clock, and a match with no stamps shows no length.
@MainActor struct MatchClockTests {
  /// 2026-11-22 12:00 in Chicago (UTC-6, no daylight saving then).
  static let noon = Date(timeIntervalSince1970: 1_795_370_400)
  static let chicago = TimeZone(identifier: "America/Chicago")!
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  @Test func theStartIsTheLocalWallClockWithItsOffset() throws {
    let s = try JSONNode.parse(MatchClock.start(Self.noon, zone: Self.chicago).ascii)
    #expect(s["year"]?.int == 2026 && s["month"]?.int == 11 && s["day"]?.int == 22)
    #expect(s["hour"]?.int == 12 && s["min"]?.int == 0 && s["utcOffset"]?.int == -360)
    let tokyo = try JSONNode.parse(MatchClock.start(Self.noon, zone: TimeZone(identifier: "Asia/Tokyo")!).ascii)
    #expect(tokyo["day"]?.int == 23 && tokyo["hour"]?.int == 3 && tokyo["utcOffset"]?.int == 540)
  }

  /// A stamp is the device's UTC clock on the start's offset, wherever the device is: a
  /// joiner in Tokyo stamps on the Chicago host's clock.
  @Test func aStampIsOnTheStartsClock() throws {
    let start = MatchClock.Start(year: 2026, month: 11, day: 22, hour: 12, min: 0, utcOffset: -360)
    let at = try #require(MatchClock.stamp(on: start, now: Self.noon.addingTimeInterval(95 * 60)))
    #expect(at.ascii == #"{"year":2026,"month":11,"day":22,"hour":13,"min":35}"#)
    // before the start, past twelve hours, or a start with no offset: no stamp
    #expect(MatchClock.stamp(on: start, now: Self.noon.addingTimeInterval(-120)) == nil)
    #expect(MatchClock.stamp(on: start, now: Self.noon.addingTimeInterval(13 * 3600)) == nil)
    let old = MatchClock.Start(year: 2026, month: 11, day: 22, hour: 12, min: 0, utcOffset: nil)
    #expect(MatchClock.stamp(on: old, now: Self.noon) == nil)
    #expect(MatchClock.stamp(on: nil, now: Self.noon) == nil)
  }

  @Test func aStampIsAddedToTheObject() {
    let at = JS.object([("year", .int(2026)), ("month", .int(1)), ("day", .int(2)), ("hour", .int(3)), ("min", .int(4))])
    #expect(MatchClock.adding(at, to: "{}") == #"{"at":{"year":2026,"month":1,"day":2,"hour":3,"min":4}}"#)
    #expect(
      MatchClock.adding(at, to: #"{"type":"resign","side":"A"}"#)
        == #"{"type":"resign","side":"A","at":{"year":2026,"month":1,"day":2,"hour":3,"min":4}}"#)
    #expect(MatchClock.adding(nil, to: #"{"dt":0.05}"#) == #"{"dt":0.05}"#)
  }

  /// The winner card's minutes: only a stamped length that can be true (the web's
  /// cards.js, 1 to 720), never 0 or "under a minute".
  @Test func onlyAKnownLengthIsShown() {
    #expect(MatchClock.shown(nil) == nil)
    #expect(MatchClock.shown(0) == nil)
    #expect(MatchClock.shown(7) == 7)
    #expect(MatchClock.shown(720) == 720)
    #expect(MatchClock.shown(721) == nil)
  }

  /// A match against the computer: the start has the device's offset, the resignation
  /// carries its stamp, and the winner card and the game file have the length.
  @Test func aSoloMatchHasItsLength() throws {
    let app = try PitchSession(appVersion: "test")
    app.clockNow = { Self.noon }
    try app.startSolo(name: "Mighty Maple", selections: app.options.defaults, save: nil)
    let start = try JSONNode.parse(app.engine.call("snapshot"))["opts"]?["start"]
    #expect(start?["utcOffset"]?.int == TimeZone.current.secondsFromGMT(for: Self.noon) / 60)
    app.dismissHandoff()
    app.clockNow = { Self.noon.addingTimeInterval(7 * 60 + 20) }
    try app.resign()
    #expect(app.trail.actions.last?.text.contains(#""at":{"#) == true)
    #expect(app.need?.winner?.minutes == 7)
    #expect(try app.sheet().text.contains(#"[Duration "7m"]"#))
  }

  /// The computer's throws and the player's are made inside `frame`: every frame carries
  /// the stamp, so the action a release makes has it.
  @Test func aThrowMadeInTheFrameIsStamped() throws {
    let setup =
      #"{"mode":"match","cpu":"both","seed":1001,"start":{"year":2026,"month":11,"day":22,"hour":12,"min":0,"utcOffset":-360}}"#
    let app = try PitchSession(appVersion: "test")
    app.clockNow = { Self.noon.addingTimeInterval(3 * 60) }
    try app.openMatch("new", json: setup, save: nil)
    for _ in 0..<4_000 where !app.playing { try app.tick(0.05) }
    try #require(app.playing)
    let action = try #require(app.trail.actions.last)
    #expect(try JSONNode.parse(action)["at"]?["min"]?.int == 3)
  }

  /// A match whose start has no offset (one from before 0.18, a fixture) is never stamped:
  /// it finishes with no minutes and no Duration line, and the card shows no time.
  @Test func anUnstampedMatchHasNoLength() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("aim"), save: nil)
    app.dismissHandoff()
    try app.resign()
    #expect(app.trail.actions.last?.text.contains(#""at""#) == false)
    let w = try #require(app.need?.winner)
    #expect(w.minutes == nil && MatchClock.shown(w.minutes) == nil)
    #expect(try !app.sheet().text.contains("[Duration"))
  }
}
