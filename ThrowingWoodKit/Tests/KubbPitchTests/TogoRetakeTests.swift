import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// The throw to go on a pitch (engine 1.4.0): a baton the pitch refused is thrown again
/// from the pitch's head, after a resume and after a full resync alike.
@Suite @MainActor struct TogoRetakeTests {
  /// A legal fixed baton to go for whoever this member throws it for.
  func baton(_ p: PitchController) throws -> JSONText? {
    let n = try JSONNode.parse(p.need)
    guard n["kind"]?.string == "togo", let round = n["round"]?.int ?? n["togo"]?["round"]?.int else { return nil }
    return JSONText(
      #"{"type":"togo","side":"A","round":\#(round),"how":"baton","launch":{"speed":5,"loft":20,"swivel":0,"legal":true},"stance":{"x":0,"y":0},"target":{"x":0,"y":8},"scripted":true}"#
    )
  }

  @Test func aRefusedBatonIsThrownAgainAfterTheWholeMatchIsTaken() async throws {
    let fake = FakePitch()
    let p = try await player(fake, "Native_Member")
    defer { p.close() }
    #expect(try await p.prepareLobby(options: [:]))
    try await p.joinTeam("A")
    #expect(try await p.start(seed: 1001, at: startAt))
    let mine = try #require(try baton(p), "the match opens on the throw to go: \(p.need.text)")
    // refused, and the resync answered with the whole match (a `state`), not a resume
    fake.refuseNext = "seq"
    #expect(try await p.take(mine))
    try await eventually { fake.match?.seq == 1 && p.outstanding.isEmpty && !p.awaitingState }
    #expect(fake.links(of: "Native_Member").last!.sent("resync").count == 1)
    #expect(try JSONNode.parse(fake.match!.acts[0].a.text)["type"]?.string == "togo")
  }
}
