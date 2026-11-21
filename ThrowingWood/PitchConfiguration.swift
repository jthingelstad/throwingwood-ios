import Foundation
import KubbPitch

/// Where the app plays online and what it calls, one value each.
///
/// - `server`: the pitch server, whose `/ws?pitch=<code>` is one pitch's socket and
///   whose `/open` is the open games list. Production is the pitch Worker's address,
///   which is not final and not deployed yet (the owner's call, the web's
///   docs/PITCH-SERVER.md); change it here when it is.
/// - `api`: the HTTPS calls that are not live play (report, replay, reel, share).
/// - `site`: where reels are served.
///
/// A debug build takes `PITCH_SERVER_URL`, `PITCH_API_URL` and `REELS_URL` from the
/// environment (a scheme's arguments), so it can play against a local pitch server
/// (`wrangler dev` on 127.0.0.1). A simulator build with none set uses 127.0.0.1:
/// `PITCH_DEV_PORT` (8797) for the pitch server, `API_DEV_PORT` (8798) for the API and
/// `REELS_DEV_PORT` (4322, the web's `npm run preview`) for reels. Never production
/// while testing.
enum PitchConfiguration {
  static let productionServer = URL(string: "wss://throwingwood-pitches.throwingwood.workers.dev")!
  static let productionAPI = URL(string: "https://throwingwood.com/api/")!
  static let productionSite = URL(string: "https://throwingwood.com")!

  static var server: URL {
    if let url = debugOverride("PITCH_SERVER_URL") { return url }
    #if targetEnvironment(simulator)
      return URL(string: "ws://127.0.0.1:\(port("PITCH_DEV_PORT", 8797))")!
    #else
      return productionServer
    #endif
  }
  static var api: URL {
    if let url = debugOverride("PITCH_API_URL") { return url }
    #if targetEnvironment(simulator)
      return URL(string: "http://127.0.0.1:\(port("API_DEV_PORT", 8798))/api/")!
    #else
      return productionAPI
    #endif
  }
  static var site: URL {
    if let url = debugOverride("REELS_URL") { return url }
    #if targetEnvironment(simulator)
      return URL(string: "http://127.0.0.1:\(port("REELS_DEV_PORT", 4322))")!
    #else
      return productionSite
    #endif
  }

  /// The API client for this build.
  @MainActor static var client: PitchAPI { PitchAPI(base: api, appVersion: GameModel.version) }

  private static func port(_ name: String, _ fallback: UInt16) -> UInt16 {
    UInt16(ProcessInfo.processInfo.environment[name] ?? "") ?? fallback
  }
  private static func debugOverride(_ name: String) -> URL? {
    #if DEBUG
      guard let text = ProcessInfo.processInfo.environment[name], let url = URL(string: text),
        url.scheme != nil
      else { return nil }
      return url
    #else
      return nil
    #endif
  }
}
