import Foundation
import KubbRenderer
import Observation

@MainActor @Observable final class GameModel {
  enum Screen {
    case home, options, practice, match, menu, sheet, onlineEntry, join, pitch, report, invalidLink,
      reel, share, sealed, settings

    var usesFeedback: Bool {
      switch self {
      case .options, .practice, .match, .pitch, .menu: true
      default: false
      }
    }
  }
  let feedback = GameFeedback()
  let meter = MeterChoice()
  let offline: PitchSession?
  var pitch: PitchSession? { online?.board ?? sealed?.board ?? offline }
  var online: OnlinePitch?
  var onlineRevision = 0
  var report: PitchReport?
  var reportReturn = Screen.match
  /// The highlight reel of the pitch on the winner card (ReelCard.swift), kept while
  /// the card is closed so its button shows how the reel stands.
  var reel: HighlightReel?
  var reelReturn = Screen.match
  /// The finished match against the computer on the winner card, and its share card
  /// (ShareCard.swift), while it is the match on the screen.
  var share: SoloShare?
  var shareReturn = Screen.match
  /// A shared match opened by its code (a sealed pitch, ShareCard.swift): shown from its
  /// kept replay on a session of its own, never joined.
  var sealed: SealedPitch?
  /// Review pictures stand in for the reel's server (simulator only).
  @ObservationIgnored var reelHooksOverride: ((String) -> HighlightReel.Hooks)?
  /// The plan's two columns on the screen (window points; PlanControls reports them):
  /// the coach line keeps out of any level with it. Drawing only, not observed.
  @ObservationIgnored var planFrames: [Int: CGRect] = [:]
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
  /// The player's own throw level, the device's one value (ThrowLevel). The solo
  /// set-up's `selections["level"]` is the computer's.
  var throwLevel = ThrowLevel.fallback {
    didSet {
      guard throwLevel != oldValue else { return }
      ThrowLevel.store(throwLevel, in: .standard)
      perform {
        try offline?.useLevel(throwLevel)
        if let online { try online.profile(name: online.name, level: throwLevel) }
      }
    }
  }
  /// Where Settings goes back to.
  var settingsReturn = Screen.home
  func openSettings() {
    settingsReturn = screen
    screen = .settings
  }
  var name = "You"
  /// The menu's Raising (Jamie, 2026-11-19): every kubb of this device's raised by the
  /// engine's choice for the rest of this match (AutoRaise). Not kept on the device.
  var raiseAutomatically: Bool {
    get { pitch?.raiseAutomatically ?? false }
    set {
      pitch?.raiseAutomatically = newValue
      refresh()
    }
  }
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
    _ = NetworkPath.shared  // a reel asked for offline knows at once
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
    throwLevel = ThrowLevel.load(
      defaults,
      choices: pitch.options.rows.first { $0.id == "level" }?.choices.map { $0[0] } ?? [],
      soloInProgress: (try? save.read()) != nil)
    try? pitch.useLevel(throwLevel)  // practice throws at it from the start
    perform {
      #if targetEnvironment(simulator)
        if let mode = ProcessInfo.processInfo.environment["ONLINE_REVIEW"] {
          beginReview(mode)
          return
        }
        if let mode = ProcessInfo.processInfo.environment["REEL_REVIEW"] {
          // a finished match behind the card, as on the winner card
          let snapshot = try String(
            contentsOf: URL.temporaryDirectory.appending(path: "review-solo.json"), encoding: .utf8)
          try pitch.restore(snapshot, save: nil)
          pitch.dismissHandoff()
          beginReelReview(mode)
          return
        }
        if let mode = ProcessInfo.processInfo.environment["SHARE_REVIEW"] {
          // a finished match against the computer behind the card, as on the winner card
          let snapshot = try String(
            contentsOf: URL.temporaryDirectory.appending(path: "review-solo.json"), encoding: .utf8)
          try pitch.restore(snapshot, save: nil)
          pitch.dismissHandoff()
          beginShareReview(mode)
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
          if mode == "settings" {
            screen = .settings
            return
          }
          let snapshot = try String(
            contentsOf: URL.temporaryDirectory.appending(path: "review-solo.json"), encoding: .utf8)
          try pitch.restore(snapshot, save: nil)
          screen = .match
          if mode != "handoff" { pitch.dismissHandoff() }
          raiseAutomatically = mode == "raiseauto"
          if mode == "raiserest" { pitch.raiseRest() }
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
        try pitch.useLevel(throwLevel)
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
        level: throwLevel, appVersion: Self.version)
      if online != nil { leaveOnline() }
      sealed = nil
      feedback.silence()
      feedback.attach(pitch.board)
      online = pitch
      screen = .pitch
      pitch.changed = { [weak self, weak pitch] in
        guard let self, let pitch, online === pitch else { return }
        if pitch.stage == .sealed {
          openSealed(pitch.link)  // a shared match: watched from its replay
          return
        }
        if screen == .reel, let reel {
          // the card stays through a reconnect (the foreground's among them) and a
          // rematch's lobby; a match starting, or the pitch gone, closes it
          if !reel.staysOpen(on: pitch.stage, finished: pitch.controller.finishedReplay) {
            reel.hide()
            screen = pitch.stage == .match ? .match : .pitch
          }
        } else if pitch.stage == .match {
          if screen == .pitch { screen = .match }
        } else if screen == .settings {
          if pitch.stage == .match { settingsReturn = .match }
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
  func leaveOnline() {
    guard let online else { return }
    online.changed = nil
    online.board.onFeedback = nil
    online.board.cancelFeedback = nil
    self.online = nil
    report = nil
    reel?.hide()
    reel = nil
    Task { await online.leave() }
  }
  func home() {
    feedback.silence()
    if sealed != nil {
      // the solo match behind it, if any, stays as it was
      sealed = nil
      reel?.hide()
      screen = .home
      refresh()
      return
    }
    if online != nil {
      leaveOnline()
      screen = .home
      refresh()
      return
    }
    perform {
      if pitch?.need?.kind == "over" { try save.clear() }
      try pitch?.practice()
      try pitch?.useLevel(throwLevel)
      screen = .home
    }
  }
  func solo() {
    perform {
      if let text = try save.read() {
        try pitch?.restore(text, save: save)
        try pitch?.useLevel(throwLevel)
        screen = .match
      } else {
        screen = .options
      }
    }
  }
  func start() {
    share = nil
    perform {
      try pitch?.startSolo(name: name, level: throwLevel, selections: selections, save: save)
      for (key, value) in selections {
        UserDefaults.standard.set(value, forKey: "solo.option." + key)
      }
      UserDefaults.standard.set(name, forKey: "solo.name")
      screen = .match
    }
  }
  /// BY HAND on the raise panel: back to choosing the ends.
  func raiseByHand() {
    pitch?.raiseByHand()
    refresh()
  }
  func showSheet() {
    sheetReturn = screen
    perform {
      sheet = try pitch?.sheet()
      screen = .sheet
    }
  }
}
