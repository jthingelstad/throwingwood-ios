import Foundation
import simd

struct WorldPoint: Decodable {
  let x, y, z: Double
  var vector: V3 { V3(x, y, z) }
}

public struct ThrowResult: Decodable, Equatable, Sendable {
  public let flag, restText: String?
  struct Words: Decodable, Equatable {
    let power, release, steady, side: String?
  }
  let verdicts: Words?
  /// The match's ruling on the throw (the session's `ruling`, on a match's recording): its
  /// short words and codes.
  struct Ruling: Decodable, Equatable, Sendable {
    struct Part: Decodable, Equatable, Sendable { let code: String? }
    let short, code: String?
    let parts: [Part]?
    var codes: [String] { (parts?.compactMap(\.code)).flatMap { $0.isEmpty ? nil : $0 } ?? (code.map { [$0] } ?? []) }
  }
  let ruling: Ruling?
  /// The throw to go's verdict (engine 1.4.0, `recording.result` of kind "togo"): each
  /// side's baton (`gap` in m to the king's side, 0 touching; `toppled` the king), the
  /// side that throws first, how ("closer", "king", "again") and why again ("tie", "both
  /// king").
  public struct TogoBaton: Decodable, Equatable, Sendable {
    public let gap: Double?, mm: Int?, toppled: Bool?, cpu: Bool?
    let verdicts: Words?
  }
  public internal(set) var togo: Bool? = nil
  public internal(set) var first: String? = nil, how: String? = nil, why: String? = nil
  public internal(set) var round: Int? = nil
  public internal(set) var A: TogoBaton? = nil, B: TogoBaton? = nil
  /// The teams' names and the viewer's side, set by the session for the words (never the
  /// engine's).
  public internal(set) var togoTeams: [String: String]? = nil
  public internal(set) var togoViewer: String? = nil
  /// The flag over the pitch: a throw to go's verdict (TogoWords), else `shownFlag`.
  public var headline: String? {
    togo == true ? TogoWords.flag(self) : shownFlag
  }
  /// The line under the flag: a throw to go's distances, else the engine's `restText`.
  public var shownRest: String? {
    togo == true ? TogoWords.rest(self) : restText
  }
  /// The flag over the pitch after the throw (the web's rulings.js flagFor): the
  /// recording's `flag`, except where a Kid match's ruling says what happened better. A
  /// Kid match has no punishments and no losing throws, so the flag never says one: a king
  /// knocked down early is stood back up ("KING BACK UP", `kingUp`), a kubb out twice is
  /// placed by the engine ("OUT TWICE: PLACED", `placed`), and a helicopter counts
  /// (`helicopterCounts`): its flag is what it knocked down ("1 DOWN", "MISS"), never
  /// "HELICOPTER", which in the standard game means a throw that does not count.
  public var shownFlag: String? {
    let codes = ruling?.codes ?? []
    let short = ruling?.short.flatMap { $0.isEmpty ? nil : $0 }
    if codes.contains("kingUp") || codes.contains("placed"), let short { return short }
    if codes.contains("helicopterCounts") { return flag == "HELICOPTER" ? short : flag }
    return flag
  }
  public struct Verdict: Equatable {
    public let text: String, offTarget: Bool
  }
  public var words: [Verdict] {
    // a throw to go's: the viewer's own baton's
    let own = togo == true ? (togoViewer == "A" ? A : togoViewer == "B" ? B : nil)?.verdicts : nil
    guard let v = togo == true ? own : verdicts else { return [] }
    var off = [Verdict]()
    var on = [Verdict]()
    for (word, good, label) in [
      (v.power, "ON", "POWER ON"), (v.release, "ON", "ARC ON"),
      (v.steady, "STEADY", "STEADY"), (v.side, "STRAIGHT", "STRAIGHT"),
    ] {
      guard let word else { continue }
      if word == good {
        on.append(Verdict(text: label, offTarget: false))
      } else {
        off.append(Verdict(text: word, offTarget: true))
      }
    }
    return off + on
  }
}

struct Recording: Decodable {
  struct Body: Decodable {
    let id: String, start, frames: Int, poses: [Int]
  }
  struct Burst: Decodable {
    let start: Double, kind: String, anchor: WorldPoint, takenBack: Bool?
  }
  struct Projectile: Decodable { let id: String }
  struct Touch: Decodable { let t: Double, id, kind: String }
  struct Contact: Decodable { let t, strength: Double, a, b, idA, idB: String }
  struct Landing: Decodable { let t, strength: Double, surface: Surface }
  /// A piece meeting the ground hard enough to matter (engine 0.14's `timeline.impacts`,
  /// while `setImpacts` is on): when (the throw's clock), where (the recording's frame),
  /// which piece and its kind, whether it is the thrown one, how fast it came down (m/s)
  /// and its push on the ground (0 to 1). A scene that rings draws one there.
  struct Impact: Decodable, Equatable {
    let t, x, y: Double
    let id: String
    let with: String
    let thrown: Bool?
    let speed, strength: Double?
  }
  struct Timeline: Decodable {
    let bursts: [Burst], touches: [Touch]?, contacts: [Contact]?, batonLanding: Landing?
    let impacts: [Impact]?
  }
  let projectile: Projectile
  let frameDt, duration, poseScale: Double
  let items: [Piece], bodies: [Body], timeline: Timeline, result: ThrowResult
}

/// Pre-index moving tracks once. The other pieces keep their release pose.
struct Playback {
  let recording: Recording
  private let tracks: [(index: Int, body: Recording.Body)]
  var nextTime = 0.0, rest = 0.0, realTime = 0.0
  let feedback: [TimedFeedback]
  var nextCue = 0
  var finished = false
  var starts: [Double?]
  /// The pieces as the frame before showed them (Spin.swift).
  var lastShown: [String: Piece] = [:]
  /// `rings`: the scene rings at each ground impact, and taps with it (PitchFeedback).
  init(_ r: Recording, rings: Bool = false) {
    recording = r
    feedback = r.timeline.feedback(projectileID: r.projectile.id, rings: rings)
    let indices = Dictionary(uniqueKeysWithValues: r.items.enumerated().map { ($1.id, $0) })
    tracks = r.bodies.compactMap { b in indices[b.id].map { ($0, b) } }
    starts = Array(repeating: nil, count: r.timeline.bursts.count)
  }

  func pieces(at t: Double) -> [Piece] {
    var items = recording.items
    let u = t / recording.frameDt
    let frame = Int(floor(u))
    for (index, b) in tracks where frame + 1 >= b.start && b.frames > 0 {
      var p = items[index]
      func pose(_ f: Int) -> (V3, SIMD4<Double>) {
        if f < b.start { return (p.center, p.rotation.vector) }
        let i = min(f - b.start, b.frames - 1) * 7
        let d = b.poses
        let scale = recording.poseScale
        return (
          V3(Double(d[i]), Double(d[i + 1]), Double(d[i + 2])) / scale,
          SIMD4(Double(d[i + 4]), Double(d[i + 5]), Double(d[i + 6]), Double(d[i + 3])) / scale
        )
      }
      let a = pose(frame)
      let next = pose(frame + 1)
      let fraction = u - Double(frame)
      let center = a.0 + (next.0 - a.0) * fraction
      let end = dot(a.1, next.1) < 0 ? -next.1 : next.1
      let q = simd_normalize(a.1 + (end - a.1) * fraction)
      (p.x, p.y, p.z) = (center.x, center.y, center.z)
      (p.qx, p.qy, p.qz, p.qw) = (q.x, q.y, q.z, q.w)
      items[index] = p
    }
    return items
  }
}
