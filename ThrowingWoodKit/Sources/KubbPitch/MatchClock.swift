import Foundation

/// A match's clock (engine 0.18.0, kubb-engine docs/SESSION.md "Actions", `at`; the web's
/// src/game/clock.js): the start and the stamps on its actions on one basis, made here and
/// nowhere else.
///
/// The engine takes a match's start and its finish as wall-clock fields (`{ year, month,
/// day, hour, min }`) and subtracts them with no time zone. The start is the starting
/// host's local wall clock (the game file's Start line), and it carries that host's UTC
/// offset at that moment (`utcOffset`, minutes east of UTC), so every later stamp is the
/// stamping device's UTC clock on that same offset, whoever stamps and wherever they are.
/// A daylight-saving change mid-match moves nothing: the offset is the start's. A start
/// with no offset (an older match) gets no stamps: no length rather than a wrong one.
public enum MatchClock {
  /// The longest a match can honestly last (the web's MAX_MINUTES); past it a stamp is a
  /// clock gone wrong.
  public static let maxMinutes = 12 * 60

  /// The start for a new match (solo, and a pitch's START): the local wall clock now and
  /// its UTC offset.
  public static func start(_ date: Date = Date(), zone: TimeZone = .current) -> JS {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return .object([
      ("year", .int(c.year!)), ("month", .int(c.month!)), ("day", .int(c.day!)),
      ("hour", .int(c.hour!)), ("min", .int(c.minute!)),
      ("utcOffset", .int(zone.secondsFromGMT(for: date) / 60)),
    ])
  }

  /// A match's start as the clock reads it: its wall fields and offset.
  public struct Start: Equatable, Sendable {
    public let year, month, day, hour, min: Int
    public let utcOffset: Int?
    public init(year: Int, month: Int, day: Int, hour: Int, min: Int, utcOffset: Int?) {
      (self.year, self.month, self.day, self.hour, self.min) = (year, month, day, hour, min)
      self.utcOffset = utcOffset
    }
    /// From a start table (`opts.start` of a snapshot, a `new`'s `start`).
    public init?(_ node: JSONNode?) {
      guard let n = node, let y = n["year"]?.int, let mo = n["month"]?.int, let d = n["day"]?.int,
        let h = n["hour"]?.int, let mi = n["min"]?.int
      else { return nil }
      self.init(year: y, month: mo, day: d, hour: h, min: mi, utcOffset: n["utcOffset"]?.int)
    }
    /// From a match's snapshot text (its `opts.start`).
    public init?(snapshot: String?) {
      guard let s = snapshot, let node = try? JSONNode.parse(s) else { return nil }
      self.init(node["opts"]?["start"])
    }
    /// Minutes since the epoch, reading the wall fields as if they were UTC (as the
    /// engine subtracts them).
    var wallMinutes: Int { MatchClock.wallMinutes(year, month, day, hour, min) }
  }

  static func wallMinutes(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    return Int((date.timeIntervalSince1970 / 60).rounded())
  }

  /// An action's `at` now: the device's UTC clock on the start's offset, or nil when the
  /// start has none, or when the stamp could not be true (before the start, or past
  /// `maxMinutes` after it).
  public static func stamp(on start: Start?, now: Date = Date()) -> JS? {
    guard let start, let off = start.utcOffset else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents(
      [.year, .month, .day, .hour, .minute], from: now.addingTimeInterval(Double(off) * 60))
    let at = (c.year!, c.month!, c.day!, c.hour!, c.minute!)
    let m = wallMinutes(at.0, at.1, at.2, at.3, at.4) - start.wallMinutes
    guard m >= 0, m <= maxMinutes else { return nil }
    return .object([
      ("year", .int(at.0)), ("month", .int(at.1)), ("day", .int(at.2)), ("hour", .int(at.3)),
      ("min", .int(at.4)),
    ])
  }

  /// `object` (the JSON text of an object: an action or a `frame` call's input) with `at`
  /// added, or as it is when there is no stamp.
  public static func adding(_ at: JS?, to object: String) -> String {
    guard let at, let close = object.lastIndex(of: "}") else { return object }
    let inside = object[object.index(after: object.startIndex)..<close]
    let empty = inside.allSatisfy(\.isWhitespace)
    return String(object[..<close]) + (empty ? "" : ",") + #""at":"# + at.ascii + "}"
  }

  /// The minutes a winner card or a share shows: the engine's `winner.minutes` only when
  /// the match was stamped and the length can be true (1 to `maxMinutes`; the web's
  /// cards.js). A match no action stamped has none (engine 0.18.0), and a match under a
  /// minute shows none either, never "under a minute".
  public static func shown(_ minutes: Int?) -> Int? {
    guard let minutes, minutes >= 1, minutes <= maxMinutes else { return nil }
    return minutes
  }
}
