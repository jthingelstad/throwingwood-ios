import CoreGraphics
import Foundation
import Testing
import simd

@testable import KubbRenderer

/// A thrown kubb at SPIN's most (about 69 rad/s, eleven turns a second) is drawn as a
/// spin where the frames cannot show the turn, and plainly where they can (Spin.swift).
@MainActor struct SpinTests {
  static let omega = 69.0  // rad/s: SPIN at its most

  /// A kubb standing up at (0, 4, 0.5), turned `deg` about its long axis (`twist`) or end
  /// over end.
  static func kubb(_ deg: Double, twist: Bool, id: String = "a1") -> Piece {
    let a = deg * .pi / 180
    let q = twist ? simd_quatd(angle: a, axis: V3(0, 0, 1)) : simd_quatd(angle: a, axis: V3(1, 0, 0))
    return Piece(id: id, kind: "kubb", team: "A", x: 0, y: 4, z: 0.5, qw: q.real, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z)
  }
  /// The turn a frame of `dt` s of shown time makes at `omega`, in degrees.
  static func perFrame(_ hz: Double, speed: Double = 1) -> Double { omega / hz * speed * 180 / .pi }

  @Test func atSixtyFramesASecondItIsASpin() {
    let turn = Self.perFrame(60)
    #expect(abs(turn - 65.9) < 0.1)
    #expect(SpinTune.amount(Self.kubb(10, twist: true), Self.kubb(10 + turn, twist: true), kind: "kubb") == 1)
  }

  /// At 120 frames a second the same spin turns half as far a frame (33 degrees): a
  /// touch of blur; in slow motion (a quarter speed, 16 degrees a frame at 60) none.
  @Test func at120HzAndInSlowMotionLessOrNone() {
    let k120 = SpinTune.amount(Self.kubb(10, twist: true), Self.kubb(10 + Self.perFrame(120), twist: true), kind: "kubb")
    #expect(k120 > 0 && k120 < 0.25)
    let slow = SpinTune.amount(
      Self.kubb(10, twist: true), Self.kubb(10 + Self.perFrame(60, speed: 0.25), twist: true), kind: "kubb")
    #expect(slow == 0)
    let slow120 = SpinTune.amount(
      Self.kubb(10, twist: true), Self.kubb(10 + Self.perFrame(120, speed: 0.25), twist: true), kind: "kubb")
    #expect(slow120 == 0)
  }

  /// End over end a half turn repeats: the blur starts at twice the twist's turn.
  @Test func endOverEndAndTheBaton() {
    #expect(SpinTune.amount(Self.kubb(0, twist: false), Self.kubb(45, twist: false), kind: "kubb") == 0)
    #expect(SpinTune.amount(Self.kubb(0, twist: false), Self.kubb(110, twist: false), kind: "kubb") == 1)
    // a baton is round about its long axis: its twist never blurs
    var b0 = Self.kubb(0, twist: true, id: "baton1"), b1 = Self.kubb(66, twist: true, id: "baton1")
    #expect(SpinTune.amount(b0, b1, kind: "baton") == 0)
    b0 = Self.kubb(0, twist: false, id: "baton1")
    b1 = Self.kubb(110, twist: false, id: "baton1")
    #expect(SpinTune.amount(b0, b1, kind: "baton") == 1)
  }

  /// The drawing: a spinning piece shows its in-between poses, and in Black & White they
  /// are solid, the picture still one bit.
  @Test(arguments: ["day", "neon", "bw"])
  func aSpinIsDrawn(look: String) throws {
    let app = try SceneLooksTests.match(look)
    app.dismissHandoff()
    let size = SceneLooksTests.upright
    var still = app.scene
    let from = Self.kubb(20, twist: true, id: "spinner")
    let to = Self.kubb(20 + Self.perFrame(60), twist: true, id: "spinner")
    still.items.append(to)
    var spun = still
    spun.spins = SpinTune.spins(from: ["spinner": from], to: still.items)
    #expect(spun.spins?["spinner"]?.u == 1)
    func draw(_ s: PitchScene) -> CGContext {
      SceneLooksTests.picture(size) { c in
        PitchRenderer.draw(in: c, size: size, camera: app.shownCamera, scene: s, look: look)
      }
    }
    let a = draw(still), b = draw(spun)
    SceneLooksTests.keep(b, "\(look)-spin")
    SceneLooksTests.keep(a, "\(look)-spin-plain")
    #expect(SceneLooksTests.pixels(a) != SceneLooksTests.pixels(b))
    if look == "bw" {
      let px = SceneLooksTests.pixels(b)
      var grey = 0
      for i in stride(from: 0, to: px.count, by: 4) where !(px[i] == px[i + 1] && px[i + 1] == px[i + 2] && (px[i] == 0 || px[i] == 255)) {
        grey += 1
      }
      #expect(grey == 0)
    }
  }
}
