import Foundation

/// One socket, confined with its client to the main actor. Tests supply a transport
/// factory; production uses Foundation only. Each send is one text frame: the pitch
/// protocol has no splitting into parts (backend/pitch-server/PROTOCOL.md section 1).
@MainActor public protocol PitchTransport: AnyObject {
  func send(_ text: String) async throws
  func receive() async throws -> String
  func close()
}

@MainActor public final class WebSocketTransport: PitchTransport {
  /// Bytes a frame may have here: twice the pitch's 128 KB limit.
  public static let maximumMessageSize = 256 * 1024
  private let session: URLSession
  private let socket: URLSessionWebSocketTask

  public init(request: URLRequest) {
    session = URLSession(configuration: .ephemeral)
    socket = session.webSocketTask(with: request)
    // The pitch takes a message of up to 128 KB, and a join with the whole state (the
    // lobby, the match's start info and its head snapshot) can be most of that. Room to
    // spare: a frame the pitch sent is never one this side cannot read.
    socket.maximumMessageSize = Self.maximumMessageSize
    socket.resume()
  }

  public func send(_ text: String) async throws { try await socket.send(.string(text)) }
  public func receive() async throws -> String {
    switch try await socket.receive() {
    case .string(let text): return text
    case .data: throw PitchError("bad-message", "The pitch uses text frames.")
    @unknown default: throw PitchError("bad-message", "Unknown frame.")
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

/// A watcher's own member id, kept for the app's run (the web's `observerId()`, kept for
/// the tab). The pitch gives a join with a known id that member's place (and a member's
/// role is fixed while it is on the pitch), so an observer must never join under the
/// player's id (PROTOCOL.md section 3).
@MainActor public final class ObserverMemberIDStore: MemberIDStore {
  public static let shared = ObserverMemberIDStore()
  private var id: String?
  public init() {}
  public func load() -> String? { id }
  public func save(_ id: String) { self.id = id }
}

/// The ids a pitch joins with: the player's own, or the watcher's when observing. The
/// watcher's is never the player's.
@MainActor public struct WatcherIDStore: MemberIDStore {
  let observer: any MemberIDStore
  let player: any MemberIDStore
  public func load() -> String? {
    guard let id = observer.load(), id != player.load() else { return nil }
    return id
  }
  public func save(_ id: String) { observer.save(id) }
}

extension MemberIDStore {
  /// The store a pitch joins with: this one to play, the watcher's own to observe.
  public func joining(observing: Bool, observer: any MemberIDStore = ObserverMemberIDStore.shared)
    -> any MemberIDStore
  {
    observing ? WatcherIDStore(observer: observer, player: self) : self
  }
}

public struct PitchError: Error, Sendable, Equatable, CustomStringConvertible {
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
