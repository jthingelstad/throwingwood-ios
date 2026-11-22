import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import KubbEngine
import KubbPitch
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

  @Test func portraitScaleAndPanKeepFarTargetsVisible() throws {
    let f = try fixture("grass")
    for size in [CGSize(width: 390, height: 844), CGSize(width: 440, height: 956)] {
      let reference = PitchProjection(size: CGSize(width: 400, height: 240), camera: f.camera)
      for kubb in f.scene.items where kubb.kind == "kubb" && kubb.y == 8 {
        let base = V3(kubb.x, kubb.y, 0)
        let fx = try #require(reference.project(base)).x
        let p = PitchProjection(size: size, camera: f.camera, focusX: Double(fx))
        let bottom = try #require(p.project(base))
        let top = try #require(p.project(base + V3(0, 0, 0.15)))
        #expect(CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 14).contains(top))
        let g = try #require(p.ground(bottom))
        #expect(simd_distance(g, base) < 1e-9)
        let height = bottom.y - top.y
        #expect(height > 10 && height < 23)
        if kubb.x == 0 { print("Far base kubb at", size, "points high", height) }
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
    var inputCues: [PitchHaptic] = []
    pitch.onFeedback = { if let h = $0.haptic { inputCues.append(h) } }
    let reference = try Engine(appVersion: "test")
    // the session asks for ground impacts, as the app does (PitchSession.askForImpacts):
    // they ride in the recording and nowhere else
    _ = try reference.call("setImpacts", json: #"{"on":true}"#)
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
    #expect(inputCues == [.band, .band, .band, .release])
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
    // this device's own throw: the coach's slow flick is its power verdict
    #expect(pitch.result?.verdicts != nil)
    #expect(pitch.coachSlow == (pitch.result?.verdicts?.power == "SLOW"))
    // Engine v0.3.0 defines hash() for matches only. Hash its canonical raw practice outputs.
    for method in ["recording", "view"] {
      let actual = SHA256.hash(data: Data(try pitch.engine.call(method).utf8))
      let expected = SHA256.hash(data: Data(try reference.call(method).utf8))
      #expect(actual == expected)
    }
    let capture = try pitch.captureReport(size: CGSize(width: 390, height: 844), scale: 3)
    let id = playback.recording.projectile.id
    // A long session that selected sand repeatedly before this throw.
    let sand = try #require(pitch.trail.actions.first)
    pitch.trail.actions.insert(contentsOf: Array(repeating: sand, count: 2500), at: 0)
    let large = try pitch.captureReport(size: CGSize(width: 390, height: 844), scale: 3)
    let compact = try JSONNode.parse(large.message(happened: "Stopped", should: "", selected: [id]))
    let checkpoint = try #require(compact["practice"]?["before"]?.string)
    #expect(compact["practice"]?["ops"]?.isNull == true)
    let replay = try Engine(appVersion: "test")
    _ = try replay.call("setImpacts", json: #"{"on":true}"#)  // as the device drew it
    _ = try replay.call("restorePractice", json: JS.object([("checkpoint", .string(checkpoint))]).json.text)
    _ = try replay.call("apply", json: #require(compact["lastThrow"]?["action"]?.raw.text))
    #expect(try replay.call("recording") == reference.call("recording"))
    try pitch.practice()
    let report = try JSONNode.parse(capture.message(happened: "Stopped", should: "", selected: [id, "king"]))
    #expect(report["mode"]?.string == "practice")
    #expect(report["practice"]?["ops"]?.items.compactMap { $0["type"]?.string } == ["surface", "throw"])
    #expect(Set(report["selectedPieces"]?.items.compactMap { $0["id"]?.string } ?? []) == [id, "king"])
    #expect(report["pitch"] == nil && report["room"] == nil)
    #expect(report["kind"]?.string == "throw")
    #expect(capture.hasLastThrow)
    // Anything else: one trimmed text, the same game, never a throw's answers or pieces.
    let long = String(repeating: "é", count: 2100)
    let feedback = try JSONNode.parse(capture.feedback("  \n" + long + " \n"))
    #expect(feedback["kind"]?.string == "feedback")
    #expect(feedback["text"]?.string?.unicodeScalars.count == 2000)
    for key in ["happened", "should", "selectedPieces"] { #expect(feedback[key] == nil) }
    #expect(feedback["mode"]?.string == "practice")
    #expect(feedback["client"]?.string == "ios")
    #expect(feedback["lastThrow"]?["action"] != nil)
    #expect(try JSONNode.parse(capture.feedback("Hi"))["text"]?.string == "Hi")
    #expect(throws: PitchError.self) { try capture.feedback(" \n ") }
  }

  @Test func reviewFlightShadow() throws {
    let pitch = try PracticePitch(appVersion: "test")
    let size = CGSize(width: 390, height: 844)
    let m = try #require(pitch.marker(in: size))
    try pitch.target(CGPoint(x: m.x + size.width * 0.22, y: m.y), size: size, snap: true)
    for p in try armPoints(pitch.dial) {
      pitch.sample(p)
      try pitch.tick(dt)
    }
    pitch.sample(nil)
    try pitch.tick(dt)
    for _ in 0..<22 { try pitch.tick(dt) }
    let piece = try #require(pitch.scene.items.first { $0.kind == "baton" })
    let shadow = V3(piece.x + 0.55 * piece.z, piece.y - 0.3 * piece.z, 0)
    let reference = PitchProjection(size: CGSize(width: 400, height: 240), camera: pitch.camera)
    let old = try #require(reference.project(shadow))
    // Check the 16e shadow in the original centred framing for the tuned release
    // (engine 0.13: the default arc goes by distance since 0.10, and the person's
    // throw is on the one meter, so the baton is elsewhere 22 frames in).
    #expect(abs(old.x * 0.975 - 267.25) < 1)
    #expect(abs((old.y - 120) * 0.975 + 422 - 626.50) < 1)
    let center = try #require(pitch.scene.projection(size, pitch.camera).project(shadow))
    var ground = pitch.scene
    ground.items.removeAll { $0.kind == "baton" }
    func raster(_ scene: PitchScene) -> CGContext {
      let ctx = bitmap(390, 844)
      ctx.translateBy(x: 0, y: 844)
      ctx.scaleBy(x: 1, y: -1)
      PitchRenderer.draw(in: ctx, size: size, camera: pitch.camera, scene: scene)
      return ctx
    }
    let withBaton = raster(pitch.scene)
    let without = raster(ground)
    let a = withBaton.data!.assumingMemoryBound(to: UInt8.self)
    let b = without.data!.assumingMemoryBound(to: UInt8.self)
    // the baton itself (since the far baseline stands at 41% of the height, 2026-11-22,
    // it is drawn inside the scanned rows too): only its shadow is counted
    let baton = try #require(pitch.scene.projection(size, pitch.camera).project(piece.center))
    var shadowPixels = 0
    for y in 400..<844 {
      for x in 0..<390 {
        let i = (y * 390 + x) * 4
        if a[i] == b[i] && a[i + 1] == b[i + 1] { continue }
        if hypot(Double(x) - baton.x, Double(y) - baton.y) < 45 { continue }
        shadowPixels += 1
        try #require(hypot(Double(x) - center.x, Double(y) - center.y) < 60)
      }
    }
    #expect(shadowPixels > 20)
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
