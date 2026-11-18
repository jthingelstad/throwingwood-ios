#if targetEnvironment(simulator)
  import KubbRenderer
  import SwiftUI

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
      case "menu", "report": return p?.stage == .match
      default: return p.map { String(describing: $0.stage) == mode } == true
      }
    }
    func body(content: Content) -> some View {
      content.task {
        guard let mode else { return }
        // Observe the reached state even when join and its terminal answer both
        // arrive during the launch transaction, before SwiftUI's first update.
        while !ready {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        if mode == "menu" { model.screen = .menu }
        if mode == "report", let online = model.online {
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
