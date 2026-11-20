import Foundation
import KubbEngine

/// The engines a pitch can run, one Lua state per major.minor, each made the first
/// time a match asks for it (kubb-engine docs/VERSIONING.md "Carrying several
/// engines"). The newest is made at once: the room's new calls (`engineFor`,
/// `announce`, `speakAs`, since 0.8.1) are always asked of it. Main actor only, as
/// every engine here is.
@MainActor public final class EngineShelf {
  /// Every major.minor this shelf can run, newest first.
  public let carried: [String]
  /// The newest engine.
  public let newest: Engine
  private let appVersion: String
  private let make: (String) throws -> Engine
  private var states: [String: Engine] = [:]

  /// Every engine this build carries (`Engine.carried`).
  public convenience init(appVersion: String) throws {
    try self.init(
      newest: Engine(appVersion: appVersion), carried: Engine.carried, appVersion: appVersion
    ) { try Engine(minor: $0, appVersion: appVersion) }
  }

  /// One engine and nothing else: a client that carries one (tests, tools).
  public convenience init(engine: Engine) {
    try! self.init(newest: engine, carried: [engine.minor], appVersion: "") { _ in engine }
  }

  init(
    newest: Engine, carried: [String], appVersion: String, make: @escaping (String) throws -> Engine
  ) throws {
    self.newest = newest
    self.carried = carried.isEmpty ? [newest.minor] : carried
    self.appVersion = appVersion
    self.make = make
    states[newest.minor] = newest
  }

  /// Whether this shelf carries the major.minor of `version` ("0.7", "0.7.4").
  public func carries(_ version: String?) -> Bool {
    Engine.majorMinor(version).map(carried.contains) ?? false
  }

  /// The engine of major.minor `minor`, made the first time it is asked for. Throws
  /// `EngineError.notCarried` for one this shelf does not carry.
  public func engine(_ minor: String) throws -> Engine {
    if let e = states[minor] { return e }
    guard carried.contains(minor) else { throw EngineError.notCarried(minor) }
    let e = try make(minor)
    states[minor] = e
    return e
  }

  /// The major.minors with a Lua state made so far (a test sees an older one made lazily).
  public var loaded: [String] { carried.filter { states[$0] != nil } }
}
