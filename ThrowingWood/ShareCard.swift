import KubbRenderer
import KubbPitch
import SwiftUI

// MAKE A HIGHLIGHT REEL on the winner card of a match against the computer (the web's
// docs/REEL.md "Sharing a match against the computer" and "The share card", src/ui/
// share.js): the share card it opens before anything is sent, then the reel card for
// the code that comes back, with its link. And a shared match opened by its code (a
// sealed pitch): its winner card, from the room's kept replay.

/// A shared match opened by its code: the join was refused `sealed`, so it is shown
/// from the room's kept replay on a session of its own (never the solo match's).
@Observable @MainActor final class SealedPitch {
  /// `old`: the match was made on an engine this build no longer carries, so it is not
  /// shown (VersionWords.oldMatch), and trying again cannot mend it.
  /// `badNames`: the match holds a name the game did not make, so it is not shown
  /// (NameWords.badMatch).
  enum Phase { case loading, shown, failed, old, badNames }
  let code: String
  var phase = Phase.loading
  var board: PitchSession?
  /// The kept match, which its reel must be of.
  var match: ReelMatch?
  init(code: String) { self.code = code }
}

extension GameModel {
  /// The winner card of a solo match appeared: the share for it, when it may be shared
  /// (a finished match against the computer whose whole trail is kept and ends on the
  /// match shown). The same match keeps its share, and so its code.
  func prepareShare() {
    guard online == nil, sealed == nil else { return }
    #if targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["SHARE_REVIEW"] != nil { return }  // its own
    #endif
    guard let pitch = offline, let found = pitch.shareableMatch(save: save, deviceName: name) else {
      share = nil
      return
    }
    if share?.key == found.key { return }
    let share = SoloShare(
      key: found.key, name: found.name, names: pitch.names,
      make: { [weak pitch] name in
        guard let pitch else { throw PitchError("closed") }
        return try pitch.shareMessage(found.source, name: name)
      },
      hooks: SoloShare.Hooks(
        send: { message in
          try await PitchConfiguration.client.share(message)
        },
        reachable: { NetworkPath.shared.reachable }))
    share.onShared = { [weak self, weak share] code in
      // an answer for a match that is no longer the winner card's changes nothing
      guard let self, let share, self.share === share else { return }
      self.shared(code)
    }
    self.share = share
  }

  /// MAKE A HIGHLIGHT REEL: the share card, or once shared the reel card itself.
  func openShare() {
    guard let share else { return }
    if let code = share.state.code {
      openReel(code: code, linked: true)
      return
    }
    share.open()
    shareReturn = screen
    screen = .share
  }

  /// NOT NOW and BACK. An answer on its way is still read.
  func closeShare() {
    if screen == .share { screen = shareReturn }
  }

  /// A code came back: the reel card for it takes over when the share card is still
  /// shown, and asks for the reel at once (the press was SHARE AND MAKE THE REEL). Closed
  /// meanwhile, the share keeps the code and the reel is made when its card is opened
  /// (nothing is sent off screen, and another pitch's reel card is never replaced).
  func shared(_ code: String) {
    guard screen == .share else { return }
    makeReel(code: code, linked: true)
    reelReturn = shareReturn
    screen = .reel
  }


  func reelHooksFor(_ code: String) -> HighlightReel.Hooks {
    reelHooksOverride?(code) ?? Self.reelHooks(code)
  }

  /// A sealed pitch (the API's replay says so): leave it and show its kept match.
  func openSealed(_ link: PitchLink) {
    leaveOnline()
    let pitch = SealedPitch(code: link.code)
    sealed = pitch
    screen = .sealed
    loadSealed(pitch)
  }

  /// Reads the pitch's kept replay (the API's `replay`, which starts nothing) and puts its last
  /// snapshot on a session of its own: the winner card shows the result.
  func loadSealed(_ pitch: SealedPitch) {
    pitch.phase = .loading
    screen = .sealed
    let code = pitch.code
    Task { [weak self] in
      let kept = try? await PitchConfiguration.client.replay(pitch: code)
      guard let self, self.sealed === pitch else { return }
      self.showSealed(pitch, kept: kept ?? nil)
    }
  }

  func showSealed(_ pitch: SealedPitch, kept: KeptReplay?) {
    do {
      guard let kept, let snap = kept.snap else { throw PitchError("no-replay") }
      let board = try PitchSession(appVersion: Self.version)
      // someone else's match: on its own engine, through the engine's names check
      try board.restoreFromOutside(snap, replay: kept.raw, engine: kept.engine)
      board.dismissHandoff()
      guard board.need?.kind == "over" else { throw PitchError("not-over") }
      pitch.board = board
      pitch.match = kept.n.map { ReelMatch(n: $0, hash: kept.hash) }
      pitch.phase = .shown
      screen = .match
      refresh()
    } catch is OldMatch {
      pitch.phase = .old
      screen = .sealed
    } catch is BadNamesMatch {
      pitch.phase = .badNames
      screen = .sealed
    } catch {
      pitch.phase = .failed
    }
  }
}

/// The share card (the web's docs/REEL.md "The share card"): what sharing does, the name
/// on the reel, what the other side is called, when it was played, then SHARE AND MAKE
/// THE REEL and NOT NOW. Nothing is sent before SHARE. Once sent: CHECKING THE MATCH with
/// the slow bar, or the line of a refusal, with TRY AGAIN where asking again can mend it.
struct ShareCard: View {
  let model: GameModel
  let share: SoloShare
  @Environment(\.screenGeometry) private var screen
  @State private var since = Date()

  private var ipad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  var body: some View {
    let v = share.view
    // the buttons are the card's pinned row, so on a phone on its side (about 390 pt
    // tall) SHARE stays in view while the words above it scroll
    CardScreen(width: ipad ? 520 : 400) {
      VStack(alignment: .leading, spacing: 12) {
        Text(ShareWords.title).cardTitle()
        if v.form {
          form
        } else {
          if !v.line.isEmpty { Text(v.line).font(displayFont(24)) }
          if v.bar { SlowBar(since: since) }
          if !v.text.isEmpty { Text(v.text).fixedSize(horizontal: false, vertical: true) }
        }
      }
    } buttons: {
      if v.form {
        // side by side at the stack's own spacing, which a 375 pt phone needs (ButtonRow's
        // 12 would stack them there), one under the other where even that does not fit
        ViewThatFits(in: .horizontal) {
          HStack { formButtons }
          VStack(alignment: .leading) { formButtons }
        }
      } else {
        HStack {
          if v.retry {
            Button(ShareWords.tryAgain) { share.send() }.buttonStyle(WoodButton(accent: true))
          }
          Spacer(minLength: 0)
          Button(ShareWords.back) { model.closeShare() }.buttonStyle(WoodButton(accent: !v.retry))
        }
      }
    }
  }

  /// NOT NOW quiet at the left (leaving), SHARE AND MAKE THE REEL go, last.
  @ViewBuilder private var formButtons: some View {
    QuietButton(ShareWords.notNow) {
      model.closeShare()
    }
    Spacer(minLength: 0)
    Button(ShareWords.share) {
      since = Date()
      share.send()
    }
    .buttonStyle(WoodButton(accent: true)).disabled(share.problem != nil)
    .lineLimit(1)
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(ShareWords.about).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        // a row's label in the 1.0 system's face: Inter bold 14 capitals
        Text(ShareWords.label).labelStyle()
        NameRowView(row: share.row, size: 24)
      }
      Text(ShareWords.sides).fixedSize(horizontal: false, vertical: true)
      Text(ShareWords.when).font(bodyFont(14, relativeTo: .footnote)).fixedSize(horizontal: false, vertical: true)
      if let say = share.say {
        Text(say).font(.subheadline.bold()).accessibilityAddTraits(.updatesFrequently)
      }
    }
  }
}

/// A shared match while its replay is read, or when it could not be (the web's words).
struct SealedCard: View {
  let model: GameModel
  let pitch: SealedPitch
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch pitch.phase {
      case .failed:
        Text("PITCH \(pitch.code)").labelStyle()
        Text("Could not show the match").font(displayFont(38))
        Text(
          "This pitch is a shared match, and it could not be loaded just now. Try again in a moment."
        ).fixedSize(horizontal: false, vertical: true)
        Button(ShareWords.tryAgain) { model.loadSealed(pitch) }.buttonStyle(WoodButton(accent: true))
      case .old:
        Text("PITCH \(pitch.code)").labelStyle()
        Text(VersionWords.oldMatch).font(displayFont(30)).fixedSize(horizontal: false, vertical: true)
      case .badNames:
        Text("PITCH \(pitch.code)").labelStyle()
        Text(NameWords.badMatchTitle).font(displayFont(38))
        Text(NameWords.badMatch).fixedSize(horizontal: false, vertical: true)
      default:
        // as the join that led here said it
        Text("Connecting").font(displayFont(38))
        Text("Joining the pitch…")
      }
      Button("HOME", action: model.home).font(.headline).padding(.vertical, 5)
    }.cardScreen(width: 400)
  }
}

#if targetEnvironment(simulator)
  extension GameModel {
    /// The review tools' share card, with no network: SHARE_REVIEW names the state, the
    /// match behind it is the solo "over" fixture, and every answer is a stand-in
    /// (tools/share-snapshots.py). Only invented names.
    func beginShareReview(_ mode: String) {
      let code = "mapkubb2"
      if ["sealed", "sealedfailed", "sealedloading", "sealedold"].contains(mode) {
        let sealed = SealedPitch(code: code)
        self.sealed = sealed
        if mode == "sealed" || mode == "sealedold" {
          let fixture = try? String(
            contentsOf: URL.temporaryDirectory.appending(path: "review-solo.json"), encoding: .utf8)
          // a shared match holds only generated names (the review fixture's stand-in "You"
          // would not be shown), so the stand-in takes one here
          let snap = fixture?.replacingOccurrences(of: #""name":"You""#, with: #""name":"Brave Birch""#)
          // sealedold: the same match, kept as made on an engine this build does not carry
          showSealed(
            sealed,
            kept: KeptReplay(v: 1, n: 1, hash: nil, snap: snap, engine: mode == "sealedold" ? "0.9.0" : nil))
        } else {
          sealed.phase = mode == "sealedfailed" ? .failed : .loading
          screen = .sealed
        }
        return
      }
      reelHooksOverride = { _ in
        HighlightReel.Hooks(
          ask: { _ in .rendering(v: 1, tag: "r1-0.7") }, kept: { KeptReplay(v: 1, n: 1, hash: nil) },
          fetch: { _, _ in }, reachable: { true })
      }
      let answers: [String: ShareReply] = [
        "engine": ShareReply(code: nil, v: 0, why: "engine"),
        "doesnotreplay": ShareReply(code: nil, v: 0, why: "does-not-replay"),
        "busy": ShareReply(code: nil, v: 0, why: "busy"),
        "unavailable": ShareReply(code: nil, v: 0, why: "unavailable"),
        "shared": ShareReply(code: code, v: 1, why: nil),
        "sharedwinner": ShareReply(code: code, v: 1, why: nil),
      ]
      let share = SoloShare(
        key: "review", name: mode == "cardlong" ? "Zealous Mahogany" : "Brave Birch",
        names: offline!.names,
        make: { name in
          mode == "toolong" ? .refused(.tooLong) : .message(JSONText(#"{"t":"share"}"#), bytes: 13)
        },
        hooks: SoloShare.Hooks(
          send: { _ in
            switch mode {
            case "checking": try await Task.sleep(for: .seconds(3600))
            case "toomany": throw PitchError("too-many")
            case "failed", "notthistime": throw PitchError("failed")
            default: break
            }
            return answers[mode] ?? ShareReply(code: nil, v: 0, why: "unavailable")
          },
          reachable: { mode != "offline" }))
      share.onShared = { [weak self, weak share] code in
        guard let self, let share, self.share === share else { return }
        self.shared(code)
      }
      self.share = share
      screen = .match
      if mode == "winner" || mode == "sharedwinner" {
        if mode == "sharedwinner" {
          openShare()
          share.send()  // answered at once; then back to the winner card
          Task { @MainActor in
            while share.state.phase != .shared { try? await Task.sleep(for: .milliseconds(20)) }
            self.closeReel()
          }
        }
        return
      }
      openShare()
      switch mode {
      case "card", "cardlong": break
      case "notthistime":
        share.send()
        Task { @MainActor in
          while share.state.phase != .error { try? await Task.sleep(for: .milliseconds(20)) }
          share.send()
        }
      default: share.send()
      }
    }
  }

  /// Signals the review tools once the share card (or the screen after it) shows its state.
  struct ShareReview: ViewModifier {
    let model: GameModel
    let mode = ProcessInfo.processInfo.environment["SHARE_REVIEW"]
    private var ready: Bool {
      guard let mode else { return false }
      let phase = model.share?.state.phase
      switch mode {
      case "winner": return model.screen == .match && model.share != nil
      case "sharedwinner": return model.screen == .match && phase == .shared
      case "card", "cardlong": return model.screen == .share
      case "checking": return phase == .sending
      case "shared": return model.screen == .reel && model.reel?.phase == .making
      case "failed", "offline": return phase == .error
      case "notthistime": return phase == .failed
      case "sealed": return model.sealed?.phase == .shown && model.screen == .match
      case "sealedfailed": return model.sealed?.phase == .failed
      case "sealedold": return model.sealed?.phase == .old
      case "sealedloading": return model.screen == .sealed
      default: return phase == .refused
      }
    }
    func body(content: Content) -> some View {
      content.task {
        guard let mode else { return }
        while !ready || !ReviewOrientation.windowSettled {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        try? Data(("share-" + mode).utf8).write(
          to: URL.temporaryDirectory.appending(path: "review-ready"), options: .atomic)
      }
    }
  }
#endif
