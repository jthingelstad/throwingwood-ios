import CLua
import Foundation

/// A failed engine call. `call` is the engine's own refusal (`kubbCall`'s
/// `{"error": ...}`); `load` and `lua` are Lua errors outside it.
public enum EngineError: Error, Equatable, CustomStringConvertible {
  case missingSources(String)
  case load(String)
  case call(method: String, message: String)
  case lua(String)

  public var description: String {
    switch self {
    case .missingSources(let what): "engine sources: \(what)"
    case .load(let message): "engine load: \(message)"
    case .call(let method, let message): "\(method): \(message)"
    case .lua(let message): "lua: \(message)"
    }
  }
}

/// Where the vendored Lua came from (`Engine/engine.json`, written by
/// scripts/vendor-engine.sh).
public struct EngineManifest: Decodable, Sendable, Equatable {
  public let source: String
  public let commit: String
  /// "core/world.lua" to the file's SHA-256.
  public let files: [String: String]
}

/// The game engine: the Playdate game's Lua core and the web's session
/// (`lua/web`) in Lua 5.4, behind one door, `call(_:json:)`, the native twin
/// of the web's `kubbCall` (kubb.thingelstad.xyz docs/ENGINE.md). Every
/// argument and result is JSON text.
///
/// Each Engine is its own Lua state holding one session. It is not thread
/// safe: use one from one place at a time.
public final class Engine {
  private let state: OpaquePointer
  public let manifest: EngineManifest

  /// The engine shipped in this package.
  public convenience init() throws {
    try self.init(directory: Self.bundled())
  }

  /// The `Engine` folder in this package's resources.
  static func bundled() throws -> URL {
    guard let dir = Bundle.module.url(forResource: "Engine", withExtension: nil) else {
      throw EngineError.missingSources("no Engine folder in the bundle")
    }
    return dir
  }

  /// An engine from a folder laid out as `Engine/`: `core/*.lua`, `web/*.lua`
  /// and `engine.json`.
  public convenience init(directory: URL, extra: [String: String] = [:]) throws {
    let manifest: EngineManifest
    do {
      manifest = try JSONDecoder().decode(
        EngineManifest.self, from: Data(contentsOf: directory.appending(path: "engine.json")))
    } catch {
      throw EngineError.missingSources("engine.json: \(error)")
    }
    var sources = extra
    for name in manifest.files.keys {
      guard let text = try? String(contentsOf: directory.appending(path: name), encoding: .utf8) else {
        throw EngineError.missingSources(name)
      }
      sources[String(name.dropLast(4))] = text
    }
    try self.init(sources: sources, manifest: manifest)
  }

  /// `sources` maps module names as the web's bundle does ("core/world",
  /// "web/session") to their Lua.
  init(sources: [String: String], manifest: EngineManifest) throws {
    guard let state = luaL_newstate() else { throw EngineError.load("no memory for a Lua state") }
    self.state = state
    self.manifest = manifest
    luaL_openlibs(state)
    lua_createtable(state, 0, Int32(sources.count))
    for (name, text) in sources {
      push(text)
      lua_setfield(state, -2, name)
    }
    lua_setglobal(state, "__kubbSources")
    try run(Self.boot, name: "=boot")
    lua_getglobal(state, "kubbCall")
    let loaded = lua_type(state, -1) == LUA_TFUNCTION
    lua_settop(state, -2)
    if !loaded { throw EngineError.load("web/api did not define kubbCall") }
  }

  deinit {
    lua_close(state)
  }

  // The web's import shim (src/engine/index.js), reading the sources table.
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
    import "web/api"
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
    var chunk = chunk
    let status = chunk.withUTF8 { buf in
      buf.withMemoryRebound(to: CChar.self) {
        luaL_loadbufferx(state, $0.baseAddress, $0.count, name, "t")
      }
    }
    if status != LUA_OK { throw EngineError.load(popError()) }
    if lua_pcallk(state, 0, 0, 0, 0, nil) != LUA_OK { throw EngineError.load(popError()) }
  }

  /// Calls a global Lua function with string arguments and one string result.
  func callGlobal(_ function: String, _ args: String...) throws -> String {
    lua_getglobal(state, function)
    for arg in args { push(arg) }
    guard lua_pcallk(state, Int32(args.count), 1, 0, 0, nil) == LUA_OK else {
      throw EngineError.lua(popError())
    }
    defer { lua_settop(state, -2) }
    var length = 0
    guard let bytes = lua_tolstring(state, -1, &length) else {
      throw EngineError.lua("\(function) returned no text")
    }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
  }

  private func push(_ text: String) {
    var text = text
    text.withUTF8 { buf in
      buf.withMemoryRebound(to: CChar.self) { _ = lua_pushlstring(state, $0.baseAddress, $0.count) }
    }
  }

  private func popError() -> String {
    defer { lua_settop(state, -2) }
    var length = 0
    guard let bytes = lua_tolstring(state, -1, &length) else { return "(an error that is not text)" }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
  }
}
