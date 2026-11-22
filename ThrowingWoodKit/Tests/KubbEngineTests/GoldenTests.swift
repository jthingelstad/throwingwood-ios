import Foundation
import Testing

@testable import KubbEngine

/// kubb-engine's golden corpus (`Fixtures/golden/hashes.json`, vendored with
/// its driver `Fixtures/golden/drive.lua` from the same release by
/// scripts/vendor-engine.sh; an older engine's, were one carried, in
/// `Fixtures/engines/<mm>/golden/`):
/// the hash after every action of its seeded matches (twelve computer against
/// computer, since 0.8.0 a thirteenth of a person's short batons against the
/// computer, and since 0.12.0 a person raised automatically against the pro
/// computer and the beginner computer on both sides) on the engine's reference platform, the web's WebAssembly Lua with
/// musl's libm (kubb-engine docs/DETERMINISM.md). Every engine the build carries
/// must give every hash of its own corpus identically: then a match started on a
/// phone and one in a browser are the same match, throw for throw.
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

  static let shared = load(minor: Engine.newest)

  /// The corpus vendored with the carried engine of major.minor `minor`.
  static func load(minor: String) -> Corpus {
    let url = Bundle.module.url(forResource: goldenFolder(minor) + "/hashes", withExtension: "json")!
    return try! JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
  }
}

/// Where the golden driver and corpus of the carried engine `minor` are.
func goldenFolder(_ minor: String) -> String {
  minor == Engine.newest ? "Fixtures/golden" : "Fixtures/engines/\(minor)/golden"
}

/// The corpus each carried engine is pinned to, and its size: a new engine, or one we
/// decide to support again (docs/ENGINES.md), changes this on purpose.
let pinnedCorpora: [String: (corpus: String, matches: Int)] = [
  "1.0": ("1.0.0", 21)
]

/// One golden match on one carried engine.
struct GoldenCase: Sendable, CustomTestStringConvertible {
  let minor: String
  let index: Int
  var testDescription: String { "\(minor) #\(index + 1)" }
}

let goldenCases: [GoldenCase] = Engine.carried.flatMap { mm in
  (0..<(pinnedCorpora[mm]?.matches ?? 0)).map { GoldenCase(minor: mm, index: $0) }
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

/// An engine (the carried one of `minor`, or the newest) with its golden driver and
/// the maths probe loaded beside it.
func drivingEngine(minor: String = Engine.newest) throws -> Engine {
  let driver = String(goldenFolder(minor).dropFirst("Fixtures/".count)) + "/drive.lua"
  let engine = try Engine(
    directory: Engine.bundled(minor: minor), appVersion: testAppVersion,
    extra: ["tests/golden/drive": fixture(driver), "test/probe": fixture("probe.lua")])
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
    // Hash-neutral releases retain the exact corpus from the last change to match physics.
    let expected = ["0.4.1": "0.2.0", "0.5.1": "0.5.0", "0.7.1": "0.5.0", "0.7.2": "0.5.0", "0.7.3": "0.5.0", "0.7.4": "0.5.0", "0.8.1": "0.8.0", "0.8.2": "0.8.0", "0.13.1": "0.13.0", "0.13.2": "0.13.0", "0.13.3": "0.13.0", "0.13.4": "0.13.0", "0.15.1": "0.15.0"][engine.engineVersion] ?? engine.engineVersion
    #expect(corpus.version == expected, "run scripts/vendor-engine.sh sync")
    #expect(corpus.tune == Engine.tune)
    #expect(corpus.matches.count == pinnedCorpora[Engine.newest]?.matches)
    #expect(engine.luaVersion == "Lua 5.4.5")
  }

  /// Every engine the build carries, each with the corpus it is pinned to: the newest
  /// alone, since we support only the newest (docs/ENGINES.md). An engine it once
  /// carried (0.9, 0.8, 0.7) is not carried.
  @Test func everyCarriedEngineHasItsOwnCorpus() throws {
    #expect(Engine.carried == ["1.0"])
    #expect(Set(pinnedCorpora.keys) == Set(Engine.carried))
    for mm in Engine.carried {
      let engine = try Engine(minor: mm, appVersion: testAppVersion)
      #expect(engine.minor == mm)
      let corpus = Corpus.load(minor: mm)
      #expect(corpus.version == pinnedCorpora[mm]?.corpus, "\(mm): run scripts/vendor-engine.sh sync")
      #expect(corpus.matches.count == pinnedCorpora[mm]?.matches)
      #expect(corpus.tune == Engine.tune)
    }
    for gone in ["0.18", "0.17", "0.16", "0.9", "0.8", "0.7", "0.6"] {
      #expect(throws: EngineError.notCarried(gone)) { try Engine(minor: gone, appVersion: testAppVersion) }
    }
  }

  /// The bundle holds no engine beyond the supported ones (Supported.swift, from
  /// `OLDER`). SwiftPM leaves a resource folder in a built bundle when Package.swift stops
  /// copying it, so a cached or earlier build kept 0.9, 0.8 and 0.7 after they were
  /// dropped (CI, 2026-11-21). They are never carried; this says the build is stale.
  @Test func theBundleHoldsOnlyTheSupportedEngines() {
    let stale = Engine.bundledOlder.keys.filter { !Engine.supportedOlder.contains($0) }.sorted()
    #expect(stale.isEmpty, "stale build: \(stale) in the bundle; remove the built bundles and build again")
    #expect(Engine.carried == [Engine.newest] + Engine.supportedOlder)
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

  @Test(arguments: goldenCases) func matchPlaysAsOnTheReference(_ golden: GoldenCase) throws {
    let corpus = golden.minor == Engine.newest ? corpus : Corpus.load(minor: golden.minor)
    let index = golden.index
    let want = try #require(corpus.matches.indices.contains(index) ? corpus.matches[index] : nil)
    let engine = try drivingEngine(minor: golden.minor)
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
      "golden \(golden.minor) \(want.name): \(agree) of \(want.actions.count) actions match,",
      "\(Int(elapsed / .milliseconds(1))) ms")
  }
}
