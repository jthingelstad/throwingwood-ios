import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import KubbEngine
import Testing
import simd

@testable import KubbRenderer

private func bitmap(_ w: Int, _ h: Int) -> CGContext {
  CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

private struct Fixture: Decodable {
  let width, height: Int, scene: PitchScene, camera: Camera
}
private func url(_ name: String, _ ext: String) -> URL {
  Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
}
private func fixture(_ name: String) throws -> Fixture {
  try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url(name, "json")))
}

struct RendererTests {
  @Test(arguments: ["grass", "sand", "snow", "mid-match", "plan"])
  func snapshot(name: String) throws {
    let f = try fixture(name)
    let ctx = bitmap(f.width, f.height)
    let size = CGSize(width: f.width, height: f.height)
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    PitchRenderer.draw(in: ctx, size: size, camera: f.camera, scene: f.scene)
    let image = try #require(ctx.makeImage())
    #if os(macOS)
      if let output = ProcessInfo.processInfo.environment["PITCH_RENDER_OUT"] {
        let dest = URL(fileURLWithPath: output).appendingPathComponent(name + "-ios.png")
        let writer = try #require(
          CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
      }
    #endif
    let source = try #require(CGImageSourceCreateWithURL(url(name + "-ios", "png") as CFURL, nil))
    let reference = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(reference.width == f.width && reference.height == f.height)
    let expected = bitmap(f.width, f.height)
    expected.draw(reference, in: CGRect(origin: .zero, size: size))
    let a = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let b = expected.data!.assumingMemoryBound(to: UInt8.self)
    // Tile-local tolerance keeps a lost distant kubb from hiding in all the grass.
    for y in stride(from: 0, to: f.height, by: 16) {
      for x in stride(from: 0, to: f.width, by: 16) {
        var error = 0
        for row in y..<min(y + 16, f.height) {
          for col in x..<min(x + 16, f.width) {
            let off = (row * f.width + col) * 4
            for i in off..<off + 3 { error += abs(Int(a[i]) - Int(b[i])) }
          }
        }
        try #require(Double(error) / (16 * 16 * 3) < 4, "Tile at \(x),\(y) differs")
      }
    }
  }

  @Test func projectionRoundTripsAcrossAspectRatios() throws {
    let f = try fixture("plan")
    for size in [CGSize(width: 320, height: 700), CGSize(width: 800, height: 280)] {
      let p = PitchProjection(size: size, camera: f.camera)
      let world = V3(0.4, 6.7, 0)
      let screen = try #require(p.project(world))
      let recovered = try #require(p.ground(screen))
      #expect(abs(world.x - recovered.x) < 1e-10 && abs(world.y - recovered.y) < 1e-10)
      #expect(p.project(f.camera.eye - f.camera.forward) == nil)
    }
  }
}

@MainActor struct PracticeTests {
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

  @Test func dialToRestAgreesWithIndependentEngine() throws {
    let pitch = try PracticePitch(appVersion: "test")
    let reference = try Engine(appVersion: "test")
    _ = try reference.call("new", json: #"{"mode":"practice","drill":false,"surface":"grass"}"#)
    try pitch.surface(.sand)
    _ = try reference.call("setSurface", json: #"{"surface":"sand"}"#)
    for point in try armPoints(pitch.dial) {
      pitch.sample(point)
      try pitch.tick(dt)
      let angle = atan2(point.x, point.y) * 180 / .pi
      _ = try reference.call("frame", json: #"{"dt":\#(dt),"arm":\#(angle)}"#)
    }
    pitch.sample(nil)
    try pitch.tick(dt)
    _ = try reference.call("frame", json: #"{"dt":\#(dt)}"#)
    let playback = try #require(pitch.playback)
    #expect(playback.recording.duration > 0.5)
    struct Frame: Decodable { let items: [Piece], camera: Camera }
    var samples = 0
    for _ in 0..<2000 where pitch.playing {
      let before = try #require(pitch.playback)
      try pitch.tick(1 / 120)
      if !before.finished && samples.isMultiple(of: 12) {
        let raw = try reference.call("showAt", json: #"{"t":\#(before.nextTime)}"#)
        let expected = try JSONDecoder().decode(Frame.self, from: Data(raw.utf8))
        #expect(pitch.camera.eye == expected.camera.eye)
        #expect(pitch.scene.items.map(\.id) == expected.items.map(\.id))
        for (ours, theirs) in zip(pitch.scene.items, expected.items) {
          #expect(simd_distance(ours.center, theirs.center) < 0.000011)
          #expect(abs(dot(ours.rotation.vector, theirs.rotation.vector)) > 0.99997)
        }
      }
      samples += 1
    }
    #expect(!pitch.playing && samples > 60)
    #expect(pitch.result == playback.recording.result)
    // Engine v0.3.0 defines hash() for matches only. Hash its canonical raw practice outputs.
    for method in ["recording", "view"] {
      let actual = SHA256.hash(data: Data(try pitch.engine.call(method).utf8))
      let expected = SHA256.hash(data: Data(try reference.call(method).utf8))
      #expect(actual == expected)
    }
  }

  @Test func cancellingAWindupLeavesTheDialReady() throws {
    let pitch = try PracticePitch(appVersion: "test")
    for p in try armPoints(pitch.dial).prefix(12) {
      pitch.sample(p)
      try pitch.tick(dt)
    }
    try pitch.cancelInput()
    #expect(pitch.dial.phase == "idle" && !pitch.playing)
    for p in try armPoints(pitch.dial) {
      pitch.sample(p)
      try pitch.tick(dt)
    }
    pitch.sample(nil)
    try pitch.tick(dt)
    #expect(pitch.playing)
  }

  #if targetEnvironment(simulator)
    @Test func simulatorFrameBudget() throws {
      let scale = 2.0
      let pitch = try PracticePitch(appVersion: "test")
      let size = CGSize(width: 390, height: 844)
      let ctx = bitmap(Int(size.width * scale), Int(size.height * scale))
      ctx.scaleBy(x: scale, y: scale)
      for p in try armPoints(pitch.dial) {
        pitch.sample(p)
        try pitch.tick(dt)
      }
      pitch.sample(nil)
      let release = CFAbsoluteTimeGetCurrent()
      try pitch.tick(dt)
      let releaseMS = (CFAbsoluteTimeGetCurrent() - release) * 1000
      var update = [Double]()
      var total = [Double]()
      for _ in 0..<2000 {
        guard pitch.playback?.finished == false else { break }
        let start = CFAbsoluteTimeGetCurrent()
        try pitch.tick(1 / 120)
        update.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        PitchRenderer.draw(in: ctx, size: size, camera: pitch.camera, scene: pitch.scene)
        ctx.flush()
        total.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
      }
      #expect(total.count > 60)
      func distribution(_ values: [Double]) -> String {
        let s = values.sorted()
        return [0.5, 0.95, 0.99, 1].map { String(format: "%.3f", s[Int(Double(s.count - 1) * $0)]) }
          .joined(separator: "/")
      }
      print(
        "Pitch frames \(total.count), release ms \(releaseMS), update p50/p95/p99/max \(distribution(update)), update+\(scale)x raster \(distribution(total))"
      )
    }
  #endif
}
