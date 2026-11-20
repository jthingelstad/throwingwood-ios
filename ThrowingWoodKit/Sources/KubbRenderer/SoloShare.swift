import Foundation
import KubbRooms

// Sharing a finished match against the computer from its winner card (the web's
// docs/REEL.md "Sharing a match against the computer", src/ui/share.js; the wire, words
// and reducer are KubbRooms' Share.swift). The match is the one kept on disk
// (SoloTrail.swift), and only when it is the match on the screen.

extension FinishedSoloMatch {
  /// The match as a share is made from it. `now`: the last snapshot, when at hand.
  public func shareSource(now: String? = nil) -> ShareSource {
    ShareSource(
      engine: engine, start: start, actions: entries.map(\.action), hashes: entries.map(\.hash),
      winner: winner, now: now)
  }
  /// The hash after the last action: what identifies this finished match.
  public var finalHash: String? { entries.last?.hash }
}

/// A finished match on the screen that may be shared, and what identifies it.
public struct ShareableMatch: Sendable {
  /// The hash of the finished match (the hash after its last action).
  public let key: String
  public let source: ShareSource
  /// What the name field starts with (the web's nameFromMatch).
  public let name: String
}

extension PitchSession {
  /// The match on the winner card, if it may be shared: a finished match against the
  /// computer (not online, not practice) whose whole trail is kept on disk and ends on
  /// the match shown. A finished save restored by a build from before the trail, or a
  /// match resumed from one, has none.
  public func shareableMatch(save: MatchSave) -> ShareableMatch? {
    guard onlineAction == nil, need?.kind == "over", let finished = save.finishedMatch(),
      finished.complete, let key = finished.finalHash, (try? engine.hash()) == key
    else { return nil }
    let source = finished.shareSource(now: try? engine.call("snapshot"))
    guard source.shareable else { return nil }
    return ShareableMatch(key: key, source: source, name: ShareName.fromMatch(start: source.start))
  }

  /// The `share` message for that match under the name on the card, renamed by this
  /// session's engine.
  public func shareMessage(_ source: ShareSource, name: String) throws -> ShareMade {
    try ShareMessage.make(engine: engine, source: source, name: name)
  }
}

/// The share card's state for one finished match (the web's `Share`): the name typed,
/// the message as sent (sent again as it is on TRY AGAIN), and the reducer's state.
/// Nothing is sent before `send`. The answer is read even with the card closed.
@Observable @MainActor public final class SoloShare {
  public struct Hooks {
    /// One `share` message on a socket of its own, and the server's answer.
    public var send: @MainActor (JSONText) async throws -> ShareReply
    /// Whether the device has a network path now (offline sends nothing).
    public var reachable: @MainActor () -> Bool
    public init(
      send: @escaping @MainActor (JSONText) async throws -> ShareReply,
      reachable: @escaping @MainActor () -> Bool
    ) {
      self.send = send
      self.reachable = reachable
    }
  }

  /// The finished match this is for.
  public let key: String
  public private(set) var state = ShareState()
  /// The field's text, as typed (cut to 16 characters).
  public private(set) var name: String
  /// SHARE was pressed with a name the reel cannot take: say why even when empty.
  public private(set) var tried = false
  /// The last thing typed was cut to 16 characters: say so.
  public private(set) var clipped = false
  /// Messages sent, for tests.
  public private(set) var sent = 0
  /// A code came back: the reel card takes over (called once).
  public var onShared: (@MainActor (String) -> Void)?

  private let make: @MainActor (String) throws -> ShareMade
  private let hooks: Hooks
  private var message: JSONText?

  public init(
    key: String, name: String, make: @escaping @MainActor (String) throws -> ShareMade, hooks: Hooks
  ) {
    self.key = key
    self.name = name
    self.make = make
    self.hooks = hooks
  }

  public var view: ShareState.View { state.view }
  /// The name as it would go, trimmed.
  public var trimmed: String { ShareName.jsTrimmed(name) }
  /// Why the name will not do (SHARE faded while there is one).
  public var problem: ShareName.Problem? { ShareName.problem(trimmed) }
  /// The line under the field: why the name will not do, once there is something to
  /// say (a name typed, or SHARE pressed), or that it was cut.
  public var say: String? {
    if clipped { return ShareWords.name(.long) }
    guard let problem, tried || !trimmed.isEmpty else { return nil }
    return ShareWords.name(problem)
  }

  /// The field changed: cut to 16 characters, said when it was.
  public func type(_ text: String) {
    let cut = ShareName.clip(text)
    clipped = cut != text
    name = cut
  }

  /// The card opened again: a refusal that may pass later starts over.
  public func open() {
    tried = false
    clipped = false
    state = state.step(.open)
  }

  /// SHARE AND MAKE THE REEL, and TRY AGAIN.
  public func send() {
    if state.phase == .idle {
      let name = trimmed
      if ShareName.problem(name) != nil {
        tried = true
        return
      }
      let made: ShareMade
      do { made = try make(name) } catch { made = .refused(.doesNotReplay) }
      switch made {
      case .refused(let why):
        state = state.step(.refuse(why))
        return
      case .message(let text, _): message = text
      }
    }
    state = state.step(.send)
    guard state.phase == .sending, let message else { return }
    guard hooks.reachable() else {
      state = state.step(.error("unavailable"))  // nothing is sent
      return
    }
    sent += 1
    Task { [weak self, hooks] in
      let event: ShareState.Event
      do { event = .answer(try await hooks.send(message)) } catch {
        event = .error(RoomsClient.shareErrorCode(error))
      }
      self?.answered(event)
    }
  }

  private func answered(_ event: ShareState.Event) {
    state = state.step(event)
    if state.phase == .shared, let code = state.code { onShared?(code) }
  }
}
