#if targetEnvironment(simulator)
  import KubbRenderer
  import SwiftUI

  /// The review tools' landscape pictures: REVIEW_ORIENTATION "left" or "right"
  /// turns the interface that way (the simulator itself stays upright), and every
  /// review waits for it before it prepares or signals a picture.
  enum ReviewOrientation {
    static let wanted = ProcessInfo.processInfo.environment["REVIEW_ORIENTATION"]
    @MainActor static func apply() {
      guard let wanted,
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
      else { return }
      let mask: UIInterfaceOrientationMask = wanted == "left" ? .landscapeLeft : .landscapeRight
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
    /// Is a screen of `size` the way the review asked for?
    static func settled(_ size: CGSize) -> Bool {
      wanted == nil || size.width > size.height
    }
    @MainActor static var windowSettled: Bool {
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      return settled(scene?.windows.first?.bounds.size ?? .zero)
    }
  }

  /// Simulator checkpoint for the local review harness. Every room event arrives over loopback.
  struct OnlineReview: ViewModifier {
    let model: GameModel
    let mode = ProcessInfo.processInfo.environment["ONLINE_REVIEW"]
    private var ready: Bool {
      guard let mode else { return false }
      let p = model.online
      switch mode {
      case "entry": return model.screen == .onlineEntry
      case "join": return model.screen == .join
      case "share": return p?.stage == .lobby && p?.isHost == true
      case "host", "guest":
        return p?.members.filter { $0.side != nil }.count == 2 && p?.stage == .lobby
      case "newer", "older": return p?.versionCard?.rawValue == mode
      case "handoff": return p?.stage == .match && p?.board.handoff != nil
      case "flight": return model.playing
      case "shout": return p?.shouts.isEmpty == false && p?.board.handoff == nil
      case "winner": return p?.board.need?.kind == "over"
      case "menu", "report", "feedback": return p?.stage == .match
      default: return p.map { String(describing: $0.stage) == mode } == true
      }
    }
    func body(content: Content) -> some View {
      content.task {
        ReviewOrientation.apply()
        guard let mode else { return }
        // Observe the reached state even when join and its terminal answer both
        // arrive during the launch transaction, before SwiftUI's first update.
        while !ready || !ReviewOrientation.windowSettled {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        // the host's Scene picked in the lobby (the review tools' --scene)
        if mode == "host", let look = ProcessInfo.processInfo.environment["REVIEW_SCENE"],
          let online = model.online
        {
          try? await online.option("scene", look)
          while online.lobbyScene != look {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
          }
          try? await Task.sleep(for: .milliseconds(300))
        }
        if mode == "menu" { model.screen = .menu }
        if mode == "report" || mode == "feedback", let online = model.online {
          model.perform {
            model.report = try online.captureReport(size: .zero, scale: 3)
            model.screen = .report
          }
        }
        try? Data(mode.utf8).write(
          to: URL.temporaryDirectory.appending(path: "online-ready"), options: .atomic)
      }
    }
  }
#endif
