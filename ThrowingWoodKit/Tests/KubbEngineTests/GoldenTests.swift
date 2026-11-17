import Foundation
import Testing

@testable import KubbEngine

/// kubb-engine's golden corpus (`Fixtures/golden/hashes.json`, vendored with
/// its driver `Fixtures/golden/drive.lua` from the same release by
/// scripts/vendor-engine.sh): the hash after every action of twelve seeded
/// computer-against-computer matches on the engine's reference platform, the
/// web's WebAssembly Lua with musl's libm (kubb-engine docs/DETERMINISM.md).
/// The native engine must give every hash identically: then a match started
/// on a phone and one in a browser are the same match, throw for throw.
struct Corpus: Decodable {
  struct Winner: Decodable, Equatable {
    let winner: String
    let turns: Int
    let thrown: Int
    let hits: Int
  }

  struct Action: Decodable, Equatable {
    let type: String
    let hash: String
  }

  struct Match: Decodable {
    let name: String
    let start: String
    let turns: Int
    let winner: Winner
    let actions: [Action]
  }

  let version: String
  let tune: String
  let matches: [Match]

  static let shared: Corpus = {
    let url = Bundle.module.url(forResource: "Fixtures/golden/hashes", withExtension: "json")!
    return try! JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
  }()
}

/// Arguments where Apple's libm and musl's round the last bit differently,
/// with the web's answers (`Fixtures/math-probe.json`).
struct MathProbe: Decodable {
  struct Probe: Decodable {
    let fn: String
    let args: [String]
    let bits: String
  }

  let probes: [Probe]

  static let shared: MathProbe = {
    let url = Bundle.module.url(forResource: "Fixtures/math-probe", withExtension: "json")!
    return try! JSONDecoder().decode(MathProbe.self, from: Data(contentsOf: url))
  }()
}

func fixture(_ name: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
  return try String(contentsOf: url, encoding: .utf8)
}

/// An engine with the golden driver and the maths probe loaded beside it.
func drivingEngine() throws -> Engine {
  let engine = try Engine(
    directory: Engine.bundled(), appVersion: testAppVersion,
    extra: ["tests/golden/drive": fixture("golden/drive.lua"), "test/probe": fixture("probe.lua")])
  try engine.run(
    """
    import "tests/golden/drive"
    import "test/probe"
    function goldenMatch(i)
      local m = tw.golden.matches()[tonumber(i)]
      return tw.web.json.encode(tw.golden.play(m))
    end
    """, name: "=test")
  return engine
}

let testAppVersion = "0.0-test"

/// Set KUBB_APPLE_LIBM_PROOF=1 for the manual proof (AGENTS.md "Proving
/// Apple's libm fails"); never in CI, since Apple may change its libm.
let appleLibmProof = ProcessInfo.processInfo.environment["KUBB_APPLE_LIBM_PROOF"] == "1"

@Suite struct GoldenTests {
  let corpus = Corpus.shared

  @Test func corpusIsForTheVendoredEngine() throws {
    let engine = try Engine(appVersion: testAppVersion)
    #expect(corpus.version == engine.engineVersion, "run scripts/vendor-engine.sh sync")
    #expect(corpus.tune == Engine.tune)
    #expect(corpus.matches.count == 12)
    #expect(engine.luaVersion == "Lua 5.4.5")
  }

  /// The arguments where Apple's libm and musl's round the last bit
  /// differently: the engine's Lua gives musl's (the web's) answer.
  @Test func mathIsTheWebsMath() throws {
    let engine = try drivingEngine()
    let probes = MathProbe.shared.probes
    let cases = probes.map { [$0.fn] + $0.args }
    let text = try engine.callGlobal("mathProbe", String(decoding: JSONEncoder().encode(cases), as: UTF8.self))
    let got = try JSONDecoder().decode([String].self, from: Data(text.utf8))
    #expect(got.count == probes.count)
    for (probe, bits) in zip(probes, got) {
      #expect(bits == probe.bits, "\(probe.fn)(\(probe.args.joined(separator: ", ")))")
    }
  }

  /// The probe is worth something only where the platform's own libm differs
  /// from musl's on it, as Apple's does. A manual check, not CI.
  @Test(.enabled(if: appleLibmProof)) func appleLibmDiffersOnTheProbe() {
    func double(_ hex: String) -> Double { Double(bitPattern: UInt64(hex.dropFirst(2), radix: 16)!) }
    let platform: [String: (Double, Double) -> Double] = [
      "sin": { a, _ in Foundation.sin(a) }, "cos": { a, _ in Foundation.cos(a) },
      "tan": { a, _ in Foundation.tan(a) }, "asin": { a, _ in Foundation.asin(a) },
      "acos": { a, _ in Foundation.acos(a) }, "atan": { a, b in Foundation.atan2(a, b) },
      "exp": { a, _ in Foundation.exp(a) }, "log": { a, _ in Foundation.log(a) },
      "log2": { a, _ in Foundation.log2(a) }, "log10": { a, _ in Foundation.log10(a) },
      "pow": { a, b in Foundation.pow(a, b) },
    ]
    let probes = MathProbe.shared.probes
    let differing = probes.filter { probe in
      let f = platform[probe.fn]!
      let r = f(double(probe.args[0]), probe.args.count > 1 ? double(probe.args[1]) : 0)
      return String(format: "0x%016llx", r.bitPattern) != probe.bits
    }
    print("Apple's libm differs from musl's on \(differing.count) of \(probes.count) probes")
    #expect(differing.count > 0)
  }

  @Test(arguments: 0..<12) func matchPlaysAsOnTheReference(index: Int) throws {
    let want = try #require(corpus.matches.indices.contains(index) ? corpus.matches[index] : nil)
    let engine = try drivingEngine()
    let started = ContinuousClock.now
    let text = try engine.callGlobal("goldenMatch", String(index + 1))
    let elapsed = ContinuousClock.now - started
    struct Played: Decodable {
      let name: String
      let start: String
      let turns: Int?
      let winner: Corpus.Winner?
      let actions: [Corpus.Action]
    }
    let got = try JSONDecoder().decode(Played.self, from: Data(text.utf8))
    #expect(got.name == want.name)
    #expect(got.start == want.start)
    let agree = zip(got.actions, want.actions).prefix { $0 == $1 }.count
    if got.actions.count != want.actions.count || agree != want.actions.count {
      Issue.record(
        "\(want.name) leaves the corpus at action \(agree + 1): \(agree) of \(want.actions.count) agree, \(got.actions.count) played")
    }
    #expect(got.turns == want.turns)
    #expect(got.winner == want.winner)
    print(
      "golden \(want.name): \(agree) of \(want.actions.count) actions match,",
      "\(Int(elapsed / .milliseconds(1))) ms")
  }
}
