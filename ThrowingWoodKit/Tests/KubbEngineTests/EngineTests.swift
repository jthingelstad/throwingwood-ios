import CryptoKit
import Foundation
import Testing

@testable import KubbEngine

@Suite struct EngineTests {
  /// The vendored Lua is what engine.json says, byte for byte
  /// (scripts/vendor-engine.sh check does the same from the shell).
  @Test func vendoredFilesMatchTheManifest() throws {
    let dir = try Engine.bundled()
    let engine = try Engine()
    #expect(engine.manifest.files.count > 40)
    for (name, sha) in engine.manifest.files {
      let data = try Data(contentsOf: dir.appending(path: name))
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      #expect(digest == sha, "\(name)")
    }
  }

  @Test func aMatchStartsAndHashesTheSameEveryTime() throws {
    let options = #"{"mode":"match","seed":42,"cpu":"both","maxTurns":4}"#
    let a = try Engine()
    let b = try Engine()
    _ = try a.call("new", json: options)
    _ = try b.call("new", json: options)
    let hash = try a.hash()
    #expect(hash.count == 8)
    #expect(try b.hash() == hash)
    // A snapshot restored elsewhere is the same match.
    let c = try Engine()
    _ = try c.call("restore", json: a.call("snapshot"))
    #expect(try c.hash() == hash)
  }

  @Test func refusalsAreErrors() throws {
    let engine = try Engine()
    #expect {
      try engine.call("snapshot")
    } throws: { error in
      guard case EngineError.call(let method, let message) = error else { return false }
      return method == "snapshot" && message.contains("no session")
    }
    #expect(throws: EngineError.self) { try engine.call("noSuchMethod") }
  }

  @Test func aBrokenModuleFailsToLoad() throws {
    let manifest = EngineManifest(source: "test", commit: "0", files: [:])
    #expect(throws: EngineError.self) {
      try Engine(sources: ["web/api": "this is not lua"], manifest: manifest)
    }
  }
}
