import Foundation
import KubbEngine
import KubbPitch

// Sharing a finished match against the computer from its winner card (the web's
// docs/REEL.md "Sharing a match against the computer", src/ui/share.js; the wire, words
// and reducer are KubbPitch' Share.swift). The match is the one kept on disk
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
  /// What the name row starts with (the web's nameFromMatch).
  public let name: String
}

extension PitchSession {
  /// The match on the winner card, if it may be shared: a finished match against the
  /// computer (not online, not practice) whose whole trail is kept on disk and ends on
  /// the match shown. A finished save restored by a build from before the trail, or a
  /// match resumed from one, has none.
  /// `deviceName` is the device's name, what the row starts with when the match's own
  /// side A name is not a generated name.
  public func shareableMatch(save: MatchSave, deviceName: String? = nil) -> ShareableMatch? {
    guard onlineAction == nil, need?.kind == "over", let finished = save.finishedMatch(),
      finished.complete, Engine.majorMinor(finished.engine) == engine.minor,
      let key = finished.finalHash, (try? engine.hash()) == key
    else { return nil }
    let source = finished.shareSource(now: try? engine.call("snapshot"))
    guard source.shareable else { return nil }
    return ShareableMatch(
      key: key, source: source, name: ShareName.fromMatch(start: source.start, names: names,
        fallback: names.valid(.player, deviceName).ok ? deviceName! : ((try? names.roll(.player))?.text ?? "")))
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
  /// The name on the reel, as the name row has it (a generated name).
  public private(set) var name: String
  /// SHARE was pressed with a name the reel cannot take: say why.
  public private(set) var tried = false
  /// Messages sent, for tests.
  public private(set) var sent = 0
  /// A code came back: the reel card takes over (called once).
  public var onShared: (@MainActor (String) -> Void)?

  private let make: @MainActor (String) throws -> ShareMade
  private let hooks: Hooks
  private var message: JSONText?
  /// The engine's names door: what the reel can take.
  public let names: Names

  public init(
    key: String, name: String, names: Names, make: @escaping @MainActor (String) throws -> ShareMade,
    hooks: Hooks
  ) {
    self.key = key
    self.name = name
    self.names = names
    self.make = make
    self.hooks = hooks
  }

  public var view: ShareState.View { state.view }
  /// Why the name will not do (SHARE faded while there is one).
  public var problem: ShareName.Problem? { ShareName.problem(name, names: names) }
  /// The line under the row: why the name will not do, once SHARE was pressed.
  public var say: String? {
    guard let problem, tried else { return nil }
    return ShareWords.name(problem)
  }

  /// The name row changed.
  public func set(_ text: String) {
    name = text
  }

  /// The card's name row ("Name on the reel"), starting from `name`.
  public var row: NameRowModel {
    if let r = rowMade { return r }
    let r = NameRowModel(names: names, kind: .player, text: name, label: ShareWords.label)
    if !names.valid(.player, name).ok { name = r.text }
    r.onChange = { [weak self] in self?.set($0) }
    rowMade = r
    return r
  }
  @ObservationIgnored private var rowMade: NameRowModel?

  /// The card opened again: a refusal that may pass later starts over.
  public func open() {
    tried = false
    state = state.step(.open)
  }

  /// SHARE AND MAKE THE REEL, and TRY AGAIN.
  public func send() {
    if state.phase == .idle {
      let name = self.name
      if ShareName.problem(name, names: names) != nil {
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
        event = .error(PitchAPI.errorCode(error))
      }
      self?.answered(event)
    }
  }

  private func answered(_ event: ShareState.Event) {
    state = state.step(event)
    if state.phase == .shared, let code = state.code { onShared?(code) }
  }
}
