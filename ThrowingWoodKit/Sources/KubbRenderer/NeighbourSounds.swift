import Foundation
import simd

// The Tournament's other pitches heard, quiet and far (the owner, 2026-11-22: "We should
// hear the sounds from the other pitches."). The web's src/game/neighbour-sound.js, its
// numbers and its rule. The cues come from what engine 0.16.0 puts in each neighbour
// recording (kubb-engine docs/SESSION.md "Neighbours"): `hits`, the first contact on each
// body struck with its strength, and `landing`, the thrown piece's first touch of the
// ground. Each body knocks once, at its first hit: a kubb that toppled as loud as its hit
// was hard (0.35 + 0.65 x strength of the full knock), the king 1.5 times that, a kubb
// struck and left standing (or a stake) a quieter, slightly higher tap at 0.45 of a
// topple's; the landing is a softer, lower thud at `landing.t`. Nothing is read from the
// poses. Played with the game's own knock takes, lower (farther); sound only, never a
// haptic, and nothing under Reduce Motion (no neighbours run there), in the background,
// while the match is paused (the field's clock stops) or within `ownGap` of the player's
// own knock.

/// One neighbour sound to play now: what, how loud (linear gain, the distance already
/// in it) and where (pan, -1 left to 1 right).
public struct NeighbourSound: Equatable, Sendable {
  public enum Kind: Sendable, Equatable {
    /// A kubb going over.
    case hit
    /// A kubb struck and left standing, or a stake: quieter and a little higher.
    case tap
    /// The king going down: louder.
    case king
    /// The thrown piece landing: softer and lower (a thud on grass, not wood on wood).
    case land
  }
  public let kind: Kind
  public let gain, pan: Double
  /// The knock's playback rate before its random spread (`NeighbourSounds.rate`).
  public var rate: Double {
    switch kind {
    case .land: NeighbourSounds.landRate
    case .tap: NeighbourSounds.rate * NeighbourSounds.tapRate
    default: NeighbourSounds.rate
    }
  }
}

/// A cue in a neighbour's recording: when (s on the field's clock), what, and its share of
/// its kind's full knock (`level`, by its hit's strength).
struct NeighbourCue: Equatable {
  let time: Double
  let kind: NeighbourSound.Kind
  var level = 1.0
}

public enum NeighbourSounds {
  /// The knock's gain at `nearM` (the pitch beside), against the player's own 0.72 (0.8 x
  /// 0.9, docs/FEEL.md): about 10 dB under it.
  public static let near = 0.22
  static let nearM = 8.0
  /// The gain falls as (nearM / d) ^ fall, d the metres between the pitches' origins:
  /// 12 m 0.12, 14.4 m 0.09, 24 m 0.04.
  static let fall = 1.5
  /// Under this a cue is not played at all.
  static let floor = 0.02
  /// A king going down, and the thrown piece landing, of a kubb's knock.
  public static let king = 1.5, land = 0.55
  /// Every neighbour knock a little lower than the player's (farther), a landing lower
  /// still; each with the player's ± 6% spread.
  public static let rate = 0.9, landRate = 0.72
  /// The most a pitch is put to one side.
  static let pan = 0.8
  /// Neighbour sounds at once, at most (the faintest dropped), on voices of their own.
  public static let voices = 3
  /// s round the player's own knock with no neighbour sound (half either side).
  public static let ownGap = 0.5
  /// s: a cue this late is dropped, not played.
  static let stale = 0.3
  /// A hit's strength (0 to 1) sets its knock between `softest` and the full one: a graze
  /// is quiet, a hard hit full.
  static let softest = 0.35
  /// A kubb struck and left standing, of a topple's knock at that strength, and a little
  /// higher (a tap, not a fall).
  static let stood = 0.45, tapRate = 1.05

  /// A hit's share of the full knock by its strength (none given: the full knock).
  static func share(_ strength: Double?) -> Double {
    guard let s = strength, s.isFinite else { return 1 }
    return softest + (1 - softest) * max(0, min(1, s))
  }

  /// The cues of a throw that left the hand at `at`, in time order (the web's cuesOf): one
  /// for each body struck, at its first hit (a topple, the king's, or a tap for a body left
  /// standing), one for a body that toppled with no hit listed (none should), at its
  /// `toppleT`, and the landing.
  static func cues(_ r: NeighbourRecording, at: Double) -> [NeighbourCue] {
    var out: [NeighbourCue] = []
    let bodies = Dictionary(r.bodies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var heard = Set<String>()
    for h in r.hits ?? [] where h.t.isFinite && h.id != r.projectile.id && !heard.contains(h.id) {
      heard.insert(h.id)
      let level = share(h.strength)
      if let b = bodies[h.id], b.toppleT != nil {
        out.append(NeighbourCue(time: at + h.t, kind: b.kind == "king" ? .king : .hit, level: level))
      } else {
        out.append(NeighbourCue(time: at + h.t, kind: .tap, level: level * stood))
      }
    }
    for b in r.bodies where b.id != r.projectile.id && !heard.contains(b.id) {
      if let t = b.toppleT { out.append(NeighbourCue(time: at + t, kind: b.kind == "king" ? .king : .hit)) }
    }
    if let l = r.landing, l.t.isFinite {
      out.append(NeighbourCue(time: at + l.t, kind: .land, level: share(l.strength)))
    }
    return out.sorted { $0.time < $1.time }
  }

  /// A cue's gain for a pitch whose origin is `d` m from the player's, or 0 (not played):
  /// the distance's, the kind's share and the cue's own `level` (the floor is the
  /// distance's and the kind's, as the web's gainFor, before the level).
  static func gain(distance d: Double, kind: NeighbourSound.Kind, level: Double = 1) -> Double {
    let g = near * min(1, pow(nearM / max(1, d), fall)) * (kind == .king ? king : kind == .land ? land : 1)
    return g < floor ? 0 : g * level
  }

  /// Left or right of a point (x, y) on the ground as the camera looks: from where it
  /// lies across the view, at most `pan` either way.
  static func pan(x: Double, y: Double, camera: Camera) -> Double {
    let dx = x - camera.px, dy = y - camera.py
    let l = hypot(dx, dy)
    guard l > 1e-6 else { return 0 }
    return max(-pan, min(pan, (dx * camera.rx + dy * camera.ry) / l))
  }

  /// Which voice to take for a new sound of `gain` (the web's capVoices): a free one, else
  /// the faintest sounding when it is fainter than this, else none.
  static func voice(gains: [Double?], gain: Double) -> Int? {
    if let free = gains.firstIndex(where: { $0 == nil }) { return free }
    guard let low = gains.indices.min(by: { gains[$0]! < gains[$1]! }), gains[low]! < gain else { return nil }
    return low
  }
}

extension TournamentNeighbours {
  /// The neighbours' sounds that came due since the last call, as heard from `session`'s
  /// camera (the field turned with Team B's view, as drawn); none while the field is not
  /// live or within `ownGap` of the player's own knock (the cues are taken all the same).
  /// The app plays them through PitchAudio, under SOUND.
  public func sounds(session: PitchSession) -> [NeighbourSound] {
    let due = takeCues()
    guard live, !due.isEmpty, !session.ownKnockNear(NeighbourSounds.ownGap / 2) else { return [] }
    let turned = session.scene.neighboursTurned
    let camera = session.shownCamera
    return due.compactMap { pitch, c in
      let g = NeighbourSounds.gain(distance: hypot(pitch.offset.x, pitch.offset.y), kind: c.kind, level: c.level)
      guard g > 0 else { return nil }
      let x = turned ? -pitch.offset.x : pitch.offset.x
      let y = (turned ? -pitch.offset.y : pitch.offset.y) + 4
      return NeighbourSound(kind: c.kind, gain: g, pan: NeighbourSounds.pan(x: x, y: y, camera: camera))
    }
  }
}
