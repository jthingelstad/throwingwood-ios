import CLua
import Foundation

/// A failed engine call. `call` is the engine's own refusal (`kubbCall`'s
/// `{"error": ...}`); `load` and `lua` are Lua errors outside it.
public enum EngineError: Error, Equatable, CustomStringConvertible {
  case missingSources(String)
  case load(String)
  case call(method: String, message: String)
  case lua(String)
  /// A match's engine major.minor that this build does not carry.
  case notCarried(String)

  public var description: String {
    switch self {
    case .notCarried(let mm): "engine \(mm) is not carried by this build"
    case .missingSources(let what): "engine sources: \(what)"
    case .load(let message): "engine load: \(message)"
    case .call(let method, let message): "\(method): \(message)"
    case .lua(let message): "lua: \(message)"
    }
  }
}

/// The vendored engine's own manifest (`Engine/engine.json`, from the
/// kubb-engine release scripts/vendor-engine.sh copies).
public struct EngineManifest: Decodable, Sendable, Equatable {
  public let name: String
  /// The kubb-engine release named by its bundled manifest.
  public let version: String
  /// "core/world.lua" to the file's SHA-256.
  public let files: [String: String]
}

/// The game engine, kubb-engine (the rules, physics and session of Kubb:
/// Throwing Wood) in Lua 5.4, behind one door, `call(_:json:)`, the native
/// twin of the engine's `kubbCall` (kubb-engine docs/SESSION.md). Every
/// argument and result is JSON text.
///
/// Each Engine is its own Lua state holding one session. It is not thread
/// safe: use one from one place at a time.
public final class Engine {
  private let state: OpaquePointer
  public let manifest: EngineManifest
  /// The engine's version, as its `engineVersion` call gives it.
  public let engineVersion: String

  /// The tune the engine runs with: a pointer's, until the iPhone's touch
  /// throw has its own (kubb-engine tune/).
  public static let tune = "pointer"

  /// The engine shipped in this package. `appVersion` names the app in the
  /// game files the engine writes (`[Scored by "Throwing Wood ios 0.1"]`).
  public convenience init(appVersion: String) throws {
    try self.init(directory: Self.bundled(), appVersion: appVersion)
  }

  /// The label `setClient` gets: "ios" and the app's version.
  public static func clientLabel(appVersion: String) -> String {
    "ios \(appVersion)"
  }

  /// The Location line of a game file written here, as on the web (engine 0.7.2+).
  /// It is in no snapshot, room document, recording or hash.
  public static let location = "throwingwood.com"

  /// The `Engine` folder in this package's resources: the newest engine.
  static func bundled() throws -> URL {
    guard let dir = Bundle.module.url(forResource: "Engine", withExtension: nil) else {
      throw EngineError.missingSources("no Engine folder in the bundle")
    }
    return dir
  }

  // MARK: - The engines this build carries

  /// "major.minor" of a version ("0.8.1", "0.8", "0.8+engines"), as the engine's
  /// `lobby.majorMinor` reads it, or nil.
  public static func majorMinor(_ version: String?) -> String? {
    guard let version,
      let m = version.firstMatch(of: /^(\d+)\.(\d+)/), let a = Int(m.1), let b = Int(m.2)
    else { return nil }
    return "\(a).\(b)"
  }

  /// The engines this build carries by major.minor, newest first (kubb-engine
  /// docs/VERSIONING.md "Carrying several engines"): the newest in the bundle's
  /// `Engine/`, and each older minor we decide to keep supporting in
  /// `Engines/<major.minor>/`, laid out the same way. Which ones is decided once, by
  /// `OLDER` in scripts/vendor-engine.sh (docs/ENGINES.md); today the newest alone, and
  /// the bundle has no `Engines/`.
  public static let carried: [String] = {
    var out: [String] = []
    if let dir = try? bundled(), let m = try? manifest(in: dir), let mm = majorMinor(m.version) {
      out.append(mm)
    }
    out += older.keys.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    return out
  }()

  /// The full version of every carried engine, newest first, as each one's engine.json
  /// names it (which its `engineVersion` must equal, checked when it starts), read
  /// without starting an older engine.
  public static let carriedVersions: [String] = carried.compactMap { mm in
    (try? bundled(minor: mm)).flatMap { try? manifest(in: $0).version }
  }

  /// The newest engine's major.minor: what solo, practice and a new pitch play on.
  public static var newest: String { carried.first ?? "" }

  /// Every older engine's folder, by major.minor: `Engines/<mm>/` whose engine.json
  /// names that minor, and only one `supportedOlder` names (Supported.swift, written
  /// from `OLDER`). A folder the bundle holds beyond that is a stale build's (SwiftPM
  /// leaves a resource folder Package.swift no longer copies) and is never carried.
  private static let older: [String: URL] = {
    var out: [String: URL] = [:]
    for (name, dir) in bundledOlder where supportedOlder.contains(name) {
      if let m = try? manifest(in: dir), majorMinor(m.version) == name { out[name] = dir }
    }
    return out
  }()

  /// Every engine folder in the bundle's `Engines/`, supported or not (a test checks a
  /// stale build has left none).
  static var bundledOlder: [String: URL] {
    guard let root = Bundle.module.url(forResource: "Engines", withExtension: nil),
      let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
    else { return [:] }
    var out: [String: URL] = [:]
    for name in names where !name.hasPrefix(".") { out[name] = root.appending(path: name) }
    return out
  }

  /// The folder of the carried engine of major.minor `minor`.
  static func bundled(minor: String) throws -> URL {
    if minor == newest { return try bundled() }
    guard let dir = older[minor] else { throw EngineError.notCarried(minor) }
    return dir
  }

  static func manifest(in directory: URL) throws -> EngineManifest {
    try JSONDecoder().decode(
      EngineManifest.self, from: Data(contentsOf: directory.appending(path: "engine.json")))
  }

  /// The carried engine of major.minor `minor` (nil: the newest), a Lua state of its
  /// own. Throws `EngineError.notCarried` for a minor this build does not carry.
  public convenience init(minor: String?, appVersion: String) throws {
    try self.init(directory: Self.bundled(minor: minor ?? Self.newest), appVersion: appVersion)
  }

  /// This engine's major.minor.
  public var minor: String { Self.majorMinor(engineVersion) ?? engineVersion }

  /// An engine from a folder laid out as `Engine/`: engine.json and the Lua
  /// files it names (`core/`, `pitch/` (`room/` before 0.13), `session/`, `tune/`,
  /// `version.lua`). `extra` adds modules beside them (a test driver).
  public convenience init(directory: URL, appVersion: String, extra: [String: String] = [:]) throws {
    let manifest: EngineManifest
    do {
      manifest = try Self.manifest(in: directory)
    } catch {
      throw EngineError.missingSources("engine.json: \(error)")
    }
    let sources = extra.merging(try Self.sources(in: directory, manifest: manifest)) { _, file in file }
    try self.init(sources: sources, manifest: manifest, appVersion: appVersion)
  }

  // MARK: - The neighbours' engine

  /// What a Lua state is for: the player's session (the tune, the client, every match),
  /// or the Tournament's neighbouring pitches (kubb-engine docs/SESSION.md "Neighbours"),
  /// which need neither and must never share a state with the session.
  public enum Role: Sendable { case session, neighbours }

  /// What this state is for.
  public let role: Role

  /// The neighbours' own engine: the newest bundle in a Lua state of its own, with the
  /// host's clock `__kubbClock` (monotonic milliseconds, for `neighbours.advance`'s
  /// `budgetMs`) set before the boot chunk, and no `useTune` or `setClient` (kubb-engine
  /// docs/CLIENTS.md "0.15.1 on top"). Only `neighbours.*` calls belong on it.
  public static func neighbours() throws -> Engine {
    let directory = try bundled()
    let manifest: EngineManifest
    do {
      manifest = try Self.manifest(in: directory)
    } catch {
      throw EngineError.missingSources("engine.json: \(error)")
    }
    return try Engine(sources: sources(in: directory, manifest: manifest), manifest: manifest, appVersion: "", role: .neighbours)
  }

  private static func sources(in directory: URL, manifest: EngineManifest) throws -> [String: String] {
    var sources: [String: String] = [:]
    for name in manifest.files.keys {
      guard let text = try? String(contentsOf: directory.appending(path: name), encoding: .utf8) else {
        throw EngineError.missingSources(name)
      }
      sources[String(name.dropLast(4))] = text
    }
    return sources
  }

  /// The host's clock for the neighbours' budget: monotonic milliseconds since boot
  /// (`CLOCK_UPTIME_RAW`, which stops while the device sleeps, as the match clock does).
  /// A C function of the Swift target's, so the engine's C targets and their flags are
  /// untouched; it reads no maths library.
  static let hostClock: lua_CFunction = { state in
    lua_pushnumber(state, Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000)
    return 1
  }

  /// `sources` maps module names as the engine's bundle does ("core/world",
  /// "session/api", "version") to their Lua.
  init(sources: [String: String], manifest: EngineManifest, appVersion: String, role: Role = .session) throws {
    guard let state = luaL_newstate() else { throw EngineError.load("no memory for a Lua state") }
    do {
      luaL_openlibs(state)
      if role == .neighbours {
        lua_pushcclosure(state, Self.hostClock, 0)
        lua_setglobal(state, "__kubbClock")
      }
      lua_createtable(state, 0, Int32(sources.count))
      for (name, text) in sources {
        Self.push(state, text)
        lua_setfield(state, -2, name)
      }
      lua_setglobal(state, "__kubbSources")
      try Self.run(state, Self.boot, name: "=boot")
      lua_getglobal(state, "kubbCall")
      let loaded = lua_type(state, -1) == LUA_TFUNCTION
      lua_settop(state, -2)
      if !loaded { throw EngineError.load("session/api did not define kubbCall") }
      let version = try Self.start(state: state, appVersion: appVersion, role: role)
      if version != manifest.version {
        throw EngineError.load("the engine says it is \(version), engine.json \(manifest.version)")
      }
      self.engineVersion = version
    } catch {
      lua_close(state)
      throw error
    }
    self.state = state
    self.manifest = manifest
    self.role = role
  }

  /// The host's calls before the first `new` or `restore` (kubb-engine
  /// docs/SESSION.md "Starting"): the version, the tune, the client label and location.
  /// The neighbours' state asks the version alone.
  private static func start(state: OpaquePointer, appVersion: String, role: Role) throws -> String {
    struct Version: Decodable { let version: String }
    func call(_ method: String, _ args: [String: String]) throws -> Data {
      let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
      let text = try callGlobal(state, "kubbCall", method, json)
      if text.hasPrefix(#"{"error":"#) { throw EngineError.load("\(method): \(text)") }
      return Data(text.utf8)
    }
    let version = try JSONDecoder().decode(Version.self, from: call("engineVersion", [:])).version
    if role == .neighbours { return version }
    _ = try call("useTune", ["name": tune])
    _ = try call("setClient", ["label": clientLabel(appVersion: appVersion), "location": location])
    return version
  }

  deinit {
    lua_close(state)
  }

  // The engine's import shim (kubb-engine docs/SESSION.md "Loading"), reading
  // the sources table.
  private static let boot = """
    local sources = __kubbSources
    __kubbSources = nil
    function __kubbSource(name) return sources[name] end
    local imported = {}
    function import(name)
      name = name:gsub("%.lua$", "")
      if imported[name] then return nil end
      imported[name] = true
      local s = __kubbSource(name)
      if not s then error("import: no module " .. name, 2) end
      return assert(load(s, "@" .. name))()
    end
    import "session/api"
    """

  /// One engine call: the method's name and its argument as JSON text (empty
  /// for none), the result as JSON text. `snapshot` returns the snapshot
  /// itself, and `restore` takes it as its argument, as on the web.
  public func call(_ method: String, json: String = "") throws -> String {
    let text = try callGlobal("kubbCall", method, json)
    if text.hasPrefix(#"{"error":"#) {
      let message =
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? String
      throw EngineError.call(method: method, message: message ?? text)
    }
    return text
  }

  /// The match's hash (FNV-1a 32 of its snapshot, 8 hex digits): equal hashes
  /// mean equal matches, here and on the web.
  public func hash() throws -> String {
    struct Hash: Decodable { let hash: String }
    return try JSONDecoder().decode(Hash.self, from: Data(call("hash").utf8)).hash
  }

  /// Lua's version, as `_VERSION` and the release this build compiled.
  public var luaVersion: String {
    "Lua \(LUA_VERSION_MAJOR).\(LUA_VERSION_MINOR).\(LUA_VERSION_RELEASE)"
  }

  // MARK: - Lua

  /// Runs a chunk of Lua in this engine's state.
  func run(_ chunk: String, name: String) throws {
    try Self.run(state, chunk, name: name)
  }

  private static func run(_ state: OpaquePointer, _ chunk: String, name: String) throws {
    var chunk = chunk
    let status = chunk.withUTF8 { buf in
      buf.withMemoryRebound(to: CChar.self) {
        luaL_loadbufferx(state, $0.baseAddress, $0.count, name, "t")
      }
    }
    if status != LUA_OK { throw EngineError.load(popError(state)) }
    if lua_pcallk(state, 0, 0, 0, 0, nil) != LUA_OK { throw EngineError.load(popError(state)) }
  }

  /// Calls a global Lua function with string arguments and one string result.
  func callGlobal(_ function: String, _ args: String...) throws -> String {
    try Self.callGlobal(state, function, args)
  }

  private static func callGlobal(_ state: OpaquePointer, _ function: String, _ args: String...) throws -> String {
    try callGlobal(state, function, args)
  }

  private static func callGlobal(_ state: OpaquePointer, _ function: String, _ args: [String]) throws -> String {
    lua_getglobal(state, function)
    for arg in args { push(state, arg) }
    guard lua_pcallk(state, Int32(args.count), 1, 0, 0, nil) == LUA_OK else {
      throw EngineError.lua(popError(state))
    }
    defer { lua_settop(state, -2) }
    var length = 0
    guard let bytes = lua_tolstring(state, -1, &length) else {
      throw EngineError.lua("\(function) returned no text")
    }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
  }

  private func push(_ text: String) {
    Self.push(state, text)
  }

  private static func push(_ state: OpaquePointer, _ text: String) {
    var text = text
    text.withUTF8 { buf in
      buf.withMemoryRebound(to: CChar.self) { _ = lua_pushlstring(state, $0.baseAddress, $0.count) }
    }
  }

  private func popError() -> String {
    Self.popError(state)
  }

  private static func popError(_ state: OpaquePointer) -> String {
    defer { lua_settop(state, -2) }
    var length = 0
    guard let bytes = lua_tolstring(state, -1, &length) else { return "(an error that is not text)" }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
  }
}
