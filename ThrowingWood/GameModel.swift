import Foundation
import KubbRenderer
import Observation

@MainActor @Observable final class GameModel {
  enum Screen {
    case home, options, practice, match, menu, sheet, onlineEntry, join, pitch, report, invalidLink

    var usesFeedback: Bool {
      switch self {
      case .options, .practice, .match, .pitch, .menu: true
      default: false
      }
    }
  }
  let feedback = GameFeedback()
  let offline: PitchSession?
  var pitch: PitchSession? { online?.board ?? offline }
  var online: OnlinePitch?
  var onlineRevision = 0
  var report: PitchReport?
  var joinInput = ""
  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

  var screen = Screen.home {
    didSet { feedback.onPitch = screen.usesFeedback }
  }
  var error: String?
  var surface = Surface.grass
  var result: ThrowResult?
  var playing = false
  var slow = false
  var sheetReturn = Screen.match
  var revision = 0
  var sheet: ScoreSheet?
  var selections = [String: String]()
  var name = "You"
  let save = MatchSave(file: URL.applicationSupportDirectory.appending(path: "solo-match.json"))

  init() {
    do {
      offline = try PitchSession(
        appVersion:
          Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    } catch {
      offline = nil
      self.error = String(describing: error)
      return
    }
    defer { feedback.onPitch = screen.usesFeedback }
    guard let pitch = offline else { return }
    feedback.attach(pitch)
    let defaults = UserDefaults.standard
    selections = pitch.options.defaults
    for row in pitch.options.rows {
      if let saved = defaults.string(forKey: "solo.option." + row.id),
        row.choices.contains(where: { $0.first == saved })
      {
        selections[row.id] = saved
      }
    }
    name = defaults.string(forKey: "solo.name") ?? "You"
    perform {
      #if targetEnvironment(simulator)
        if let mode = ProcessInfo.processInfo.environment["ONLINE_REVIEW"] {
          beginReview(mode)
          return
        }
        if let mode = ProcessInfo.processInfo.environment["MATCH_REVIEW"] {
          selections = pitch.options.defaults
          name = "You"
          if mode == "home" { return }
          if mode == "options" {
            screen = .options
            return
          }
          let snapshot = try String(
            contentsOf: URL.temporaryDirectory.appending(path: "review-solo.json"), encoding: .utf8)
          try pitch.restore(snapshot, save: nil)
          screen = .match
          if mode != "handoff" { pitch.dismissHandoff() }
          if mode == "menu" { screen = .menu }
          if mode == "sheet" { showSheet() }
          return
        }
        if ProcessInfo.processInfo.environment["PITCH_REVIEW"] != nil {
          screen = .practice
          return
        }
      #endif
      if let snapshot = try save.read() {
        try pitch.restore(snapshot, save: save)
        if let level = defaults.string(forKey: "solo.matchLevel") {
          try pitch.useLevel(level)
          selections["level"] = level
        }
        screen = .match
      }
    }
  }

  func perform(_ body: () throws -> Void) {
    do {
      try body()
      refresh()
    } catch { self.error = String(describing: error) }
  }
  func refresh() {
    guard let pitch else { return }
    if playing != pitch.playing { playing = pitch.playing }
    if result != pitch.result { result = pitch.result }
    if surface != pitch.scene.surface { surface = pitch.scene.surface }
    if slow != (pitch.playing && pitch.slow) { slow = pitch.playing && pitch.slow }
    if revision != pitch.revision { revision = pitch.revision }
  }
  func enter(_ link: PitchLink, create: Bool) {
    perform {
      let defaults = UserDefaults.standard
      let pitch = try OnlinePitch(
        url: RoomsConfiguration.url, link: link, create: create,
        name: defaults.string(forKey: "pitch.name") ?? "",
        level: defaults.string(forKey: "pitch.level") ?? "club", appVersion: Self.version)
      if online != nil { leaveOnline() }
      feedback.silence()
      feedback.attach(pitch.board)
      online = pitch
      screen = .pitch
      pitch.changed = { [weak self, weak pitch] in
        guard let self, let pitch, online === pitch else { return }
        if pitch.stage == .match {
          if screen == .pitch { screen = .match }
        } else {
          screen = .pitch
        }
        onlineRevision += 1
        refresh()
      }
      pitch.connect()
    }
  }
  func join(_ text: String) {
    guard let link = PitchLink(text) else {
      screen = .invalidLink
      return
    }
    if let online, online.link == link {
      switch online.stage {
      case .connecting, .reconnecting, .lobby, .match:
        screen = online.stage == .match ? .match : .pitch
        return
      default: break
      }
    }
    enter(link, create: false)
  }
  private func leaveOnline() {
    guard let online else { return }
    online.changed = nil
    online.board.onFeedback = nil
    online.board.cancelFeedback = nil
    self.online = nil
    report = nil
    Task { await online.leave() }
  }
  func home() {
    feedback.silence()
    if online != nil {
      leaveOnline()
      screen = .home
      refresh()
      return
    }
    perform {
      if pitch?.need?.kind == "over" { try save.clear() }
      try pitch?.practice()
      screen = .home
    }
  }
  func solo() {
    perform {
      if let text = try save.read() {
        try pitch?.restore(text, save: save)
        if let level = UserDefaults.standard.string(forKey: "solo.matchLevel") {
          try pitch?.useLevel(level)
        }
        screen = .match
      } else {
        screen = .options
      }
    }
  }
  func start() {
    perform {
      try pitch?.startSolo(name: name, selections: selections, save: save)
      for (key, value) in selections {
        UserDefaults.standard.set(value, forKey: "solo.option." + key)
      }
      UserDefaults.standard.removeObject(forKey: "solo.matchLevel")
      UserDefaults.standard.set(name, forKey: "solo.name")
      screen = .match
    }
  }
  var matchLevel: String {
    get { selections["level"] ?? "" }
    set {
      perform {
        try pitch?.useLevel(newValue)
        selections["level"] = newValue
        UserDefaults.standard.set(newValue, forKey: "solo.matchLevel")
      }
    }
  }
  func showSheet() {
    sheetReturn = screen
    perform {
      sheet = try pitch?.sheet()
      screen = .sheet
    }
  }
}
