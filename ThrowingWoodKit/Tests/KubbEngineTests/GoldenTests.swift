import Foundation
import Testing

@testable import KubbEngine

/// `Fixtures/golden-hashes.json` is what the web's WebAssembly engine gives
/// for `Fixtures/drive.lua` (tools/golden-hashes.mjs). The native engine must
/// give every hash identically: then a match started on a phone and one in a
/// browser are the same match, throw for throw.
struct Golden: Decodable {
  struct Match: Decodable {
    let opts: JSONValue
    let start: String
    /// [type, hash after the action, FNV of the action's JSON]
    let actions: [[String]]
  }

  struct Replay: Decodable {
    let file: String
    let start: String
    let hashes: [String]
    let differs: Bool
  }

  struct Probe: Decodable {
    let fn: String
    let args: [String]
    let bits: String
  }

  struct Source: Decodable {
    let source: String
    let commit: String
  }

  let wasmoon: String
  let lua: String
  let engine: Source
  let matches: [Match]
  let replay: Replay
  let math: [Probe]

  static let shared: Golden = {
    let url = Bundle.module.url(forResource: "Fixtures/golden-hashes", withExtension: "json")!
    return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
  }()

  static func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
  }
}

/// Any JSON, kept as it was read so it can be handed back to the engine.
enum JSONValue: Decodable, Encodable {
  case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}

/// An engine with the driver loaded beside the game.
func drivingEngine() throws -> Engine {
  let engine = try Engine(directory: Engine.bundled(), extra: ["test/drive": Golden.fixture("drive.lua")])
  try engine.run(#"import "test/drive""#, name: "=test")
  return engine
}

@Suite struct GoldenTests {
  let golden = Golden.shared

  @Test func goldenIsForTheVendoredEngine() throws {
    let engine = try Engine()
    #expect(engine.manifest.commit == golden.engine.commit, "run tools/golden-hashes.mjs after vendoring")
    #expect(golden.lua == "Lua 5.4")
    #expect(engine.luaVersion == "Lua 5.4.5")
  }

  /// The arguments where Apple's libm and musl's round the last bit
  /// differently: the engine's Lua gives musl's (the web's) answer.
  @Test func mathIsTheWebsMath() throws {
    let engine = try drivingEngine()
    let cases = golden.math.map { [$0.fn] + $0.args }
    let text = try engine.callGlobal("mathProbe", String(decoding: JSONEncoder().encode(cases), as: UTF8.self))
    let got = try JSONDecoder().decode([String].self, from: Data(text.utf8))
    for (probe, bits) in zip(golden.math, got) {
      #expect(bits == probe.bits, "\(probe.fn)(\(probe.args.joined(separator: ", ")))")
    }
  }

  /// The probe is worth something only where the platform's own libm differs
  /// from musl's on it, as Apple's does: then a build that linked Lua to
  /// Apple's libm by mistake fails `mathIsTheWebsMath` and every match below.
  @Test func platformMathDiffersOnTheProbe() {
    func double(_ hex: String) -> Double { Double(bitPattern: UInt64(hex.dropFirst(2), radix: 16)!) }
    let platform: [String: (Double, Double) -> Double] = [
      "sin": { a, _ in Foundation.sin(a) }, "cos": { a, _ in Foundation.cos(a) },
      "tan": { a, _ in Foundation.tan(a) }, "asin": { a, _ in Foundation.asin(a) },
      "acos": { a, _ in Foundation.acos(a) }, "atan": { a, b in Foundation.atan2(a, b) },
      "exp": { a, _ in Foundation.exp(a) }, "log": { a, _ in Foundation.log(a) },
      "log2": { a, _ in Foundation.log2(a) }, "log10": { a, _ in Foundation.log10(a) },
      "pow": { a, b in Foundation.pow(a, b) },
    ]
    let differing = golden.math.filter { probe in
      let f = platform[probe.fn]!
      let r = f(double(probe.args[0]), probe.args.count > 1 ? double(probe.args[1]) : 0)
      return String(format: "0x%016llx", r.bitPattern) != probe.bits
    }
    #expect(differing.count > 0)
  }

  @Test(arguments: 0..<12) func matchPlaysAsOnTheWeb(index: Int) throws {
    let match = try #require(golden.matches.indices.contains(index) ? golden.matches[index] : nil)
    let engine = try drivingEngine()
    let opts = String(decoding: try JSONEncoder().encode(match.opts), as: UTF8.self)
    let started = ContinuousClock.now
    let text = try engine.callGlobal("driveMatch", opts)
    let elapsed = ContinuousClock.now - started
    struct Out: Decodable { let start: String; let actions: [[String]]; let releaseCpu: Double }
    let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
    #expect(out.start == match.start)
    #expect(out.actions.count == match.actions.count)
    if let i = Array(zip(out.actions, match.actions)).firstIndex(where: { $0 != $1 }) {
      Issue.record("match \(index + 1) leaves the web's at action \(i + 1): \(out.actions[i]) vs \(match.actions[i])")
    }
    let ms = elapsed / .milliseconds(1)
    let each = Double(max(1, out.actions.count))
    print(
      "match \(index + 1): \(out.actions.count) actions, \(Int(ms)) ms (\(String(format: "%.1f", ms / each)) ms an action",
      "with the computer's think frames; \(String(format: "%.2f", out.releaseCpu * 1000 / each)) ms CPU a throw's release)")
  }

  @Test func recordedMatchReplaysAsOnTheWeb() throws {
    let engine = try drivingEngine()
    let text = try engine.callGlobal("driveReplay", Golden.fixture(golden.replay.file))
    struct Out: Decodable { let start: String; let hashes: [String]; let differs: Bool }
    let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
    #expect(out.start == golden.replay.start)
    #expect(out.hashes == golden.replay.hashes)
    #expect(out.differs == golden.replay.differs)
  }
}
