import Foundation
import simd

// The Tournament's other pitches heard, quiet and far (the owner, 2026-11-22: "We should
// hear the sounds from the other pitches."). The web's src/game/neighbour-sound.js, its
// numbers. The engine's neighbour recording carries no timeline (no touches, contacts or
// landing: kubb-engine session/neighbours.lua keeps a far pitch's recording small), so the
// cues come from what it does carry: each kubb's and the king's `toppleT` (the moment it
// went over) and the thrown piece's poses (the first frame it is on the ground after it
// flew). Played with the game's own knock takes, lower (farther); sound only, never a
// haptic, and nothing under Reduce Motion (no neighbours run there), in the background,
// while the match is paused (the field's clock stops) or within `ownGap` of the player's
// own knock.

/// One neighbour sound to play now: what, how loud (linear gain, the distance already
/// in it) and where (pan, -1 left to 1 right).
public struct NeighbourSound: Equatable, Sendable {
  public enum Kind: Sendable, Equatable {
    /// A kubb going over.
    case hit
    /// The king going down: louder.
    case king
    /// The thrown piece landing: softer and lower (a thud on grass, not wood on wood).
    case land
  }
  public let kind: Kind
  public let gain, pan: Double
  /// The knock's playback rate before its random spread (`NeighbourSounds.rate`).
  public var rate: Double { kind == .land ? NeighbourSounds.landRate : NeighbourSounds.rate }
}

/// A cue in a neighbour's recording: when (s on the field's clock) and what.
struct NeighbourCue: Equatable {
  let time: Double
  let kind: NeighbourSound.Kind
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
  /// m: the thrown piece's centre this low is on the ground, once it has been `flewZ` high.
  static let landZ = 0.06, flewZ = 0.2

  /// The cues of a throw that left the hand at `at`, in time order.
  static func cues(_ r: NeighbourRecording, at: Double) -> [NeighbourCue] {
    var out: [NeighbourCue] = []
    let k = r.poseScale
    for b in r.bodies {
      if b.id == r.projectile.id {
        // the first frame on the ground after it flew
        var flew = false
        for j in 0..<b.frames where j * 7 + 2 < b.poses.count {
          let z = Double(b.poses[j * 7 + 2]) / k
          if z > flewZ {
            flew = true
          } else if flew && z <= landZ {
            out.append(NeighbourCue(time: at + Double(b.start + j) * r.frameDt, kind: .land))
            break
          }
        }
      } else if let t = b.toppleT {
        out.append(NeighbourCue(time: at + t, kind: b.kind == "king" ? .king : .hit))
      }
    }
    return out.sorted { $0.time < $1.time }
  }

  /// A cue's gain for a pitch whose origin is `d` m from the player's, or 0 (not played).
  static func gain(distance d: Double, kind: NeighbourSound.Kind) -> Double {
    let g = near * min(1, pow(nearM / max(1, d), fall)) * (kind == .king ? king : kind == .land ? land : 1)
    return g < floor ? 0 : g
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
      let g = NeighbourSounds.gain(distance: hypot(pitch.offset.x, pitch.offset.y), kind: c.kind)
      guard g > 0 else { return nil }
      let x = turned ? -pitch.offset.x : pitch.offset.x
      let y = (turned ? -pitch.offset.y : pitch.offset.y) + 4
      return NeighbourSound(kind: c.kind, gain: g, pan: NeighbourSounds.pan(x: x, y: y, camera: camera))
    }
  }
}
