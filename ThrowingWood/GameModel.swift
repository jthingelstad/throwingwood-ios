import Foundation
import KubbRenderer
import Observation

@MainActor @Observable final class GameModel {
  enum Screen {
    case home, options, practice, match, menu, sheet, onlineEntry, join, pitch, report, invalidLink,
      reel, share, sealed, settings, howTo, practiceMenu

    var usesFeedback: Bool {
      switch self {
      case .options, .practice, .match, .pitch, .menu, .howTo, .practiceMenu: true
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
  /// The header's foot on an upright screen (window points; MatchScreen measures it, a
  /// larger text size grows it): the minimap hangs under its right end.
  var headerBottom: CGFloat?
  var joinInput = ""
  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

  var screen = Screen.home {
    didSet { feedback.onPitch = screen.usesFeedback }
  }
  var error: String?
  /// One sentence for the player, shown over the screen until closed: a kept match made
  /// on an engine this build no longer carries (VersionWords.oldMatch).
  var notice: String?
  var surface = Surface.grass
  var result: ThrowResult?
  var playing = false
  var slow = false
  var sheetReturn = Screen.match
  var revision = 0
  var sheet: ScoreSheet?
  var selections = [String: String]()
  /// The practice pitch's scene (its menu's Scene), kept on the device: one of the
  /// engine's catalogue (an id it does not list is Park).
  var practiceScene = SceneID.entry(UserDefaults.standard.string(forKey: "pitch.practiceScene")).id {
    didSet {
      guard practiceScene != oldValue else { return }
      UserDefaults.standard.set(practiceScene, forKey: "pitch.practiceScene")
      // the engine keeps a practice's scene from its start: a new practice in it, on the
      // same surface where the scene allows it, else the scene's own
      practiceSurface = SceneID.entry(practiceScene).resolve(practiceSurface)
      perform {
        try offline?.practice(scene: practiceScene, surface: practiceSurface)
      }
    }
  }
  /// The practice pitch's surface (its menu's Surface), kept on the device as the
  /// web keeps `practiceSurface`. Practice only: a match's surface is its own option.
  var practiceSurface =
    Surface(rawValue: UserDefaults.standard.string(forKey: "pitch.practiceSurface") ?? "") ?? .grass
  {
    didSet { UserDefaults.standard.set(practiceSurface.rawValue, forKey: "pitch.practiceSurface") }
  }
  /// The practice menu's Surface: the pitch changes under the practice, and is kept.
  func setPracticeSurface(_ s: Surface) {
    perform {
      try pitch?.surface(s)
      practiceSurface = s
    }
  }
  /// The practice behind the home card in the practice's scene and surface, then shown.
  func openPractice() {
    perform {
      practiceSurface = SceneID.entry(practiceScene).resolve(practiceSurface)
      if let offline,
        (offline.scene.look ?? "day") != practiceScene || offline.scene.surface != practiceSurface
      {
        try offline.practice(scene: practiceScene, surface: practiceSurface)
      }
      screen = .practice
    }
  }
  /// The scene the screen shows (the pitch's look and the controls' skin): a
  /// match's own (play, watching, a reopened or shared match, its replay), the
  /// solo options' pick over the pitch behind them, the lobby's choice on a
  /// pitch that takes one, the practice's; the day for the cards outside any
  /// pitch. An unknown id is the day (SceneID.shown).
  var shownScene: String {
    switch screen {
    case .home, .onlineEntry, .join, .invalidLink: return "day"
    case .settings: return settingsReturn == .settings ? "day" : scene(on: settingsReturn)
    default: return scene(on: screen)
    }
  }
  private func scene(on screen: Screen) -> String {
    switch screen {
    case .home, .onlineEntry, .join, .invalidLink, .settings: return "day"
    case .options:
      return pitch?.options.takesScene == true ? SceneID.shown(selections["scene"]) : "day"
    case .pitch:
      if let online, online.stage != .match { return online.lobbyScene }
      return SceneID.shown(pitch?.scene.look)
    default: return SceneID.shown(pitch?.scene.look)
    }
  }
  /// How to throw, from a menu's grid; DONE goes back to the menu it came from.
  func openHowTo() {
    howToReturn = screen == .practiceMenu ? .practiceMenu : .menu
    screen = .howTo
  }
  var howToReturn = Screen.menu
  /// Where Settings goes back to.
  var settingsReturn = Screen.home
  func openSettings() {
    settingsReturn = screen
    screen = .settings
  }
  /// The player's name, the device's one value (PlayerName): a generated name, picked
  /// in the name row (Settings, the solo card, the lobby). A change is kept and, on a
  /// pitch, told to the room. Never typed.
  var name = "" {
    didSet {
      guard name != oldValue, let names = offline?.names else { return }
      name = PlayerName.store(name, in: .standard, names: names)
      nameRow?.set(name)
      if let online { perform { try online.profile(name: name) } }
    }
  }
  /// The device's name row (NameRowModel), one for every screen that picks the name.
  private(set) var nameRow: NameRowModel?
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
    selections = pitch.options.load(defaults)
    name = PlayerName.load(defaults, names: pitch.names)
    let row = NameRowModel(names: pitch.names, kind: .player, text: name, label: "Your name")
    row.onChange = { [weak self] in self?.name = $0 }
    nameRow = row
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
          // the solo options' Scene row picked (the review tools' --scene)
          if let look = ProcessInfo.processInfo.environment["REVIEW_SCENE"] { selections["scene"] = look }
          name = "Brave Birch"  // a generated name for the pictures (the fixtures' own say "You")
          if mode == "home" { return }
          if mode == "options" {
            screen = .options
            return
          }
          if mode == "settings" {
            screen = .settings
            return
          }
          if mode == "practicemenu" {
            // the practice pitch's menu card (stage 3: its rows segmented bars), in the
            // review's scene
            practiceScene = ProcessInfo.processInfo.environment["REVIEW_SCENE"] ?? "day"
            openPractice()
            screen = .practiceMenu
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
          if mode == "matchsettings" {
            // Settings from the match's menu, in the match's scene
            screen = .menu
            openSettings()
          }
          if mode == "sheet" { showSheet() }
          return
        }
        if ProcessInfo.processInfo.environment["PITCH_REVIEW"] != nil {
          openPractice()
          return
        }
      #endif
      if let snapshot = try save.read(), try resumeKept(snapshot, on: pitch) {
        screen = .match
      }
    }
  }

  /// The kept solo match back on the pitch. One made on an engine this build no longer
  /// carries cannot be played on (docs/ENGINES.md): it is dropped, with its trail, and
  /// the player told in one sentence; the caller starts afresh. True when restored.
  private func resumeKept(_ snapshot: String, on pitch: PitchSession) throws -> Bool {
    do {
      // the device's own match: the plain restore (typed names from before generated
      // names stay, seen only by this device's player; a share checks the whole match)
      try pitch.restore(snapshot, save: save)
      return true
    } catch let old as OldMatch {
      save.dropOld(engine: old.engine)
      notice = VersionWords.oldMatch
      return false
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
      let pitch = try OnlinePitch(
        url: PitchConfiguration.server, link: link, create: create,
        name: name, appVersion: Self.version, api: PitchConfiguration.client)
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
          // Settings opened from the lobby stays open when another player starts
          // the match; its BACK then goes to the match, not to a lobby that is gone
          if screen == .settings, settingsReturn == .pitch { settingsReturn = .match }
        } else if screen == .settings {
          // and back to the lobby when the match it would return to is over
          if settingsReturn == .match { settingsReturn = .pitch }
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
    join(link)
  }
  /// A pitch by its link: the one open already if it is the same (watching or
  /// playing alike), else a new join. `link.observe` joins as an observer.
  func join(_ link: PitchLink) {
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
      try pitch?.practice(scene: practiceScene, surface: practiceSurface)
      screen = .home
    }
  }
  func solo() {
    perform {
      if let pitch, let text = try save.read(), try resumeKept(text, on: pitch) {
        screen = .match
      } else {
        screen = .options
      }
    }
  }
  func start() {
    share = nil
    perform {
      // the match plays the scene's set (startSolo), and that is what is kept
      guard let pitch else { return }
      try pitch.startSolo(name: name, selections: selections, save: save)
      pitch.options.keep(selections, in: .standard)
      selections = pitch.options.starting(selections)
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
