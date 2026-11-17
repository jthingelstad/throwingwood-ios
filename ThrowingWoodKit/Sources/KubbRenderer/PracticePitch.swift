import CoreGraphics
import Foundation
import KubbEngine

public struct DialState: Decodable, Equatable, Sendable {
  public let phase: String
  public let arm, crank, back, deadDeg, overDeg: Double
  public let powerLo, powerHi, releaseLo, releaseHi, lastBack, lastStop: Double?
  public let prompt: String?
}

/// A control gets samples in dial-local units and returns a session frame on demand.
/// Unit (0,0) is the centre. Lifting during a flick sends the engine a frame without an arm.
public protocol ThrowInput {
  mutating func sample(_ point: CGPoint?)
  mutating func frame(after dt: Double) -> String?
  mutating func reset()
}

public struct PointerDial: ThrowInput {
  private struct Contact {
    var arm: Double, fresh = true, lifted = false
  }
  // Coalesce motion within one contact, preserve up/down boundaries across display ticks.
  private var contacts: [Contact] = []
  private var elapsed = 0.0
  public init() {}
  public mutating func sample(_ point: CGPoint?) {
    if let point {
      let arm = atan2(point.x, point.y) * 180 / .pi
      if contacts.last?.lifted == false {
        contacts[contacts.count - 1].arm = arm
        contacts[contacts.count - 1].fresh = true
      } else {
        contacts.append(Contact(arm: arm))
      }
    } else if !contacts.isEmpty {
      contacts[contacts.count - 1].lifted = true
    }
  }
  public mutating func frame(after dt: Double) -> String? {
    guard let contact = contacts.first else { return nil }
    elapsed += dt
    if !contact.fresh && contact.lifted {
      contacts.removeFirst()
      elapsed = 0
      return #"{"dt":\#(dt)}"#
    }
    guard contact.fresh || elapsed >= 1.0 / 30 - 0.002 else { return nil }
    contacts[0].fresh = false
    defer { elapsed = 0 }
    return #"{"dt":\#(elapsed),"arm":\#(contact.arm)}"#
  }
  public mutating func reset() { self = Self() }
}

private struct Aim: Decodable {
  let marker, thrower: GroundMark?
  let arc: [WorldPoint]?, advY: Double?
}
private struct AimOutput: Decodable {
  let aim: Aim, camera: Camera
  let dial: DialState?, recording: Recording?
}
private struct ViewOutput: Decodable {
  let aim: Aim, camera: Camera, items: [Piece], surface: Surface, set: String, dial: DialState
}
private struct Shown: Decodable {
  let camera: Camera, speed: Double, done: Bool, dial: DialState
}

public struct HitBurst {
  public let kind: String, age: Double
  let anchor: V3
  public func point(size: CGSize, camera: Camera) -> CGPoint? {
    PitchProjection(size: size, camera: camera).project(anchor)
  }
}

@MainActor
public final class PracticePitch {
  let engine: Engine
  private let decoder = JSONDecoder()
  private var input: any ThrowInput
  private(set) var playback: Playback?
  public private(set) var scene: PitchScene, camera: Camera, dial: DialState
  public private(set) var result: ThrowResult?, bursts: [HitBurst] = []
  private var resultAge = 0.0
  public var playing: Bool { playback != nil }

  public init(appVersion: String, input: any ThrowInput = PointerDial()) throws {
    self.input = input
    engine = try Engine(appVersion: appVersion)
    let v = try decoder.decode(
      ViewOutput.self,
      from: Data(
        engine.call(
          "new",
          json:
            #"{"mode":"practice","drill":false,"surface":"grass"}"#
        ).utf8))
    scene = PitchScene(surface: v.surface, set: v.set, items: v.items)
    camera = v.camera
    dial = v.dial
    aim(v.aim, camera: v.camera)
  }

  private func read<T: Decodable>(_ method: String, _ args: String = "") throws -> T {
    try decoder.decode(T.self, from: Data(engine.call(method, json: args).utf8))
  }
  private func aim(_ a: Aim, camera c: Camera) {
    camera = c
    scene.advantageY = a.advY
    scene.marker = a.marker
    scene.thrower = a.thrower
    scene.arc = a.arc?.map(\.vector)
  }
  private func adopt(_ v: ViewOutput) {
    scene = PitchScene(surface: v.surface, set: v.set, items: v.items)
    dial = v.dial
    aim(v.aim, camera: v.camera)
  }

  public func surface(_ s: Surface) throws {
    guard !playing else { return }
    try adopt(read("setSurface", #"{"surface":"\#(s.rawValue)"}"#))
  }
  public func marker(in size: CGSize) -> CGPoint? {
    guard let m = scene.marker, m.shown != false else { return nil }
    return PitchProjection(size: size, camera: camera).project(m.point)
  }
  public func target(_ point: CGPoint, size: CGSize, snap: Bool) throws {
    guard !playing, let g = PitchProjection(size: size, camera: camera).ground(point) else {
      return
    }
    let a: AimOutput = try read("setTarget", #"{"x":\#(g.x),"y":\#(g.y),"snap":\#(snap)}"#)
    aim(a.aim, camera: a.camera)
  }
  public func sample(_ point: CGPoint?) { if !playing { input.sample(point) } }

  public func cancelInput() throws {
    input.reset()
    guard !playing else { return }
    // v0.3's plan-held frame disarms even a forward swing. Ease immediately back to aim.
    let _: AimOutput = try read("frame", #"{"plan":true,"dt":0.001}"#)
    let a: AimOutput = try read("frame", #"{"dt":0.016666666666666666}"#)
    aim(a.aim, camera: a.camera)
    if let d = a.dial { dial = d }
  }

  /// One display tick. Returns true only when the screen needs repainting.
  @discardableResult public func tick(_ delta: Double) throws -> Bool {
    let dt = min(max(delta, 0.00001), 0.05)
    if playback != nil {
      try play(dt)
      return true
    }
    var changed = false
    if result != nil {
      resultAge += dt
      if resultAge >= 6 {
        result = nil
        changed = true
      }
    }
    guard let args = input.frame(after: dt) else { return changed }
    let a: AimOutput = try read("frame", args)
    aim(a.aim, camera: a.camera)
    if let d = a.dial { dial = d }
    if let recording = a.recording {
      input.reset()
      playback = Playback(recording)
      result = nil
      scene.arc = nil
      scene.marker = nil
      scene.thrower = nil
      try play(0)
    }
    return true
  }

  private func play(_ dt: Double) throws {
    guard var p = playback else { return }
    if !p.finished {
      let t = min(p.nextTime, p.recording.duration)
      let shown: Shown = try read("showAt", #"{"t":\#(t)}"#)
      scene.items = p.pieces(at: t)
      camera = shown.camera
      dial = shown.dial
      for i in p.starts.indices
      where p.starts[i] == nil && t >= p.recording.timeline.bursts[i].start {
        p.starts[i] = p.realTime
      }
      if shown.done {
        p.finished = true
        result = p.recording.result
        resultAge = 0
      }
      p.nextTime = min(p.recording.duration, t + dt * shown.speed)
    } else {
      p.rest += dt
    }
    bursts = p.starts.enumerated().compactMap { i, start in
      guard let start else { return nil }
      let b = p.recording.timeline.bursts[i]
      let age = p.realTime - start
      guard age < (b.kind == "double" ? 0.7 : 0.6) else { return nil }
      return HitBurst(kind: b.kind, age: age, anchor: b.anchor.vector)
    }
    p.realTime += dt
    if p.rest >= 0.8 && bursts.isEmpty {
      try adopt(read("view"))
      playback = nil
    } else {
      playback = p
    }
  }
}
