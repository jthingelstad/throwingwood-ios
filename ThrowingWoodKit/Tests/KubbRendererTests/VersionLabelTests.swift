import KubbEngine
import Testing

@testable import KubbRenderer

/// `<app version> (<engine version>)` (VersionLabel.swift).
@MainActor struct VersionLabelTests {
  @Test func theLabelIsTheAppAndTheNewestEngine() {
    let label = VersionLabel(app: "0.2", build: "114", engine: "0.8.1", also: ["0.7.4"])
    #expect(label.text == "0.2 (0.8.1)")
    #expect(label.detail == ["build 114", "Also plays 0.7.4"])
    #expect(VersionLabel(app: "0.2", engine: "0.8.1").detail.isEmpty)
  }

  /// The engine's version comes from the engine itself, the newest in the parentheses.
  /// The build carries 1.0 beside the newest, so the detail says "Also plays 1.0.0".
  @Test func thisBuildsLabelReadsItsEngines() throws {
    let session = try PitchSession(appVersion: "0.2")
    let newest = try Engine(appVersion: "0.2").engineVersion
    let label = session.versionLabel
    #expect(label.text == "0.2 (\(newest))")
    #expect(label.engine == Engine.carriedVersions.first)
    #expect(label.also == Array(Engine.carriedVersions.dropFirst()) && label.also.first?.hasPrefix("1.0.") == true)
    #expect(label.detail.contains { $0.hasPrefix("Also plays 1.0") })
    #expect(!label.text.contains("build"))
  }
}
