import Foundation
import KubbRenderer
import Observation

@MainActor @Observable final class GameModel {
  enum Screen { case home, options, practice, match, menu, sheet }
  let pitch: PitchSession?
  var screen = Screen.home
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
      pitch = try PitchSession(
        appVersion:
          Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    } catch {
      pitch = nil
      self.error = String(describing: error)
      return
    }
    guard let pitch else { return }
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
  func home() {
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
