import CryptoKit
import Foundation
import Testing

@testable import KubbEngine

@Suite struct EngineTests {
  /// The vendored Lua is what engine.json says, byte for byte
  /// (scripts/vendor-engine.sh check does the same from the shell).
  @Test func vendoredFilesMatchTheManifest() throws {
    let dir = try Engine.bundled()
    let engine = try Engine(appVersion: testAppVersion)
    #expect(engine.manifest.name == "kubb-engine")
    #expect(engine.manifest.files.count > 40)
    for (name, sha) in engine.manifest.files {
      let data = try Data(contentsOf: dir.appending(path: name))
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      #expect(digest == sha, "\(name)")
    }
  }

  /// The host's calls at start: the version matches engine.json, the tune is
  /// loaded (so `new` runs) and the label is in the game file.
  @Test func theEngineStartsAsAHost() throws {
    let engine = try Engine(appVersion: "1.2")
    #expect(engine.engineVersion == engine.manifest.version)
    #expect(engine.engineVersion.split(separator: ".").count == 3)
    _ = try engine.call("new", json: #"{"mode":"match","seed":7,"cpu":"both","maxTurns":1}"#)
    var need = try engine.call("need")
    for _ in 0..<100_000 where !need.contains(#""kind":"over""#) {
      _ = try engine.call("frame", json: #"{"dt":0.016666666666666666}"#)
      need = try engine.call("need")
    }
    #expect(need.contains(#"Throwing Wood ios 1.2"#))
  }

  /// A score sheet written here says it was played at throwingwood.com, and
  /// the Location line changes no hash: an engine set back to the default
  /// ("Playdate") plays the same match to the same hashes.
  @Test func theSheetSaysThrowingwoodCom() throws {
    struct Sheet: Decodable { let text: String }
    let options = #"{"mode":"match","seed":42,"cpu":"both","maxTurns":2}"#
    let app = try Engine(appVersion: testAppVersion)
    let plain = try Engine(appVersion: testAppVersion)
    _ = try plain.call("setClient", json: #"{"label":"ios test"}"#)
    _ = try app.call("new", json: options)
    _ = try plain.call("new", json: options)
    for _ in 0..<600 {
      _ = try app.call("frame", json: #"{"dt":0.05}"#)
      _ = try plain.call("frame", json: #"{"dt":0.05}"#)
      try #require(try app.hash() == plain.hash())
    }
    func text(_ e: Engine) throws -> String {
      try JSONDecoder().decode(Sheet.self, from: Data(e.call("sheet").utf8)).text
    }
    #expect(try text(app).contains(#"[Location "throwingwood.com"]"#))
    #expect(try text(plain).contains(#"[Location "Playdate"]"#))
  }

  @Test func aMatchStartsAndHashesTheSameEveryTime() throws {
    let options = #"{"mode":"match","seed":42,"cpu":"both","maxTurns":4}"#
    let a = try Engine(appVersion: testAppVersion)
    let b = try Engine(appVersion: testAppVersion)
    _ = try a.call("new", json: options)
    _ = try b.call("new", json: options)
    let hash = try a.hash()
    #expect(hash.count == 8)
    #expect(try b.hash() == hash)
    // A snapshot restored elsewhere is the same match.
    let c = try Engine(appVersion: testAppVersion)
    _ = try c.call("restore", json: a.call("snapshot"))
    #expect(try c.hash() == hash)
  }

  @Test func refusalsAreErrors() throws {
    let engine = try Engine(appVersion: testAppVersion)
    #expect {
      try engine.call("snapshot")
    } throws: { error in
      guard case EngineError.call(let method, let message) = error else { return false }
      return method == "snapshot" && message.contains("no session")
    }
    #expect(throws: EngineError.self) { try engine.call("noSuchMethod") }
  }

  @Test func aBrokenModuleFailsToLoad() throws {
    let manifest = EngineManifest(name: "kubb-engine", version: "0.0.0", files: [:])
    #expect(throws: EngineError.self) {
      try Engine(sources: ["session/api": "this is not lua"], manifest: manifest, appVersion: testAppVersion)
    }
  }
}
