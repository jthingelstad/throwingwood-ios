import Foundation

/// One socket, confined with its client to the main actor. Tests supply a transport
/// factory; production uses Foundation only. Each send is one text message/frame.
@MainActor public protocol RoomsTransport: AnyObject {
  func send(_ text: String) async throws
  func receive() async throws -> String
  func close()
}

@MainActor public final class WebSocketTransport: RoomsTransport {
  private let session: URLSession
  private let socket: URLSessionWebSocketTask

  public init(request: URLRequest) {
    session = URLSession(configuration: .ephemeral)
    socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = 32 * 1024
    socket.resume()
  }

  public func send(_ text: String) async throws { try await socket.send(.string(text)) }
  public func receive() async throws -> String {
    switch try await socket.receive() {
    case .string(let text): return text
    case .data: throw RoomError("bad-message", "Rooms use text frames.")
    @unknown default: throw RoomError("bad-message", "Unknown frame.")
    }
  }
  public func close() {
    socket.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}

@MainActor public protocol MemberIDStore {
  func load() -> String?
  func save(_ id: String)
}

@MainActor public struct DeviceMemberIDStore: MemberIDStore {
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  public func load() -> String? { defaults.string(forKey: "kubb.member") }
  public func save(_ id: String) { defaults.set(id, forKey: "kubb.member") }
}

public struct RoomError: Error, Sendable, Equatable, CustomStringConvertible {
  public let code: String
  public let message: String
  public let re: String?
  public init(_ code: String, _ message: String = "", re: String? = nil) {
    self.code = code
    self.message = message
    self.re = re
  }
  public var description: String { "\(code): \(message)" }
}
