import Foundation

enum RoomsConfiguration {
  static var url: URL {
    #if targetEnvironment(simulator)
      let port = UInt16(ProcessInfo.processInfo.environment["ROOMS_DEV_PORT"] ?? "") ?? 8788
      return URL(string: "ws://127.0.0.1:\(port)")!
    #else
      return URL(string: "wss://throwingwood.com/ws")!
    #endif
  }
  /// Where reels are served: the site. A simulator build reads them from the web's
  /// local preview (`npm run preview`, 127.0.0.1:4322), or REELS_DEV_PORT.
  static var site: URL {
    #if targetEnvironment(simulator)
      let port = UInt16(ProcessInfo.processInfo.environment["REELS_DEV_PORT"] ?? "") ?? 4322
      return URL(string: "http://127.0.0.1:\(port)")!
    #else
      return URL(string: "https://throwingwood.com")!
    #endif
  }
}
