import Foundation
import simd

// The Tournament's other pitches heard, quiet and far (the owner, 2026-11-22: "We should
// hear the sounds from the other pitches."). The engine's neighbour recording carries no
// timeline (no touches, contacts or landing: kubb-engine session/neighbours.lua keeps a far
// pitch's recording small), so the cues come from what it does carry: each moved body's
// first moving frame (the moment it was struck), its `toppleT` (the moment a kubb or the
// king went over), and the thrown piece's poses (the frame it comes down to the grass).
// Sound only: never a haptic, and nothing under Reduce Motion (no neighbours run there),
// in the background or while the match is paused (the field's clock stops).

/// One neighbour sound to play now: what, how loud (linear gain, the distance already
/// in it) and where (pan, -1 left to 1 right).
public struct NeighbourSound: Equatable, Sendable {
  public enum Kind: Sendable, Equatable {
    /// Wood on wood: a kubb struck or going over (the player's own knock takes).
    case knock
    /// A thrown piece coming down on the grass (a soft synthesized thud: the player's own
    /// landing has no sound, the web having no ground recordings, but far off a landing is
    /// the thing heard most).
    case thud
  }
  public let kind: Kind
  public let gain, pan: Double
}

/// A cue in a neighbour's recording: when (s on the field's clock), where (its pitch's own
/// frame), what, and how much it weighs (1 a kubb, `king` the king, the strength of a
/// landing folded in).
struct NeighbourCue: Equatable {
  let time: Double
  let x, y: Double
  let kind: NeighbourSound.Kind
  let weight: Double
}

public enum NeighbourSounds {
  /// The loudest a neighbour may be: the pitch beside, close by. The player's own knock is
  /// 0.8 x weight x (0.25 + 0.75 s) (docs/FEEL.md): 0.18 for the faintest touch, 0.72 for
  /// a full strike; a neighbour never reaches the faintest.
  public static let most = 0.12
  /// m from the player's pitch at which a neighbour is at `most`; beyond it the level falls
  /// with the square of the distance (8 m: the pitch beside; its near half is clearly
  /// heard, the far row about a quarter of that, faint).
  static let near = 8.0
  /// The king going down: a little more than a kubb.
  static let king = 1.35
  /// A kubb going over after it was struck, the second sound of one hit, softer.
  static let topple = 0.6
  /// A landing's weight before its strength: soft, as grass is.
  static let landing = 0.75
  /// Below this gain a sound is not worth a voice.
  static let floor = 0.006
  /// At most this many neighbour sounds start in one frame, the loudest kept, and the
  /// audio engine has as many neighbour voices: a busy frame drops the faintest.
  public static let voices = 3
  /// A cue later than this behind the clock is let go (a pause or a jump of the clock).
  static let stale = 0.25

  /// The cues of a throw that left the hand at `at`: a knock where each kubb or the king
  /// was struck (its track's first frame), another, softer, where one went over (`toppleT`,
  /// when it is a beat after the strike), and a thud where the thrown piece first comes
  /// down to the ground.
  static func cues(_ r: NeighbourRecording, at: Double) -> [NeighbourCue] {
    var out: [NeighbourCue] = []
    let s = r.poseScale, dt = r.frameDt
    func pose(_ b: NeighbourRecording.Body, _ f: Int) -> V3? {
      let i = f * 7
      guard f >= 0, i + 2 < b.poses.count else { return nil }
      return V3(Double(b.poses[i]), Double(b.poses[i + 1]), Double(b.poses[i + 2])) / s
    }
    for b in r.bodies {
      guard b.frames > 0, let p0 = pose(b, 0) else { continue }
      if b.id == r.projectile.id {
        // the first frame it comes down near the grass, still falling
        for f in 1..<b.frames {
          guard let a = pose(b, f - 1), let p = pose(b, f) else { break }
          if p.z < 0.09 && a.z > p.z {
            let speed = min(1, (a.z - p.z) / dt / 4)
            out.append(NeighbourCue(
              time: at + Double(b.start + f) * dt, x: p.x, y: p.y, kind: .thud,
              weight: landing * (0.45 + 0.55 * speed)))
            break
          }
        }
        continue
      }
      guard b.kind == "kubb" || b.kind == "king" else { continue }
      let w = b.kind == "king" ? king : 1
      let struck = Double(b.start) * dt
      out.append(NeighbourCue(time: at + struck, x: p0.x, y: p0.y, kind: .knock, weight: w))
      if let t = b.toppleT, t > struck + 0.15 {
        let f = min(b.frames - 1, max(0, Int((t / dt).rounded()) - b.start))
        let p = pose(b, f) ?? p0
        out.append(NeighbourCue(time: at + t, x: p.x, y: p.y, kind: .knock, weight: w * topple))
      }
    }
    return out.sorted { $0.time < $1.time }
  }

  /// How loud a sound at `point` (the player's pitch's frame, as drawn) is: `most` within
  /// `near` m of the player's pitch centre (0, 4), falling with the square of the distance
  /// beyond, times its weight.
  static func gain(at point: V3, weight: Double) -> Double {
    let d = max(near, simd_distance(V2(point.x, point.y), V2(0, 4)))
    return min(most * king, most * weight * (near / d) * (near / d))
  }

  /// Left or right as the camera looks: the sound's bearing, kept off the hard edges.
  static func pan(at point: V3, camera: Camera) -> Double {
    let v = point - camera.eye
    let ahead = max(2, dot(v, camera.forward))
    return max(-0.8, min(0.8, dot(v, camera.right) / ahead * 0.7))
  }

  /// Of the sounds due in one frame, the loudest `voices`, louder than `floor`.
  static func loudest(_ sounds: [NeighbourSound]) -> [NeighbourSound] {
    Array(sounds.filter { $0.gain >= floor }.sorted { $0.gain > $1.gain }.prefix(voices))
  }
}

extension TournamentNeighbours {
  /// The neighbours' sounds that came due since the last call, as heard from `session`'s
  /// camera (the field turned with Team B's view, as drawn), the loudest `voices` of them;
  /// none while the field is not live. The app plays them through PitchAudio, under SOUND.
  public func sounds(session: PitchSession) -> [NeighbourSound] {
    let due = takeCues()
    guard live, !due.isEmpty else { return [] }
    let turned = session.scene.neighboursTurned
    let camera = session.shownCamera
    return NeighbourSounds.loudest(due.map { pitch, c in
      var p = V3(pitch.offset.x + c.x, pitch.offset.y + c.y, 0.1)
      if turned { (p.x, p.y) = (-p.x, 8 - p.y) }
      return NeighbourSound(
        kind: c.kind, gain: NeighbourSounds.gain(at: p, weight: c.weight),
        pan: NeighbourSounds.pan(at: p, camera: camera))
    })
  }
}
