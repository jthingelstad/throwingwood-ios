import AVFoundation
import KubbRenderer
import KubbPitch
import Network
import SwiftUI

/// Whether the device has a network path: a reel asked for offline sends nothing and
/// says so. Watched from launch, so the first press already knows.
@MainActor final class NetworkPath {
  static let shared = NetworkPath()
  static let online = Notification.Name("ThrowingWood.networkOnline")
  private(set) var reachable = true
  private let monitor = NWPathMonitor()
  private init() {
    monitor.pathUpdateHandler = { path in
      let ok = path.status == .satisfied
      Task { @MainActor in
        let was = NetworkPath.shared.reachable
        NetworkPath.shared.reachable = ok
        // back online: a pitch waiting out its reconnect backoff tries at once
        if ok && !was { NotificationCenter.default.post(name: NetworkPath.online, object: nil) }
      }
    }
    monitor.start(queue: DispatchQueue(label: "network-path"))
  }
}

extension GameModel {
  /// MAKE A HIGHLIGHT REEL: the reel card for a pitch code and, when known, the
  /// finished match it is for (its number and hash), which the room's kept replay must
  /// be. A match against the computer, once shared, opens it with the code alone. The
  /// same code and match keep their reel, so the card shows how it stands.
  /// `linked`: a match just shared, whose card says "The link:" before its address.
  func openReel(code: String, match: ReelMatch? = nil, linked: Bool = false) {
    makeReel(code: code, match: match, linked: linked)
    reelReturn = screen
    screen = .reel
  }

  /// The reel for a code and match, made once and kept while it is the same.
  func makeReel(code: String, match: ReelMatch? = nil, linked: Bool = false) {
    guard reel?.code != code || reel?.match != match else { return }
    reel?.hide()
    reel = HighlightReel(
      code: code, site: PitchConfiguration.site,
      cache: URL.cachesDirectory.appending(path: "reels"), hooks: reelHooksFor(code),
      match: match, linked: linked)
  }

  /// BACK: to where the card was opened, or, on a pitch that has moved since (a
  /// rematch's lobby, a reconnect), to the pitch's own screen as it is now.
  func closeReel() {
    reel?.hide()
    if let online {
      screen = online.stage == .match ? .match : .pitch
    } else {
      screen = reelReturn
    }
  }

  static func reelHooks(_ code: String) -> HighlightReel.Hooks {
    HighlightReel.Hooks(
      ask: { v in
        try await PitchConfiguration.client.reel(pitch: code, v: v)
      },
      kept: {
        try await PitchConfiguration.client.replay(pitch: code)
      },
      fetch: { from, to in
        let (file, response) = try await URLSession.shared.download(from: from)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          try? FileManager.default.removeItem(at: file)
          throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: file, to: to)
      },
      reachable: { NetworkPath.shared.reachable })
  }

  /// The online winner card's reel: a finished pitch whose match carries its replay.
  var onlineReelCode: String? {
    guard let online, online.controller.finishedWithReplay else { return nil }
    return online.link.code
  }
}

/// The highlight reel card (the web's docs/REEL.md "What a player sees"): MAKING YOUR
/// REEL with a slow bar while the server renders, then the video playing, muted and
/// looping, tall in a tall window and wide in a wide one, with SHARE (the tall file
/// itself, to the share sheet) and COPY LINK.
struct ReelCard: View {
  let model: GameModel
  let reel: HighlightReel
  @Environment(\.screenGeometry) private var screen
  @Environment(\.scenePhase) private var phase
  @State private var copied = false

  private var wide: Bool { screen.size.width > screen.size.height }
  private var format: HighlightReel.Format { wide ? .wide : .tall }
  private var ipad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(ReelWords.title).cardTitle()
      switch reel.phase {
      case .idle, .checking, .asking, .making: making
      case .fetching:
        Text(ReelWords.fetching)
        ProgressView().frame(maxWidth: .infinity)
      case .ready:
        if let file = reel.file(format) {
          video(file)
        } else {
          ProgressView().frame(maxWidth: .infinity)
        }
      case .problem(let p):
        let words = ReelWords.problem(p)
        Text(words.text).fixedSize(horizontal: false, vertical: true)
        if words.retry {
          Button(ReelWords.tryAgain) { reel.tryAgain() }.buttonStyle(WoodButton(accent: true))
        }
      }
      // a match just shared: "The link: https://throwingwood.com/p/<code>" (the web's)
      Text(reel.linked ? "\(ShareWords.link) \(reel.link.absoluteString)" : reel.link.absoluteString)
        .font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
      if copied { Text(ReelWords.copied).font(bodyFont(14, relativeTo: .footnote)) }
      HStack {
        if reel.phase == .ready, let tall = reel.file(.tall) {
          ShareLink(item: tall) { Label(ReelWords.share, systemImage: "square.and.arrow.up") }
            .buttonStyle(WoodButton(accent: true))
            .accessibilityHint("Shares the tall video file")
        }
        Button(ReelWords.copyLink) {
          UIPasteboard.general.string = reel.link.absoluteString
          copied = true
        }.buttonStyle(WoodButton())
        Spacer(minLength: 0)
        Button(ReelWords.back) { model.closeReel() }.buttonStyle(WoodButton())
      }
    }
    .cardScreen(width: cardWidth)
    .sensoryFeedback(.success, trigger: reel.phase == .ready) { _, ready in
      ready && model.feedback.haptics
    }
    .onAppear {
      reel.want(format)
      if phase == .active { reel.show() }
    }
    .onDisappear { reel.hide() }
    .onChange(of: format) { _, f in reel.want(f) }
    #if targetEnvironment(simulator)
      .modifier(ReelReview(reel: reel, format: format))
    #endif
  }

  /// The web's widths, centred: the tall panel 520 and the sheet 640 on an iPad; a
  /// phone's card as the online cards, 400, and on its side as wide as the video.
  private var cardWidth: CGFloat {
    if ipad { return wide ? 640 : 520 }
    return wide ? max(400, videoSize.width + 32) : 400
  }

  /// The video's box: as large as the window leaves room for beside the card's words
  /// and buttons, in the reel's own shape (9:16 tall, 16:9 wide). The room left is the
  /// 1.0 card's: its top edge (64 upright, 10 on its side), padding, title, link and the
  /// button row with its shadow (the 2026-11-22 review pictures: at 250 and 190 the
  /// buttons fell under the card's foot and scrolled).
  private var videoSize: CGSize {
    let safe = screen.safe
    let height = screen.size.height - safe.top - safe.bottom
    let room = max(120, height - (wide ? 240 : 310))
    if wide {
      let w = min(room * 16 / 9, (ipad ? 640 : screen.size.width - safe.left - safe.right - 64) - 32)
      return CGSize(width: w, height: w * 9 / 16)
    }
    let w = min(room * 9 / 16, (ipad ? 520 : 400) - 32)
    return CGSize(width: w, height: w * 16 / 9)
  }

  private func video(_ file: URL) -> some View {
    LoopingVideo(url: file, still: reviewStill)
      .frame(width: videoSize.width, height: videoSize.height)
      .background(Color.woodInk)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .frame(maxWidth: .infinity)
      .accessibilityLabel("The highlight reel, playing without sound")
  }

  private var making: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(ReelWords.making).font(displayFont(24))
      SlowBar(since: reel.since ?? .now)
      Text(ReelWords.wait)
      // a lost poll: said, and the next one tried (the render goes on without us)
      if reel.offline { Text(ReelWords.problem(.offline).text) }
    }
  }

  private var reviewStill: Double? {
    #if targetEnvironment(simulator)
      ProcessInfo.processInfo.environment["REEL_REVIEW"] == nil
        && ProcessInfo.processInfo.environment["SHARE_REVIEW"] == nil ? nil : 24
    #else
      nil
    #endif
  }
}

/// A bar that fills slowly toward the end of the minute a reel takes and never claims
/// to be done: it is not the server's progress, which the server does not report.
struct SlowBar: View {
  let since: Date
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { context in
      let t = max(0, context.date.timeIntervalSince(since))
      let f = reviewing ? 0.42 : min(0.94, 1 - exp(-t / 45))
      GeometryReader { box in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3).fill(Color.woodInk.opacity(0.12))
          RoundedRectangle(cornerRadius: 3).fill(Color.woodGold)
            .frame(width: max(8, box.size.width * f))
            .animation(.linear(duration: 0.5), value: f)
        }
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.woodInk, lineWidth: 2))
      }.frame(height: 16)
    }
    .accessibilityElement().accessibilityLabel("Making the reel")
  }
  private var reviewing: Bool {
    #if targetEnvironment(simulator)
      ProcessInfo.processInfo.environment["REEL_REVIEW"] != nil
        || ProcessInfo.processInfo.environment["SHARE_REVIEW"] != nil
    #else
      false
    #endif
  }
}

/// The reel, muted and looping, with no controls (a picture, not a player).
/// `still`: a review picture's fixed frame, in seconds, paused.
struct LoopingVideo: UIViewRepresentable {
  let url: URL
  var still: Double?
  final class PlayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var looper: AVPlayerLooper?
    var url: URL?
  }
  func makeUIView(context: Context) -> PlayerView {
    let view = PlayerView()
    view.playerLayer.videoGravity = .resizeAspect
    view.backgroundColor = .clear
    return view
  }
  func updateUIView(_ view: PlayerView, context: Context) {
    guard view.url != url else { return }
    view.url = url
    let item = AVPlayerItem(url: url)
    let player = AVQueuePlayer()
    player.isMuted = true
    player.preventsDisplaySleepDuringVideoPlayback = false
    if let still {
      player.insert(item, after: nil)
      player.seek(to: CMTime(seconds: still, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
      view.looper = nil
    } else {
      view.looper = AVPlayerLooper(player: player, templateItem: item)
      player.play()
    }
    view.playerLayer.player = player
  }
  static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
    view.playerLayer.player?.pause()
    view.looper?.disableLooping()
    view.playerLayer.player = nil
  }
}

#if targetEnvironment(simulator)
  extension GameModel {
    /// The review tools' reel card, with no network: REEL_REVIEW names the state and
    /// the videos are the review's own files in tmp (tools/reel-snapshots.py).
    func beginReelReview(_ mode: String) {
      let code = "mapkubb2"
      let files = ReelFiles(
        tall: "/reels/\(code)/1-r1-0.7/tall.mp4", wide: "/reels/\(code)/1-r1-0.7/wide.mp4", pitch: code)!
      let answer: ReelAnswer =
        switch mode {
        case "done": .done(v: 1, tag: "r1-0.7", files: files)
        case "making", "makingoffline": .rendering(v: 1, tag: "r1-0.7")
        case "failed": .notStarted
        case "notthistime": .failed(v: 1, tag: "r1-0.7", why: .render)
        case "empty": .failed(v: 1, tag: "r1-0.7", why: .empty)
        case "engine": .none(v: 1, why: .engine)
        case "busy": .none(v: 1, why: .busy)
        case "unavailable": .none(v: 0, why: .unavailable)
        case "toomany": .tooMany
        default: .none(v: 0, why: .replay)
        }
      var asks = 0
      reel = HighlightReel(
        code: code, site: URL(string: "https://throwingwood.com")!,
        cache: URL.temporaryDirectory.appending(path: "review-reels"),
        hooks: HighlightReel.Hooks(
          ask: { _ in
            asks += 1
            // the second poll is lost: No connection under the wait
            if mode == "makingoffline", asks > 1 { throw PitchError("closed") }
            return answer
          },
          // the room keeps the match the card is for (match 2), or a rematch (3)
          kept: { KeptReplay(v: 1, n: mode == "moved" ? 3 : 2, hash: nil) },
          fetch: { from, to in
            let name = from.lastPathComponent  // tall.mp4 or wide.mp4
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(
              at: URL.temporaryDirectory.appending(path: "review-reel-" + name), to: to)
          },
          reachable: { mode != "offline" }),
        match: ReelMatch(n: 2, hash: nil), every: .milliseconds(mode == "makingoffline" ? 200 : 5000))
      try? FileManager.default.removeItem(at: URL.temporaryDirectory.appending(path: "review-reels"))
      reelReturn = .match
      screen = .reel
    }
  }

  /// Signals the review tools once the card shows its state (and, done, its frame).
  struct ReelReview: ViewModifier {
    let reel: HighlightReel
    let format: HighlightReel.Format
    let mode = ProcessInfo.processInfo.environment["REEL_REVIEW"]
    func body(content: Content) -> some View {
      content.task {
        guard let mode else { return }
        while true {
          let ready: Bool =
            switch mode {
            case "making": reel.phase == .making && !reel.offline
            case "makingoffline": reel.phase == .making && reel.offline
            case "done": reel.phase == .ready && reel.file(format) != nil
            case "offline": reel.phase == .problem(.offline)
            case "failed": reel.phase == .problem(.failed)
            case "notthistime": reel.phase == .problem(.notThisTime)
            default: if case .problem = reel.phase { true } else { false }
            }
          if ready, ReviewOrientation.windowSettled { break }
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        // the video's still frame is decoded and drawn
        if mode == "done" { try? await Task.sleep(for: .milliseconds(1500)) }
        try? Data(("reel-" + mode).utf8).write(
          to: URL.temporaryDirectory.appending(path: "review-ready"), options: .atomic)
      }
    }
  }
#endif
