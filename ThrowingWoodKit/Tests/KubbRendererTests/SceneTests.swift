import CoreGraphics
import Foundation
import ImageIO
import KubbEngine
import Testing

@testable import KubbRenderer

private func bitmap(_ w: Int, _ h: Int) -> CGContext {
  let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: Double(h))
  ctx.scaleBy(x: 1, y: -1)
  return ctx
}
private struct Fixture: Decodable {
  let width, height: Int, camera: Camera
  var scene: PitchScene
}
private func fixture(_ name: String) throws -> Fixture {
  let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
  return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}
private func bytes(_ ctx: CGContext) -> [UInt8] {
  let n = ctx.bytesPerRow * ctx.height
  return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: n))
}
/// PITCH_RENDER_OUT=<dir> writes the picture for a look at it.
private func keep(_ ctx: CGContext, _ name: String) {
  #if os(macOS)
    guard let dir = ProcessInfo.processInfo.environment["PITCH_RENDER_OUT"], let image = ctx.makeImage()
    else { return }
    let dest = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
    if let w = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil) {
      CGImageDestinationAddImage(w, image, nil)
      CGImageDestinationFinalize(w)
    }
  #endif
}
private func render(_ f: Fixture, look: String?, effects: SceneEffects? = nil, time: Double = 0)
  -> CGContext
{
  let ctx = bitmap(f.width, f.height)
  PitchRenderer.draw(
    in: ctx, size: CGSize(width: f.width, height: f.height), camera: f.camera, scene: f.scene,
    look: look, effects: effects, time: time)
  return ctx
}

struct SceneTests {
  @Test func sceneIds() {
    #expect(SceneID.shown(nil) == "day")
    #expect(SceneID.shown("day") == "day")
    #expect(SceneID.shown("night") == "night")
    #expect(SceneID.shown("neon") == "neon")
    #expect(SceneID.shown("sunset") == "day")
    #expect(SceneID.shown("Night") == "day")
    #expect(SceneID.row.choices.map { $0[0] } == ["day", "night", "neon"])
    #expect(SceneID.row.choices.map { $0[1] } == ["Day", "Night", "Neon"])
  }

  /// The day, an unknown scene and no scene are the same picture, byte for byte.
  @Test(arguments: ["grass", "mid-match"])
  func unknownSceneIsTheDay(name: String) throws {
    let f = try fixture(name)
    let day = bytes(render(f, look: nil))
    #expect(bytes(render(f, look: "day")) == day)
    #expect(bytes(render(f, look: "sunset")) == day)
    var carried = f
    carried.scene.look = "sunset"
    #expect(bytes(render(carried, look: nil)) == day)
  }

  /// Each scene draws every surface, and differs from the day and from the other.
  @Test(arguments: ["grass", "sand", "snow", "mid-match", "plan"])
  func scenesDraw(name: String) throws {
    let f = try fixture(name)
    let day = bytes(render(f, look: "day"))
    let nightCtx = render(f, look: "night")
    let neonCtx = render(f, look: "neon")
    keep(nightCtx, name + "-night")
    keep(neonCtx, name + "-neon")
    let night = bytes(nightCtx)
    let neon = bytes(neonCtx)
    func share(_ a: [UInt8], _ b: [UInt8]) -> Double {
      var n = 0
      for i in stride(from: 0, to: a.count, by: 4) where a[i] != b[i] || a[i + 1] != b[i + 1] { n += 1 }
      return Double(n) / Double(a.count / 4)
    }
    #expect(share(day, night) > 0.5)
    #expect(share(day, neon) > 0.5)
    #expect(share(night, neon) > 0.5)
    // a scene's world is dark: most of the picture is under the day's darkest ground
    func meanLuma(_ a: [UInt8]) -> Double {
      var sum = 0.0
      for i in stride(from: 0, to: a.count, by: 4) {
        sum += 0.2126 * Double(a[i]) + 0.7152 * Double(a[i + 1]) + 0.0722 * Double(a[i + 2])
      }
      return sum / Double(a.count / 4)
    }
    if f.scene.surface != .snow { #expect(meanLuma(night) < meanLuma(day) * 0.6) }
    #expect(meanLuma(neon) < meanLuma(day) * 0.5)
  }

  @Test func theDayHasNoEffects() {
    #expect(SceneEffects(look: "day", reduced: false) == nil)
    #expect(SceneEffects(look: "sunset", reduced: false) == nil)
    #expect(SceneEffects(look: "night", reduced: true)?.look == "night")
    #expect(SceneEffects(look: "neon", reduced: false)?.look == "neon")
  }
}

@MainActor struct SceneEffectsTests {
  private let dt = 1.0 / 60
  private func armPoints(_ d: DialState) throws -> [CGPoint] {
    let back = try #require(d.powerLo.flatMap { lo in d.powerHi.map { (lo + $0) / 2 } })
    let stop = try #require(d.releaseLo.flatMap { lo in d.releaseHi.map { (lo + $0) / 2 } })
    var a = -5.0
    var angles = [0.0, a]
    while a > -back {
      a = max(-back, a - 400 * dt)
      angles.append(a)
    }
    while a < stop {
      a = min(stop, a + 2400 * dt)
      angles.append(a)
    }
    return angles.map { a in CGPoint(x: sin(a * .pi / 180), y: cos(a * .pi / 180)) }
  }

  /// One practice throw in `look`: the most dust alive at once, and whether the
  /// pieces come to rest where the day's do (a scene is a look only).
  private func throwIn(_ look: String, reduced: Bool, keepAs: String? = nil) throws -> (
    peak: Int, hash: String, settled: Bool
  ) {
    let pitch = try PracticePitch(appVersion: "test")
    pitch.useLook(look, reduced: reduced)
    for p in try armPoints(pitch.dial) {
      pitch.sample(p)
      try pitch.tick(dt)
    }
    pitch.sample(nil)
    try pitch.tick(dt)
    #expect(pitch.playing)
    var frames = 0
    let size = CGSize(width: 390, height: 844)
    while pitch.playing && frames < 2000 {
      try pitch.tick(dt)
      frames += 1
      if let keepAs, frames == 40 {
        let ctx = bitmap(390, 844)
        PitchRenderer.draw(
          in: ctx, size: size, camera: pitch.camera, scene: pitch.scene, look: look,
          effects: pitch.effects, time: pitch.lookTime, reduced: reduced)
        keep(ctx, keepAs)
      }
    }
    // the last dust settles while the next throw is aimed, then the display may sleep
    for _ in 0..<300 where pitch.wantsFrames { try pitch.tick(dt) }
    let rest = pitch.scene.items.map { "\($0.id) \($0.x) \($0.y) \($0.z) \($0.qw)" }.joined(separator: ";")
    return (pitch.effects?.peak ?? 0, rest, !(pitch.effects?.active ?? false))
  }

  @Test func effectsFollowTheThrowAndChangeNothing() throws {
    let day = try throwIn("day", reduced: false)
    let night = try throwIn("night", reduced: false, keepAs: "throw-night")
    let calm = try throwIn("night", reduced: true, keepAs: "throw-night-reduced")
    let neon = try throwIn("neon", reduced: false, keepAs: "throw-neon")
    #expect(day.peak == 0)
    #expect(night.peak > 20)
    #expect(calm.peak < night.peak / 2)
    #expect(neon.peak >= 0)
    #expect(night.hash == day.hash && neon.hash == day.hash && calm.hash == day.hash)
    #expect(night.settled && neon.settled && calm.settled)
  }

  @Test func aSkippedThrowDropsItsDust() throws {
    let pitch = try PracticePitch(appVersion: "test")
    pitch.useLook("night", reduced: false)
    for p in try armPoints(pitch.dial) {
      pitch.sample(p)
      try pitch.tick(dt)
    }
    pitch.sample(nil)
    try pitch.tick(dt)
    for _ in 0..<30 { try pitch.tick(dt) }
    #expect(pitch.effects?.active == true)
    try pitch.skipPlayback()
    #expect(pitch.effects?.active == false)
    pitch.useLook("neon", reduced: false)
    #expect(pitch.effects?.look == "neon")
    pitch.useLook("sunset", reduced: false)
    #expect(pitch.effects == nil)
  }
}
