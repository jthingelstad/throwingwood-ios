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

struct Aim: Decodable {
  struct Plan: Decodable { let loft: Double?, tilt, spin: Int? }
  struct Wind: Decodable { let text: String }
  let wind: Wind?, advText: String?
  let plan: Plan?, mix: Double?, projectile: String?
  let marker, thrower: GroundMark?
  let arc: [WorldPoint]?, advY: Double?
}
struct AimOutput: Decodable {
  let aim: Aim, camera: Camera
  let dial: DialState?, recording: Recording?
}
struct ViewOutput: Decodable {
  let need: MatchNeed
  let aim: Aim, camera: Camera, items: [Piece], surface: Surface, set: String, dial: DialState
}
private struct Shown: Decodable {
  let camera: Camera, speed: Double, done: Bool, dial: DialState
}

public struct HitBurst {
  public let kind: String, age: Double
  let anchor: V3, focusX: Double?
  public func point(size: CGSize, camera: Camera) -> CGPoint? {
    PitchProjection(size: size, camera: camera, focusX: focusX ?? 200).project(anchor)
  }
}

public typealias PracticePitch = PitchSession

@MainActor
public final class PitchSession {
  let engine: Engine
  private let decoder = JSONDecoder()
  private var input: any ThrowInput
  private(set) var playback: Playback?
  public internal(set) var scene: PitchScene, camera: Camera, dial: DialState
  public private(set) var result: ThrowResult?, bursts: [HitBurst] = []
  private var resultAge = 0.0
  public let options: SoloOptions
  public internal(set) var need: MatchNeed?, handoff: MatchNeed.Handoff?, placement: PlacementCheck?
  public internal(set) var revision = 0
  public internal(set) var plan = false, walking = false
  public private(set) var arcDegrees: Int?, sideStep: Int?
  var mix = 0.0
  var save: MatchSave?
  var cursor: GroundMark?
  public var canAim: Bool {
    !playing && handoff == nil && (need == nil || (need?.kind == "throw" && need?.cpu == false))
  }
  public private(set) var windText: String?, advantageText: String?, slow = false
  var walkAxis = CGPoint.zero
  var levelOverride: String?
  public var playing: Bool { playback != nil }

  public init(appVersion: String, input: any ThrowInput = PointerDial()) throws {
    self.input = input
    engine = try Engine(appVersion: appVersion)
    options = try SoloOptions(engine: engine)
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

  func read<T: Decodable>(_ method: String, _ args: String = "") throws -> T {
    try decoder.decode(T.self, from: Data(engine.call(method, json: args).utf8))
  }
  func aim(_ a: Aim, camera c: Camera) {
    windText = a.wind?.text
    advantageText = a.advText
    camera = c
    mix = a.mix ?? 0
    arcDegrees = a.plan?.loft.map { Int($0.rounded()) }
    sideStep = a.projectile == "kubb" ? a.plan?.spin : a.plan?.tilt
    scene.advantageY = a.advY
    scene.marker = a.marker
    let reference = PitchProjection(size: CGSize(width: 400, height: 240), camera: c)
    if let marker = a.marker, marker.shown != false, let p = reference.project(marker.point) {
      scene.focusX = Double(p.x)
    } else {
      scene.focusX = nil
    }
    scene.thrower = a.thrower
    scene.arc = a.arc?.map(\.vector)
  }
  func adopt(_ v: ViewOutput) throws {
    scene = PitchScene(surface: v.surface, set: v.set, items: v.items)
    dial = v.dial
    aim(v.aim, camera: v.camera)
    if need != nil {
      need = v.need
      if let levelOverride, v.need.kind == "throw", v.need.cpu == false {
        try useLevel(levelOverride)
      }
      // A resignation can retain the preceding informative card in the engine view.
      handoff = v.need.kind == "throw" ? v.need.card?.handoff : nil
      placement = nil
      cursor = v.need.cursor
      try settleScene()
      revision += 1
    }
  }

  func resetPresentation() {
    input.reset()
    playback = nil
    result = nil
    bursts = []
    plan = false
    walking = false
    mix = 0
    slow = false
    walkAxis = .zero
    levelOverride = nil
    handoff = nil
    placement = nil
    cursor = nil
    revision += 1
  }

  public func surface(_ s: Surface) throws {
    guard !playing else { return }
    try adopt(read("setSurface", #"{"surface":"\#(s.rawValue)"}"#))
  }
  public func marker(in size: CGSize) -> CGPoint? {
    guard let m = scene.marker, m.shown != false else { return nil }
    return scene.projection(size, camera).project(m.point)
  }
  // Aim commands return the camera and plan. Only the session can supply the
  // corresponding dial ranges and prompt. A stationary board may get no more frames.
  func replan(_ method: String, _ args: String) throws {
    struct DialView: Decodable { let dial: DialState }
    let previousArc = arcDegrees
    let previousSide = sideStep
    let a: AimOutput = try read(method, args)
    aim(a.aim, camera: a.camera)
    let view: DialView = try read("view")
    dial = view.dial
    if arcDegrees != previousArc || sideStep != previousSide { revision += 1 }
  }

  public func target(_ point: CGPoint, size: CGSize, snap: Bool, tap: Bool = false) throws {
    guard canAim, let g = scene.projection(size, camera).ground(point), !tap || g.y > 0.5 else {
      return
    }
    try replan("setTarget", #"{"x":\#(g.x),"y":\#(g.y),"snap":\#(snap)}"#)
  }
  public func sample(_ point: CGPoint?) { if canAim && !plan { input.sample(point) } }

  public func cancelInput() throws {
    input.reset()
    guard canAim else { return }
    // The session's plan-held frame disarms even a forward swing. Ease immediately back to aim.
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
    guard handoff == nil, need == nil || need?.kind == "throw" else { return changed }
    let args: String
    if walking && walkAxis != .zero {
      args = #"{"dt":\#(dt),"plan":\#(plan),"walk":{"dx":\#(walkAxis.x),"dy":\#(walkAxis.y)}}"#
    } else if !plan, let sample = input.frame(after: dt) {
      args = sample
    } else if (plan && mix < 1) || (!plan && mix > 0) || need?.cpu == true {
      args = #"{"dt":\#(dt),"plan":\#(plan)}"#
    } else {
      return changed
    }
    let a: AimOutput = try read("frame", args)
    aim(a.aim, camera: a.camera)
    if let d = a.dial { dial = d }
    if let recording = a.recording {
      walkAxis = .zero
      walking = false
      plan = false
      input.reset()
      playback = Playback(recording)
      result = nil
      scene.arc = nil
      scene.marker = nil
      scene.thrower = nil
      try play(0)
      try checkpoint()
    }
    return true
  }

  public func skipPlayback() throws {
    guard let p = playback else { return }
    result = p.recording.result
    resultAge = 0
    bursts = []
    playback = nil
    try adopt(read("view"))
  }

  private func play(_ dt: Double) throws {
    guard var p = playback else { return }
    if !p.finished {
      let t = min(p.nextTime, p.recording.duration)
      let shown: Shown = try read("showAt", #"{"t":\#(t)}"#)
      scene.items = p.pieces(at: t)
      slow = shown.speed < 0.99
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
      return HitBurst(kind: b.kind, age: age, anchor: b.anchor.vector, focusX: scene.focusX)
    }
    p.realTime += dt
    if p.rest >= 0.8 && bursts.isEmpty {
      playback = nil
      try adopt(read("view"))
    } else {
      playback = p
    }
  }
}
