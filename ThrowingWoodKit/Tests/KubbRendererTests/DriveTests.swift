import CoreGraphics
import Foundation
import KubbEngine
import KubbPitch
import Testing
import simd

@testable import KubbRenderer

/// Engine 0.16's drive (kubb-engine docs/notes/throw.md "The drive"; the web's
/// plan-sliders.js, tray.js and coach.js): ARC reaches down through flat to a downward
/// drive, its range from `aim.controls.arc` whenever it is drawn, the side view draws the
/// planned flight down as well as up, a close drive does not flip, and the words say so.
/// The position is the web's tests/fixtures/snap-advantage.json: a computer match with
/// Team A handed to a person, a group of field kubbs off the advantage line.
@MainActor struct DriveTests {
  private func fixture(_ name: String) throws -> String {
    let file = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solo"))
    return try String(contentsOf: file, encoding: .utf8)
  }

  /// Standing `d` m short of the nearest field kubb (a far base kubb from 7.5 m), aimed at
  /// it, as the web's tests stand.
  private func at(_ d: Double) throws -> PitchSession {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("advantage"), save: nil)
    app.dismissHandoff()
    try app.reviewStand(short: d)
    #expect(abs(try #require(app.distance) - d) < 1e-6, "\(d) m")
    return app
  }

  /// A swing that makes the plan: back to `back`, a fast flick to the release band's
  /// middle, then the finger lifts.
  private func swing(_ app: PitchSession, back: Double) throws {
    let dt = 1.0 / 60
    let stop = ((app.dial.releaseHi ?? 48) + (app.dial.releaseLo ?? 32)) / 2
    func arm(_ angle: Double) throws {
      let a = angle * .pi / 180
      app.sample(CGPoint(x: sin(a), y: cos(a)))
      try app.tick(dt)
    }
    try arm(0)
    var a = -5.0
    try arm(a)
    while a > -back {
      a = max(-back, a - 400 * dt)
      try arm(a)
    }
    while a < stop {
      a = min(stop, a + 2400 * dt)
      try arm(a)
    }
    app.sample(nil)
    try app.tick(dt)
  }

  @Test func atAMetreAndAHalfTheDefaultIsADriveThatFallsFromTheHand() throws {
    let app = try at(1.5)
    let c = try #require(app.arcControl)
    #expect(c.min < 1 && c.knee == 15 && c.max == 165)
    #expect(app.isDrive && (app.loft ?? 0) < 0)
    // the plate's words, the web's: DRIVE −5°, "Arc, 5 degrees down, drive"
    let down = -PlanScale.whole(app.loft)
    #expect(app.arcTitle == "DRIVE \u{2212}\(down)°")
    #expect(PlanScale.arcValueText(loft: app.loft, drive: true) == "Arc, \(down) degrees down, drive")
    #expect(PlanScale.arcValueText(loft: app.loft, drive: true, name: "") == "\(down) degrees down, drive")
    // the side view draws the engine's planned flight as it is: falling from the hand all
    // the way to the kubb's face
    let arc = try #require(app.scene.arc)
    #expect(arc.count > 10)
    for i in 1..<arc.count { #expect(arc[i].z < arc[i - 1].z, "falls at point \(i)") }
    #expect(arc.last!.z > 0.05, "meets the kubb's face, not the ground")
    // the drive part of the track: 30% at a floor of 0, less as it rises
    #expect(abs(app.driveFraction - 0.3 * (15 - c.min) / 15) < 1e-12)
    // the caption while ARC is held
    #expect(PlanScale.caption(.arc, kubb: false, drive: app.isDrive) == "A DRIVE GOES IN LOW AND HARD, WITH NO FLIP.")
  }

  @Test func theTrackIsTwoScalesJoinedAtTheKnee() throws {
    let app = try at(1.5)
    let c = try #require(app.arcControl)
    let kf = c.driveFraction
    #expect(kf > 0.25 && kf <= 0.3)
    #expect(c.value(at: 0) == c.min && abs(c.value(at: kf) - 15) < 1e-9 && c.value(at: 1) == 165)
    #expect(c.fraction(c.min) == 0 && abs(c.fraction(15) - kf) < 1e-12 && c.fraction(165) == 1)
    for f in stride(from: 0.0, through: 1, by: 0.05) { #expect(abs(c.fraction(c.value(at: f)) - f) < 1e-9) }
    // the marks are the knee's and above, on the upper part; the drive part is hatched
    let marks = c.marks(run: 200)
    #expect(marks.first == 15 && marks.allSatisfy { $0 >= 15 })
    #expect(app.arcMarks(run: 200).allSatisfy { $0.f >= kf - 1e-9 })
    // the slider at its foot plans the floor; the knob sits at the foot
    app.slide(.arc, to: 0, phase: .up)
    try app.tick(1.0 / 60)
    #expect(abs(try #require(app.release) - c.min) < 1e-9 && app.arcPlace < 1e-9)
    // the slider at the knee is no drive; just under it is
    app.slide(.arc, to: kf + 1e-6, phase: .up)
    try app.tick(1.0 / 60)
    #expect(!app.isDrive && app.arcTitle.hasPrefix("ARC "))
    app.slide(.arc, to: kf * 0.9, phase: .up)
    try app.tick(1.0 / 60)
    #expect(app.isDrive)
    // VoiceOver's steps go through the engine (never under the floor)
    for _ in 0..<5 { try app.stepPlan(.arc, by: -1) }
    #expect(abs(try #require(app.release) - c.min) < 1e-9)
    try app.stepPlan(.arc, by: 1)
    #expect(try #require(app.release) > c.min)
  }

  @Test func atFourMetresTheFloorIsHigherAndAtEightThereIsNoDrive() throws {
    let four = try at(4)
    let c4 = try #require(four.arcControl)
    #expect(c4.min > 9 && c4.min < 15)
    #expect(four.driveFraction > 0 && four.driveFraction < 0.1)
    let eight = try at(8)
    let c8 = try #require(eight.arcControl)
    // the floor is the knee: nothing under it is offered, the track straight as before
    #expect(c8.min == 15 && c8.driveKnee == nil && eight.driveFraction == 0 && !eight.isDrive)
    #expect(abs(c8.fraction(90) - 0.5) < 1e-12)
    #expect(eight.arcTitle.hasPrefix("ARC "))
    #expect(PlanScale.caption(.arc, kubb: false, drive: eight.isDrive) == "A HIGHER ARC DROPS IN STEEPER. A LOWER ARC DRIVES IN HARDER.")
  }

  /// The range is the engine's whenever it is drawn: moving the circle with the plate open
  /// moves the floor, and the board is drawn again for it.
  @Test func theRangeFollowsTheCircleWithThePlateOpen() throws {
    let app = try at(1.5)
    try app.tapPlate(.arc)
    #expect(app.openPlate == .arc)
    let near = try #require(app.arcControl).min
    let r = app.revision
    // a far base kubb: the floor goes up to the knee
    try app.reviewStand(short: 8)
    #expect(try #require(app.arcControl).min == 15 && near < 1)
    #expect(app.revision > r)
    #expect(app.openPlate == .arc && app.driveFraction == 0)
  }

  /// A close drive leaves the hand upright and does not turn end over end: the spin
  /// drawing (Spin.swift) never ghosts it.
  @Test func aCloseDriveDoesNotFlip() throws {
    for floor in [false, true] {
      let app = try at(1.5)
      if floor {
        app.slide(.arc, to: 0, phase: .up)
        // the side view's peek goes before the meter takes a swing
        for _ in 0..<90 { try app.tick(1.0 / 60) }
      }
      #expect(app.isDrive)
      let back = ((app.dial.powerHi ?? 100) + (app.dial.powerLo ?? 80)) / 2
      try swing(app, back: back)
      #expect(app.playing, "released")
      var first: Piece?
      var frames = 0
      for _ in 0..<40 where app.playing {
        try app.tick(1.0 / 60)
        guard let b = app.scene.items.first(where: { $0.kind == "baton" && $0.z > 0.1 }) else { continue }
        first = first ?? b
        frames += 1
        #expect(app.scene.spins?[b.id] == nil, "no spin drawn (\(floor ? "floor" : "default"))")
      }
      #expect(frames > 3)
      let b = try #require(first)
      let up = 1 - 2 * (b.qx * b.qx + b.qy * b.qy)
      #expect(acos(min(1, up)) * 180 / .pi < 25, "upright at release")
    }
  }

  /// The coach after a drive that fell SHORT leads with A DRIVE NEEDS MORE POWER.; a SLOW
  /// flick wins; a throw that is no drive is not coached for being short.
  @Test func aDriveThatFallsShortIsCoached() throws {
    #expect(Coach.line(thrown: 9, slow: false, short: true, stage: .rest)?.lead == "A DRIVE NEEDS MORE POWER.")
    #expect(Coach.line(thrown: 9, slow: true, short: true, stage: .rest)?.lead == "SLOW FLICK. FLICK FASTER.")
    #expect(Coach.line(thrown: 9, slow: false, short: false, stage: .rest) == nil)
    #expect(Coach.shortDrive(power: "SHORT", drive: true) && !Coach.shortDrive(power: "SHORT", drive: false))
    for drive in [true, false] {
      let app = try at(drive ? 1.5 : 8)
      #expect(app.isDrive == drive)
      let lo = try #require(app.dial.powerLo)
      try swing(app, back: lo - 30)
      for _ in 0..<2000 where app.result == nil { try app.tick(1.0 / 60) }
      #expect(app.result?.verdicts?.power == "SHORT")
      #expect(app.coachShort == drive)
    }
  }

  /// The meter at a drive: the power band far round, short of the overpowered zone, so the
  /// red starts at the engine's mark, never over the band (the web's drive.test.mjs).
  @Test func theMeterAtADriveKeepsItsBandClearOfTheOverpoweredZone() throws {
    for (d, floor) in [(4.0, false), (4.0, true), (1.5, true)] {
      let app = try at(d)
      if floor {
        app.slide(.arc, to: 0, phase: .up)
        try app.tick(1.0 / 60)
      }
      let lo = try #require(app.dial.powerLo), hi = try #require(app.dial.powerHi)
      let tag = "\(d) m\(floor ? " at the floor" : "")"
      #expect(lo >= 120 && hi <= 150, "\(tag): \(lo) to \(hi)")
      #expect(hi < app.dial.overDeg, "\(tag): the zone starts past the band")
    }
  }

  /// A thrown kubb has no drive: its range starts at the knee and its words are its own.
  @Test func aThrownKubbHasNoDrive() throws {
    let app = try PitchSession(appVersion: "test")
    try app.restore(fixture("inkast"), save: nil)
    app.dismissHandoff()
    #expect(app.throwsKubb)
    #expect(try #require(app.arcControl).min >= 15)
    #expect(app.driveFraction == 0 && !app.isDrive && app.arcTitle.hasPrefix("ARC "))
    #expect(PlanScale.caption(.arc, kubb: true) == "A HIGHER ARC DROPS IN STEEPER. A LOWER ONE SKIDS IN.")
  }
}
