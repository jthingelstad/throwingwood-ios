import CryptoKit
import Foundation
import Testing

@testable import KubbRenderer

@MainActor struct StraightPracticeTests {
  // SHA-256 of the exact action text from v0.6.0 in wasmoon 1.16.
  @Test func referenceActions() throws {
    let reference: [(PracticeExercise, String)] = [
      (.base, "928fc82e71a0039848d72b0aa01be46f0a26670295b052ade5c5eb4ee46e90e2"),
      (.pair, "8416fc3a7d9fb6f0bbb535b9a1850e7e2d8c6c35b124d120ecc1f48fd1488b6b"),
      (.pile, "e9cd9628696d9ba741690db666b0994e0200b7dd8035d0380dc537650e8a5ed3"),
    ]
    for (exercise, hash) in reference {
      let board = try PitchSession(appVersion: "test", exercise: exercise)
      board.sample(.zero)
      board.sample(CGPoint(x: 0, y: 2.0 / 3))
      try board.tick(1.0 / 60)
      board.sample(CGPoint(x: 0, y: -0.4))
      board.sample(nil)
      try board.tick(1.0 / 60)
      let action = try #require(board.trail.actions.last)
      #expect(board.playing)
      #expect(
        SHA256.hash(data: Data(action.text.utf8)).map { String(format: "%02x", $0) }.joined()
          == hash)
    }
  }

  @Test func cancelBeforeDisplayDisarmsStroke() throws {
    let board = try PitchSession(appVersion: "test", exercise: .base)
    board.sample(.zero)
    board.sample(CGPoint(x: 0, y: 0.7))
    try board.cancelInput()
    board.sample(nil)
    try board.tick(1.0 / 60)
    #expect(!board.playing)
    #expect(board.trail.actions.isEmpty)
  }
}
