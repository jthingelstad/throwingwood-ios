import Foundation
import KubbEngine
import Testing

@testable import KubbPitch
@testable import KubbRenderer

// The lobby's computer seats and a match with computer players (engine 0.17) on the
// in-process pitch server (Pitch/FakePitch.swift), the web's words (its lobby.js and
// docs/SYSTEM.md "Computer seats").

@MainActor private final class SeatID: MemberIDStore {
  var id: String?
  init(_ id: String) { self.id = id }
  func load() -> String? { id }
  func save(_ id: String) { self.id = id }
}

@MainActor private func soon(_ test: () -> Bool) async throws {
  for _ in 0..<3000 {
    if test() { return }
    try await Task.sleep(for: .milliseconds(2))
  }
  throw PitchError("test-timeout")
}

private func quick() -> PitchClient.Timing {
  var t = PitchClient.Timing()
  t.firstRetry = .milliseconds(2)
  t.retry = .milliseconds(2)
  t.retryMax = .milliseconds(5)
  t.answer = .seconds(600)
  t.ping = .seconds(600)
  return t
}

@MainActor private func controller(_ fake: FakePitch, _ id: String) async throws -> PitchController {
  let p = try PitchController(
    pitch: PitchClient(
      url: URL(string: "ws://127.0.0.1:1")!, pitch: fake.code, appVersion: "0.0-test",
      store: SeatID(id), timing: quick(), factory: fake.factory),
    engines: EngineShelf(appVersion: "0.0-test"))
  p.connect()
  try await p.pitch.ready()
  return p
}

@MainActor private func phone(_ fake: FakePitch, _ id: String, create: Bool) throws -> OnlinePitch {
  try OnlinePitch(
    url: URL(string: "ws://127.0.0.1:1")!, link: try #require(PitchLink(fake.code)), create: create,
    name: "Brave Birch", appVersion: "0.0-test", store: SeatID(id), timing: quick(),
    defaults: UserDefaults(suiteName: "seats-\(UUID().uuidString)")!, factory: fake.factory)
}

@Suite @MainActor struct ComputerSeatLobbyTests {
  @Test func theWordsAreTheWebs() {
    #expect(SeatWords.line("Bold Birch", "pro") == "Bold Birch · computer · Pro")
    #expect(SeatWords.spoken("Bold Birch", "pro", place: 2, of: 3, side: "A") == "Bold Birch, computer, Pro, 2 of 3 in Team A")
    #expect(SeatWords.says("Bold Birch", .add(side: "A", level: "club")) == "Bold Birch joins Team A at Club.")
    #expect(SeatWords.says("Bold Birch", .level("pro")) == "Bold Birch now plays at Pro.")
    #expect(SeatWords.says("Bold Birch", .up) == "Bold Birch moves up.")
    #expect(SeatWords.says("Bold Birch", .down) == "Bold Birch moves down.")
    #expect(SeatWords.says("Bold Birch", .across("B")) == "Bold Birch moves to Team B.")
    #expect(SeatWords.says("Bold Birch", .remove) == "Bold Birch is off the team.")
    #expect(SeatWords.addLabel("A") == "Add a computer player to Team A")
    #expect(SeatWords.levelLabel("Bold Birch") == "Bold Birch's level")
    #expect(SeatWords.upLabel("Bold Birch") == "Move Bold Birch up")
    #expect(SeatWords.downLabel("Bold Birch") == "Move Bold Birch down")
    #expect(SeatWords.acrossLabel("Bold Birch", to: "B") == "Move Bold Birch to Team B")
    #expect(SeatWords.removeLabel("Bold Birch") == "Remove Bold Birch")
    #expect(SeatWords.kidNote == "Kid match: every computer plays as Kid.")
    #expect(SeatWords.computerRow(emptySide: true, anySeat: true) == .empty)
    #expect(SeatWords.computerRow(emptySide: false, anySeat: true) == .kid)
    #expect(SeatWords.computerRow(emptySide: false, anySeat: false) == nil)
    #expect(SeatWords.label(.empty) == "An empty side plays as" && SeatWords.label(.kid) == "Kid match")
    #expect(SeatWords.count(3, of: 6) == "3 of 6")
    // the match
    #expect(SeatWords.headerTail(cpu: true, level: "pro") == " · computer · pro")
    #expect(SeatWords.headerTail(cpu: nil, level: "pro") == nil)
    #expect(
      SeatWords.handoffFirst(thrower: "Bold Birch", cpu: true, level: "pro") == "Bold Birch throws first · computer · Pro")
    #expect(SeatWords.handoffFirst(thrower: "Bold Birch", cpu: nil, level: nil) == nil)
  }

  /// The host's lobby on this phone: ADD COMPUTER, a seat's level, up and down, across
  /// and REMOVE, each said once to VoiceOver; the Computer row's forms follow the seats.
  @Test func theHostsLobbyAddsLevelsMovesAndRemovesSeats() async throws {
    let fake = FakePitch()
    let online = try phone(fake, "Host_Member", create: true)
    defer { online.close() }
    online.connect()
    try await soon { online.stage == .lobby && online.isHost }
    try await online.team("A")
    try await soon { online.players("A").count == 1 }
    #expect(online.computerRow == .empty)  // B has nobody and no seat

    try await online.addComputer("A")
    let seat = try #require(online.players("A").last?.seat)
    #expect(seat.level == "club" && seat.place == 2 && seat.of == 2 && !seat.first && seat.last)
    #expect(online.seatNews?.text == "\(seat.name) joins Team A at Club.")
    #expect(online.controller.names.valid(.player, seat.name).ok && seat.name != "Brave Birch")
    try await online.seatLevel(seat.id, "pro")
    #expect(online.players("A").last?.seat?.level == "pro")
    #expect(online.seatNews?.text == "\(seat.name) now plays at Pro.")
    try await online.moveSeat(seat, .up)
    #expect(online.players("A").first?.seat?.id == seat.id)
    #expect(online.seatNews?.text == "\(seat.name) moves up.")
    try await online.moveSeat(try #require(online.players("A").first?.seat), .down)
    #expect(online.players("A").last?.seat?.id == seat.id)
    try await online.moveSeat(try #require(online.players("A").last?.seat), .across("B"))
    #expect(online.players("B").map(\.id) == [seat.id] && online.players("A").count == 1)
    #expect(online.seatNews?.text == "\(seat.name) moves to Team B.")
    // no empty side, a seat on the pitch: the Kid match switch
    #expect(online.computerRow == .kid)
    try await online.option("computer", SeatWords.kidValue(on: true))
    try await soon { online.kidPitch }
    #expect(online.players("B").first?.seat?.shownLevel == "kid")
    #expect(online.players("B").first?.seat?.level == "pro")  // its own, for when Kid goes
    #expect(online.players("B").first?.seat?.spoken == "\(seat.name), computer, Kid, 1 of 1 in Team B")
    try await online.option("computer", SeatWords.kidValue(on: false))
    try await soon { !online.kidPitch }
    #expect(online.options["computer"] == "club" && online.players("B").first?.seat?.shownLevel == "pro")
    try await online.removeSeat(try #require(online.players("B").first?.seat))
    #expect(online.players("B").isEmpty && !online.anySeat)
    #expect(online.seatNews?.text == "\(seat.name) is off the team.")
    #expect(online.computerRow == .empty)
  }

  /// An iPhone joining a pitch whose document already holds computer seats (a web host's
  /// lobby, made through the same engine reducers): it shows each seat in its place with
  /// its name and level, starts on the host's START, and shows the computer player whose
  /// throw it is.
  @Test func anIPhoneJoiningAPitchWithComputerSeatsShowsAndPlaysIt() async throws {
    let fake = FakePitch()
    let host = try await controller(fake, "Host_Member")
    defer { host.close() }
    try await host.joinTeam("A")
    let pro = try #require(try await host.addComputer(side: "A", level: "pro"))
    let clubs = [
      try #require(try await host.addComputer(side: "B")), try #require(try await host.addComputer(side: "B")),
    ]
    #expect(try JSONNode.parse(fake.doc)["computers"]?.kind == .object)

    let online = try phone(fake, "Phone_Member", create: false)
    defer { online.close() }
    online.connect()
    try await soon { online.stage == .lobby && online.players("B").count == 2 }
    #expect(!online.isHost)
    #expect(online.players("A").map(\.id) == ["Host_Member", pro])
    #expect(online.players("B").map(\.id) == clubs)
    let shown = try #require(online.players("A").last?.seat)
    #expect(shown.name == host.seatName(pro) && shown.name != Names.computer)
    #expect(SeatWords.line(shown.name, shown.shownLevel) == "\(shown.name) · computer · Pro")
    #expect(online.players("B").compactMap(\.seat).map(\.level) == ["club", "club"])
    #expect(online.computerRow == .kid)
    // the phone takes the third place on B, after the two computers
    try await online.team("B")
    try await soon { online.players("B").count == 3 }
    #expect(online.players("B").last?.member?.you == true)

    let start = JSONText(#"{"year":2026,"month":11,"day":22,"hour":12,"min":0,"utcOffset":-360}"#)
    try await soon { host.pitch.members.count == 2 }
    #expect(try await host.start(seed: 4242, at: start))
    try await soon { online.stage == .match && online.controller.state == .match }
    // the host's actions until a computer player's throw; the phone follows each
    var sawComputer = false
    for _ in 0..<12 {
      let n = try JSONNode.parse(host.need)
      if n["cpu"]?.bool == true {
        let th = n["setup"]?["thrower"]
        #expect(th?["cpu"]?.bool == true)
        try await soon { online.controller.sequence == host.sequence }
        let name = try #require(th?["name"]?.string)
        #expect(online.controller.actorDescription == "\(name) throws")
        #expect(online.controller.mayAct == false)
        let need = try JSONDecoder().decode(MatchNeed.self, from: Data(online.controller.need.text.utf8))
        let level: String? = th?["level"]?.string
        let tail = " · computer · " + SeatWords.level(level).lowercased()
        let line = HeaderWords.line(turn: 1, n: 1, of: 6, projectile: "baton", watching: false, thrower: need.setup?.thrower)
        #expect(line.hasSuffix(tail))
        sawComputer = true
        var released = false
        for _ in 0..<2000 {
          if let out = try await host.frame(JSONText(#"{"dt":0.05}"#)), try JSONNode.parse(out)["action"] != nil {
            released = true
            break
          }
        }
        try #require(released)
      } else if host.mayAct, n["kind"]?.string == "throw" {
        let seq = try #require(n["throws"]?.int)
        #expect(
          try await host.take(
            JSONText(
              #"{"type":"throw","seq":\#(seq),"how":"baton","launch":{"speed":5,"loft":20,"swivel":0,"legal":true},"stance":{"x":0,"y":0},"target":{"x":0,"y":8},"scripted":true}"#
            )))
      } else {
        break
      }
      try await soon { host.outstanding.isEmpty && online.controller.sequence == host.sequence }
      #expect(try online.controller.engine.hash() == host.engine.hash())
    }
    #expect(sawComputer)
  }
}
