import Foundation
import KubbEngine

/// What the app calls itself to a player (Jamie, 2026-11-20): its own version with the
/// Kubb Engine version beside it, `<app version> (<engine version>)`, as every Throwing
/// Wood app does, e.g. `0.2 (0.8.1)`. The parentheses hold only the newest engine's full
/// version (what new play runs on); the build number and any older engine the build
/// also carries are detail lines beneath it. Shown in the menus and sent in a feedback
/// report; never on the room wire, a rider or a kept match, which name only the engine
/// a match is played on.
public struct VersionLabel: Equatable, Sendable {
  public let app: String
  public let build: String?
  public let engine: String
  public let also: [String]

  public init(app: String, build: String? = nil, engine: String, also: [String] = []) {
    self.app = app
    self.build = build
    self.engine = engine
    self.also = also
  }

  /// This build: `engine` the newest engine's `engineVersion` (from a started engine),
  /// the older carried engines from their manifests.
  public init(app: String, build: String?, newest engine: String) {
    self.init(
      app: app, build: build, engine: engine,
      also: Engine.carriedVersions.filter { Engine.majorMinor($0) != Engine.majorMinor(engine) })
  }

  /// `0.2 (0.8.1)`.
  public var text: String { "\(app) (\(engine))" }

  /// Where detail is shown, under `text`: `build 114`, then `Also plays 0.7.4`.
  public var detail: [String] {
    var out: [String] = []
    if let build, !build.isEmpty { out.append("build \(build)") }
    if !also.isEmpty { out.append("Also plays " + also.joined(separator: ", ")) }
    return out
  }

  /// The app's own build number (CFBundleVersion, set by the TestFlight script).
  public static var bundleBuild: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  }
}

extension PitchSession {
  /// This build's label, with the newest engine's version from the engine itself.
  public var versionLabel: VersionLabel {
    VersionLabel(app: appVersion, build: VersionLabel.bundleBuild, newest: newestVersion)
  }
}
