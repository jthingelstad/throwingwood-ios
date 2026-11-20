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

  /// The engine's version comes from the engine itself, the newest in the parentheses
  /// and the others only as detail.
  @Test func thisBuildsLabelReadsItsEngines() throws {
    let session = try PitchSession(appVersion: "0.2")
    let newest = try Engine(appVersion: "0.2").engineVersion
    let label = session.versionLabel
    #expect(label.text == "0.2 (\(newest))")
    #expect(label.engine == Engine.carriedVersions.first)
    #expect(label.also == Array(Engine.carriedVersions.dropFirst()))
    #expect(!label.text.contains("build"))
    // a session playing an older match still names the newest
    if Engine.carried.count > 1 {
      try session.useEngine(minor: Engine.carried[1])
      #expect(session.versionLabel.text == "0.2 (\(newest))")
    }
  }
}
