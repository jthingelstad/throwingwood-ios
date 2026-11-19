import Foundation
import Testing

@testable import KubbRenderer

/// The throw's coach line (Coach.swift), the web's tests/game/coach.test.mjs:
/// who it shows for and the line for each part of the stroke.
struct CoachTests {
  private let lo = 112.0

  private func stage(_ phase: String?, _ back: Double? = nil, band: Bool = true) -> Coach.Stage {
    Coach.stage(phase: phase, back: back, powerLo: band ? lo : nil)
  }

  @Test func theStrokesStageRestWindingThenTheBandAndTheFlick() {
    #expect(stage("idle") == .rest)
    #expect(stage("cooldown") == .rest)
    #expect(stage("winding", 0) == .winding)
    #expect(stage("winding", 111.9) == .winding)
    #expect(stage("winding", 112) == .band)
    // past the band is still the flick's turn (the meter says EASE OFF)
    #expect(stage("winding", 140) == .band)
    #expect(stage("swinging", 120) == .band)
    // no band known: winding is winding
    #expect(stage("winding", 90, band: false) == .winding)
    #expect(stage(nil, band: false) == .rest)
  }

  @Test func theStageReadsTheSessionsDial() throws {
    let json = #"{"phase":"winding","arm":0,"crank":0,"back":120,"deadDeg":0,"overDeg":0,"powerLo":112,"powerHi":128}"#
    let dial = try JSONDecoder().decode(DialState.self, from: Data(json.utf8))
    #expect(Coach.stage(dial) == .band)
  }

  @Test func aLearnerIsCoachedUntilTheDeviceHasMadeThreeThrows() {
    for n in 0..<Coach.learnedAt {
      #expect(
        Coach.line(thrown: n, slow: false, stage: .rest)
          == Coach.Line(stage: .rest, lead: nil, line: Coach.lines[.rest]!))
    }
    #expect(Coach.line(thrown: Coach.learnedAt, slow: false, stage: .rest) == nil)
    #expect(Coach.line(thrown: 9, slow: false, stage: .rest) == nil)
  }

  @Test func theLinesFollowTheStrokeAndUseTheMetersOwnWords() {
    func at(_ phase: String, _ back: Double? = nil) -> String? {
      Coach.line(thrown: 0, slow: false, stage: stage(phase, back))?.line
    }
    #expect(at("idle") == "PULL BACK TO THE ORANGE MARK")
    #expect(at("winding", 60) == "NO RUSH GOING BACK")
    #expect(at("winding", 120) == "NOW FLICK FAST AND STOP ON THE BLUE MARK")
    #expect(at("swinging", 120) == "NOW FLICK FAST AND STOP ON THE BLUE MARK")
  }

  @Test func afterASlowVerdictTheNextThrowIsCoachedLedByTheVerdict() {
    #expect(
      Coach.line(thrown: 9, slow: true, stage: stage("idle", band: false))
        == Coach.Line(stage: .rest, lead: "SLOW FLICK. FLICK FASTER.", line: Coach.lines[.rest]!))
    let w = Coach.line(thrown: 9, slow: true, stage: stage("winding", 120))
    #expect(w?.lead == Coach.slowLine)
    #expect(w?.line == Coach.lines[.band])
  }

  @Test func onlyTheEnginesSlowPowerVerdictCountsAsASlowFlick() {
    #expect(Coach.slow(power: "SLOW"))
    for power in ["ON", "SHORT", "LONG", nil] { #expect(!Coach.slow(power: power)) }
  }
}
