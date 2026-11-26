import Foundation
import KubbEngine
import KubbPitch

/// The computer's turn against the computer, faster (engine 1.4.0, kubb-engine
/// docs/SESSION.md "The computer's turn, fast"; the web's speed button and skipCpu): watched
/// at 1x, 2x or 4x, its think, swing, throw and the kubbs it stands up, or skipped to the
/// person's next throw. The speed is the device's choice, kept across turns and matches
/// (`key`); a solo match only, never on a pitch, where every member watches the same pace.
public enum CpuSpeed {
  public static let key = "pitch.cpuSpeed"
  public static let choices = [1, 2, 4]
  public static func load(_ defaults: UserDefaults) -> Int {
    let v = defaults.integer(forKey: key)
    return choices.contains(v) ? v : 1
  }
  public static func keep(_ v: Int, in defaults: UserDefaults) {
    guard choices.contains(v) else { return }
    defaults.set(v, forKey: key)
  }
  /// The next speed a tap gives: 1x, 2x, 4x, then 1x again.
  public static func next(after v: Int) -> Int {
    let i = choices.firstIndex(of: v) ?? 0
    return choices[(i + 1) % choices.count]
  }
  /// "1X", "2X", "4X": the button's words (the web's).
  public static func label(_ v: Int) -> String { "\(v)X" }
  /// VoiceOver: "Computer's speed, 2 times".
  public static func spoken(_ v: Int) -> String { v == 1 ? "Normal" : "\(v) times" }
}

extension PitchSession {
  /// A solo match against the computer on an engine that plays its turn fast (1.4 on): no
  /// pitch, no practice, no watcher.
  var soloComputer: Bool {
    onlineAction == nil && !watching && need != nil && Engine.majorMinor(engine.engineVersion) != "1.0"
  }

  /// The factor the computer's turn runs at now (1 unless `soloComputer`).
  var fastFactor: Int { soloComputer ? max(1, min(4, cpuSpeed)) : 1 }

  /// The computer's turn is on the screen, so the speed button and the skip are shown:
  /// its aim, its throw playing, or its raises being watched.
  public var computerTurn: Bool {
    guard soloComputer, need?.kind != "over" else { return false }
    if playing { return playbackCpu }
    if stoodShow != nil { return stoodFast }
    return need?.kind == "throw" && need?.cpu == true
  }

  /// Several actions the engine made at once (`cpuPlay`), each kept with its own hash.
  func committedSteps(_ steps: [(action: JSONText, hash: String?)]) throws {
    guard !steps.isEmpty else { return }
    let snapshot = try engine.call("snapshot")
    for (i, st) in steps.enumerated() {
      trail.append(st.action, snapshot: i == steps.count - 1 ? snapshot : nil)
      if let save, trailKept {
        do {
          try save.appendTrail(st.action, hash: st.hash ?? engine.hash())
        } catch { trailKept = false }
      }
    }
    if let save {
      try save.write(snapshot)
      if trailKept, (try? JSONNode.parse(engine.call("need"))["kind"]?.string) == "over" { finishTrail() }
    }
  }
}
