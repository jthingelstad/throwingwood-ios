import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// Computer players on a pitch (engine 0.17, kubb-engine docs/PITCH.md "Computer seats";
/// the owner, 2026-11-22: "Or we want to play 2 v 2 where Tyler and I each have a pro
/// computer player as a partner."). Every rule is the engine's `pitch.*`: the app only
/// calls its reducers and plays what the session says.
@Suite @MainActor struct ComputerSeatTests {
  /// A start on the host's clock with its offset, so every action carries a stamp.
  static let stampedStart = JSONText(
    #"{"year":2026,"month":11,"day":22,"hour":12,"min":0,"utcOffset":-360}"#)

  private func lobby(_ p: PitchController) throws -> JSONNode {
    try p.pitchCall("lobbyOf", [("doc", .raw(p.pitch.document))])
  }
  private func team(_ p: PitchController, _ side: String) throws -> [String] {
    try lobby(p)["teams"]?[side]?.items.compactMap(\.string) ?? []
  }

  @Test func theHostAddsLevelsMovesAndRemovesAComputer() async throws {
    let fake = FakePitch()
    let host = try await player(fake, "Member_H1")
    let guest = try await player(fake, "Member_G1")
    defer {
      host.close()
      guest.close()
    }
    try await host.joinTeam("A")
    try await guest.joinTeam("B")
    try await eventually { host.pitch.version == 2 }

    // added last in the team's order at Club, with a generated player name nobody has
    let first = try #require(try await host.addComputer(side: "A"))
    #expect(host.isSeat(first) && !host.isSeat("Member_H1"))
    #expect(try team(host, "A") == ["Member_H1", first])
    let comps = PitchController.computers(of: try lobby(host))
    #expect(comps[first]?.level == "club")
    let name = try #require(comps[first]?.name)
    #expect(host.names.valid(.player, name).ok)
    #expect(host.seatName(first) == name)
    let second = try #require(try await host.addComputer(side: "A", level: "pro"))
    let secondName = PitchController.computers(of: try lobby(host))[second]?.name
    #expect(second != first && secondName != name)
    #expect(try team(host, "A") == ["Member_H1", first, second])
    // everyone sees the seats
    try await eventually { (try? self.team(guest, "A")) == ["Member_H1", first, second] }
    #expect(guest.seatName(second) == host.seatName(second))

    // its level
    #expect(try await host.setComputerLevel(first, "pro"))
    #expect(PitchController.computers(of: try lobby(host))[first]?.level == "pro")
    #expect(try await host.setComputerLevel(first, "pro") == false)  // unchanged: nothing
    #expect(try await host.setComputerLevel(first, "kid") == false)  // Kid is the match's
    // up and down the order, and across
    #expect(try await host.moveComputer(second, side: "A", index: 0))
    #expect(try team(host, "A") == [second, "Member_H1", first])
    #expect(try await host.moveComputer(second, side: "B", index: nil))
    #expect(try team(host, "A") == ["Member_H1", first])
    #expect(try team(host, "B") == ["Member_G1", second])
    // removed: off its team and out of `computers`
    #expect(try await host.removeComputer(second))
    #expect(try team(host, "B") == ["Member_G1"])
    #expect(PitchController.computers(of: try lobby(host))[second] == nil)

    // the host's alone
    #expect(try await guest.addComputer(side: "B") == nil)
    await #expect(throws: PitchError.self) { try await guest.removeComputer(first) }
    #expect(try team(host, "A") == ["Member_H1", first])
  }

  /// Six a team, people and seats together: the engine refuses a seventh.
  @Test func aTeamHoldsSixPeopleAndComputersTogether() async throws {
    let fake = FakePitch()
    let host = try await player(fake, "Member_H1")
    defer { host.close() }
    try await host.joinTeam("A")
    for _ in 0..<5 { #expect(try await host.addComputer(side: "A") != nil) }
    #expect(try team(host, "A").count == 6)
    #expect(try await host.addComputer(side: "A") == nil)
    // the engine's names: six seats, six names, none alike
    let names = PitchController.computers(of: try lobby(host)).values.compactMap(\.name)
    #expect(Set(names).count == 5)
  }

  /// START refused for the lineup itself: computers only (no person plays) gets the
  /// engine's own sentence, and the pitch stays a lobby, never an engine mismatch.
  @Test func aPitchOfComputersOnlyIsRefusedInTheEnginesWords() async throws {
    let fake = FakePitch()
    let host = try await player(fake, "Member_H1")
    defer { host.close() }
    #expect(try await host.addComputer(side: "A") != nil)
    #expect(try await host.addComputer(side: "B") != nil)
    #expect(try await host.start(seed: 3, at: Self.stampedStart) == false)
    let text = try #require(host.startRefusal)
    #expect(!text.isEmpty)
    #expect(host.state == .lobby && fake.match == nil)
  }

  /// The owner's 2 v 2: a person and a pro computer partner on each side, the host
  /// running both computers (`controlFor`'s cpu), played several turns with both
  /// controllers in step, hash for hash, every action stamped on the start's clock.
  @Test func twoVersusTwoWithAComputerPartnerEachSidePlaysInStep() async throws {
    let fake = FakePitch()
    let host = try await player(fake, "Member_H1")
    let guest = try await player(fake, "Member_G1")
    defer {
      host.close()
      guest.close()
    }
    try await host.joinTeam("A")
    try await guest.joinTeam("B")
    try await eventually { host.pitch.version == 2 }
    let partnerA = try #require(try await host.addComputer(side: "A", level: "pro"))
    let partnerB = try #require(try await host.addComputer(side: "B", level: "pro"))
    try await eventually { (try? self.team(guest, "B")) == ["Member_G1", partnerB] }
    // the engine's choice of engine sees no seat as a player without one
    #expect(try host.roomEngine()["engine"]?.string == Engine.newest)
    // the engine gap behind `withoutSeats`: engine 0.18.0's own engineFor, given the
    // document as it is, counts each seat as a player carrying no engine (when this
    // fails, the engine has fixed it and withoutSeats can go)
    let raw = try host.newestCall(
      "engineFor",
      [("doc", .raw(host.pitch.document)), ("members", host.pitch.membersJSON), ("host", .string("Member_H1"))])
    #expect(raw["engine"]?.isNull == true || raw["engine"] == nil)

    #expect(try await host.start(seed: 1717, at: Self.stampedStart))
    try await eventually { guest.state == .match }
    #expect(try hash(host) == hash(guest))
    let players = try #require(host.match?["players"])
    #expect(players["A"]?.items.map { $0["id"]?.string } == ["Member_H1", partnerA])
    #expect(players["B"]?.items.last?["cpu"]?.bool == true && players["B"]?.items.last?["level"]?.string == "pro")
    // the host runs the computers; the guest never does
    #expect(try JSONNode.parse(host.control)["cpu"]?.bool == true)
    #expect(try JSONNode.parse(guest.control)["cpu"]?.bool == false)

    let clock = MatchClock.Start(try JSONNode.parse(Self.stampedStart.text))
    let now = Date(timeIntervalSince1970: 1_795_370_400 + 9 * 60)  // 12:09 on the start's clock
    let at = MatchClock.stamp(on: clock, now: now)
    #expect(at != nil)
    var made = 0, cpuThrows = 0, personThrows = 0
    var throwers: Set<String> = []
    for _ in 0..<400 where made < 60 {
      let n = try JSONNode.parse(host.need)
      if n["kind"]?.string == "over" { break }
      if (try JSONNode.parse(host.need)["turn"]?.int ?? 0) > 4 { break }
      if n["cpu"]?.bool == true {
        // a computer player's throw: the host's engine makes it in its frames
        #expect(!host.mayAct && !guest.mayAct)
        throwers.insert(n["setup"]?["thrower"]?["key"]?.string ?? "")
        #expect(n["setup"]?["thrower"]?["cpu"]?.bool == true)
        var released = false
        for _ in 0..<2000 {
          let input = MatchClock.adding(at, to: #"{"dt":0.05}"#)
          if let out = try await host.frame(JSONText(input)), try JSONNode.parse(out)["action"] != nil {
            released = true
            break
          }
        }
        try #require(released)
        cpuThrows += 1
      } else {
        let actor = host.mayAct ? host : guest.mayAct ? guest : nil
        let me = try #require(actor)
        let action: JSONText
        switch n["kind"]?.string {
        case "throw":
          action = try #require(try scriptedThrow(me))
          personThrows += 1
          throwers.insert(n["setup"]?["thrower"]?["key"]?.string ?? "")
        case "raise": action = JSONText(#"{"type":"raise"}"#)
        case "punish":
          let c = n["cursor"]
          action = JSONText(#"{"type":"punish","x":\#(c?["x"]?.double ?? 0),"y":\#(c?["y"]?.double ?? 4)}"#)
        default:
          Issue.record("unexpected need \(n.raw.text.prefix(80))")
          return
        }
        #expect(try await me.take(JSONText(MatchClock.adding(at, to: action.text))))
      }
      made += 1
      try await eventually {
        host.sequence == made && guest.sequence == made && host.outstanding.isEmpty && guest.outstanding.isEmpty
      }
      #expect(try hash(host) == hash(guest), "action \(made)")
    }
    #expect(made >= 20 && cpuThrows >= 4 && personThrows >= 4)
    // all four throw: both people and both partners
    #expect(throwers.isSuperset(of: ["Member_H1", "Member_G1", partnerA, partnerB]))
    #expect(host.corrections + guest.corrections == 0)
    // every computer throw went from the host, every action carries the stamp
    let acts = try #require(fake.match?.acts)
    #expect(acts.count == made)
    for a in acts {
      let node = try JSONNode.parse(a.a)
      #expect(node["at"]?["min"]?.int == 9, "\(node["type"]?.string ?? "")")
    }
  }
}
