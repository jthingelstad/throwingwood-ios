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
}
