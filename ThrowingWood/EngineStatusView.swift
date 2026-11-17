import KubbEngine
import SwiftUI

/// The placeholder screen until the game has one: the engine loaded, a seeded
/// computer-against-computer match started, and its hash, which is the web's
/// for the same seed and throws (KubbEngineTests proves it).
struct EngineStatusView: View {
  @State private var status = EngineStatus()

  var body: some View {
    NavigationStack {
      List {
        Section("Engine") {
          LabeledContent("Lua", value: status.lua)
          LabeledContent("Engine", value: status.commit)
          LabeledContent("Loaded in", value: status.loadTime)
        }
        Section("Match, seed \(EngineStatus.seed)") {
          LabeledContent("Throws", value: "\(status.throwCount)")
          LabeledContent("Hash", value: status.hash).monospaced()
          Button("Computer throws") { status.throwOnce() }
            .disabled(status.over || status.error != nil)
        }
        if let error = status.error {
          Section("Error") { Text(error).foregroundStyle(.red) }
        }
        Section {
          LabeledContent("Version", value: Bundle.main.versionText)
        }
      }
      .navigationTitle("Throwing Wood")
    }
    .task { status.load() }
  }
}

@MainActor @Observable
final class EngineStatus {
  static let seed = 1

  private var engine: Engine?
  var lua = "…"
  var commit = "…"
  var loadTime = "…"
  var hash = "…"
  var throwCount = 0
  var over = false
  var error: String?

  func load() {
    guard engine == nil else { return }
    do {
      let started = ContinuousClock.now
      let engine = try Engine()
      loadTime = (ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds]))
      lua = engine.luaVersion
      commit = String(engine.manifest.commit.prefix(7))
      _ = try engine.call("new", json: #"{"mode":"match","seed":\#(Self.seed),"cpu":"both"}"#)
      hash = try engine.hash()
      self.engine = engine
    } catch {
      self.error = "\(error)"
    }
  }

  /// Runs frames until the computer releases its next throw, as a screen would.
  func throwOnce() {
    guard let engine else { return }
    do {
      for _ in 0..<10_000 {
        let frame = try engine.call("frame", json: #"{"dt":0.016666666666666666}"#)
        if frame.contains(#""action":"#) { break }
      }
      throwCount += 1
      hash = try engine.hash()
      over = try engine.call("need").contains(#""kind":"over""#)
    } catch {
      self.error = "\(error)"
    }
  }
}

extension Bundle {
  /// "0.1 (12)": the version and build that scripts/version.sh stamped.
  var versionText: String {
    let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(version) (\(build))"
  }
}
