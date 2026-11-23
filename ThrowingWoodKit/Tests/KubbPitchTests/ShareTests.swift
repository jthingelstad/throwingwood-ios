import Foundation
import KubbEngine
import Testing

@testable import KubbPitch

/// Sharing a match against the computer (the web's backend/api/API.md "share" and
/// docs/REEL.md "The share card"), against vectors the web's own code made
/// (`node tools/share-vectors.mjs --web <web checkout>`).
/// The web made the vectors on its engine; a match is renamed only on its own.
func shareVectorMinor() -> String {
  let url = Bundle.module.url(forResource: "Fixtures/share-vectors", withExtension: "json")!
  let v = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  return Engine.majorMinor(v?["webEngine"] as? String) ?? ""
}
let carriesVectors = Engine.carried.contains(shareVectorMinor())

@Suite @MainActor struct ShareTests {
  static let vectors: [String: Any] = {
    let url = Bundle.module.url(forResource: "Fixtures/share-vectors", withExtension: "json")!
    return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  }()
  var v: [String: Any] { Self.vectors }
  func vectorEngine() throws -> Engine { try Engine(minor: shareVectorMinor(), appVersion: "0.0-test") }
  var match: [String: Any] { v["match"] as! [String: Any] }

  func source(engine: String? = nil, actions: [JSONText]? = nil) throws -> ShareSource {
    let acts = try (match["actions"] as! [Any]).map {
      JSONText(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self))
    }
    return ShareSource(
      engine: engine ?? (v["webEngine"] as! String), start: match["start"] as! String,
      actions: actions ?? acts, winner: match["winner"] as! String)
  }

  func object(_ text: String) throws -> NSDictionary {
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as! NSDictionary
  }

  // ---------- words ----------

  @Test func theWordsAreTheContractsWords() {
    let w = v["words"] as! [String: Any]
    #expect(w["title"] as? String == ShareWords.title)
    #expect(w["about"] as? String == ShareWords.about)
    #expect(w["label"] as? String == ShareWords.label)
    #expect(w["placeholder"] == nil)  // no text field: the name row
    #expect(w["sides"] as? String == ShareWords.sides)
    #expect(w["when"] as? String == ShareWords.when)
    #expect(w["share"] as? String == ShareWords.share)
    #expect(w["notNow"] as? String == ShareWords.notNow)
    #expect(w["checking"] as? String == ShareWords.checking)
    #expect(w["checkingText"] as? String == ShareWords.checkingText)
    #expect(w["link"] as? String == ShareWords.link)
    #expect(w["failed"] as? String == ShareWords.failed)
    #expect(w["notThisTime"] as? String == ShareWords.notThisTime)
    #expect(w["offline"] as? String == ShareWords.offline)
    let names = w["name"] as! [String: String]
    #expect(names == ["pick": ShareWords.name(.pick)])
    #expect(ShareWords.name(.pick) == "Pick a name for your side.")
    let whys = w["why"] as! [String: String]
    for why in ShareWhy.allCases { #expect(whys[why.rawValue] == ShareWords.why(why)) }
    #expect(whys.count == ShareWhy.allCases.count)
    #expect(v["url"] as? String == ShareWords.url)
  }

  @Test func theLimitsAreTheServersLimits() {
    let l = v["limits"] as! [String: Int]
    #expect(l["bytes"] == ShareLimits.bytes)
    #expect(l["actions"] == ShareLimits.actions)
    #expect(l["startBytes"] == ShareLimits.startBytes)
    #expect(l["nameMax"] == nil)
    #expect(l["waitMs"] == 45000 && ShareLimits.wait == .seconds(45))
  }

  // ---------- the name ----------

  /// Only a generated player name or a default goes on the reel, as the web's
  /// nameProblem says (and the server's check): every case the web's vectors hold.
  @Test func theNameRulesAreTheWebs() throws {
    let names = Names(engine: try Engine(appVersion: "0.0-test"))
    for case let n as [String: Any] in v["names"] as! [Any] {
      let name = n["name"] as! String
      #expect(ShareName.problem(name, names: names)?.rawValue == n["problem"] as? String, "\(name.debugDescription)")
    }
  }

  @Test func theRowStartsFromTheMatchsGeneratedName() throws {
    let names = Names(engine: try Engine(appVersion: "0.0-test"))
    for case let f as [String: Any] in v["fromMatch"] as! [Any] {
      #expect(
        ShareName.fromMatch(start: f["start"] as! String, names: names, fallback: f["fallback"] as! String)
          == f["name"] as! String)
    }
  }

  // ---------- the reducer ----------

  func event(_ e: [String: Any]) -> ShareState.Event {
    switch e["type"] as! String {
    case "send": return .send
    case "open": return .open
    case "refuse": return .refuse(ShareWhy(code: e["why"] as? String))
    case "error": return .error(e["code"] as! String)
    default:
      let a = e["answer"] as! [String: Any]
      return .answer(ShareReply(code: a["code"] as? String, v: a["v"] as? Int, why: a["why"] as? String))
    }
  }

  @Test func theCardWalksTheWebsStates() {
    for case let walk as [String: Any] in v["walks"] as! [Any] {
      var s = ShareState()
      let events = walk["events"] as! [[String: Any]]
      let views = walk["views"] as! [[String: Any]]
      for (e, want) in zip(events, views) {
        s = s.step(event(e))
        let got = s.view
        let label = "\(events.map { $0["type"]! }) at \(e)"
        #expect(got.phase.rawValue == want["phase"] as? String, "\(label)")
        #expect(got.line == want["line"] as? String, "\(label)")
        #expect(got.text == want["text"] as? String, "\(label)")
        #expect(got.bar == want["bar"] as? Bool, "\(label)")
        #expect(got.retry == want["retry"] as? Bool, "\(label)")
        #expect(got.form == want["form"] as? Bool, "\(label)")
        #expect(got.code == want["code"] as? String, "\(label)")
      }
    }
  }

  @Test func onlyFinalWhysStayWhenTheCardOpensAgain() {
    for why in ShareWhy.allCases {
      let s = ShareState().step(.refuse(why)).step(.open)
      #expect((s.phase == .refused) == why.final)
    }
    #expect(ShareWhy(code: "something-new") == .unavailable)
    #expect(ShareWhy(code: nil) == .unavailable)
  }

  // ---------- the message ----------

  @Test(.enabled(if: carriesVectors)) func theMessageIsTheWebsWithTheIPhonesClient() throws {
    let engine = try vectorEngine()
    for case let m as [String: Any] in v["messages"] as! [Any] {
      let name = m["name"] as! String
      guard case .message(let text, let bytes) = try ShareMessage.make(
        engine: engine, source: source(), name: name)
      else {
        Issue.record("refused \(name)")
        continue
      }
      let message = try object(text.text)
      #expect(message["t"] as? String == "share" && message["id"] as? Int == 1)
      let g = message["g"] as! [String: Any]
      var web = m["g"] as! [String: Any]
      #expect(web["client"] as? String == "web")
      #expect(g["client"] as? String == "ios")
      web["client"] = "ios"
      #expect(NSDictionary(dictionary: g) == NSDictionary(dictionary: web), "\(name)")
      // "ios" and "web" are as long: the same bytes the web counted
      #expect(bytes == m["bytes"] as? Int)
      #expect(text.text.utf8.count == bytes)
      // ASCII on the wire, keys in the web's order
      #expect(text.text.utf8.allSatisfy { $0 < 128 })
      #expect(text.text.hasPrefix(#"{"t":"share","id":1,"g":{"client":"ios","engine":""#))
    }
    #expect(
      v["asciiCheck"] as? Int
        == (v["messages"] as! [[String: Any]])[1]["bytes"] as? Int)
  }

  @Test(.enabled(if: carriesVectors)) func theRenamedMatchReplaysToItsEndWithTheChecks() throws {
    let engine = try vectorEngine()
    guard case .message(let text, _) = try ShareMessage.make(
      engine: engine, source: source(), name: "Lucky Larch")
    else {
      Issue.record("refused")
      return
    }
    let g = try JSONNode.parse(text.text)["g"]!
    #expect(try JSONNode.parse(g["start"]!.string!)["opts"]?["teams"]?["A"]?["name"]?.string == "Lucky Larch")
    let load = JS.object([
      ("start", .raw(g["start"]!.raw)), ("log", .raw(g["log"]!.raw)),
      ("checkCpu", .bool(true)), ("checkThrows", .bool(true)),
    ])
    _ = try engine.call("replayLoad", json: load.ascii)
    let info = try JSONNode.parse(engine.call("replayFinish"))
    #expect(info["done"]?.bool == true)
    #expect(info["differs"]?.bool != true)
    #expect(info["forged"]?.bool != true)
    #expect(info["outOfBounds"]?.bool != true)
    #expect(info["throws"]?.int == match["throws"] as? Int)
  }

  @Test func anotherVersionsMatchIsRefusedHere() throws {
    let engine = try Engine(appVersion: "0.0-test")
    #expect(try ShareMessage.make(engine: engine, source: source(engine: "0.6.0"), name: "Brave Birch") == .refused(.engine))
    #expect(try ShareMessage.make(engine: engine, source: source(engine: "1.7.2"), name: "Brave Birch") == .refused(.engine))
  }

  @Test(.enabled(if: carriesVectors)) func aMatchPastTheLimitsIsTooLongBeforeAnythingIsSent() throws {
    let engine = try vectorEngine()
    let one = try source().actions[0]
    // more actions than the server takes
    let many = Array(repeating: one, count: ShareLimits.actions + 1)
    #expect(try ShareMessage.make(engine: engine, source: source(actions: many), name: "Brave Birch") == .refused(.tooLong))
    // fewer, but past what a kept document holds
    let big = Array(repeating: one, count: 700)
    #expect(try ShareMessage.make(engine: engine, source: source(actions: big), name: "Brave Birch") == .refused(.tooLong))
  }

  @Test func onlyAMatchAgainstTheComputerMayBeShared() throws {
    let s = try source()
    #expect(s.shareable)
    var start = try object(s.start) as! [String: Any]
    var opts = start["opts"] as! [String: Any]
    for (cpu, ok) in [("B", true), ("A", false)] as [(Any, Bool)] + [(["B"], true), (["A", "B"], false)] {
      opts["cpu"] = cpu
      start["opts"] = opts
      let text = String(decoding: try JSONSerialization.data(withJSONObject: start), as: UTF8.self)
      #expect(ShareSource(engine: s.engine, start: text, actions: s.actions, winner: "A").shareable == ok)
    }
    #expect(!ShareSource(engine: s.engine, start: s.start, actions: [], winner: "A").shareable)
  }

  // ---------- the answer ----------

  @Test func theAnswerIsReadAsTheWebReadsIt() throws {
    #expect(
      ShareReply.read(try JSONNode.parse(#"{"code":"abcdefgh23","v":1}"#))
        == ShareReply(code: "abcdefgh23", v: 1, why: nil))
    #expect(
      ShareReply.read(try JSONNode.parse(#"{"code":null,"v":0,"why":"busy"}"#))
        == ShareReply(code: nil, v: 0, why: "busy"))
    #expect(PitchAPI.errorCode(PitchError("failed")) == "failed")
    #expect(PitchAPI.errorCode(CancellationError()) == "closed")
  }

  /// One `POST share { g }`: the message's `g` byte for byte, waiting the share's time.
  @Test(.enabled(if: carriesVectors)) func oneCallWithTheMessagesMatch() async throws {
    let fake = FakeAPI(#"{"code":"abcdefgh23","v":1}"#)
    let engine = try vectorEngine()
    guard case .message(let text, _) = try ShareMessage.make(engine: engine, source: source(), name: "Lucky Larch")
    else {
      Issue.record("refused")
      return
    }
    let reply = try await fake.api.share(text)
    #expect(reply == ShareReply(code: "abcdefgh23", v: 1, why: nil))
    #expect(fake.requests.count == 1)
    let request = fake.requests[0]
    #expect(request.httpMethod == "POST" && request.url?.absoluteString == "http://127.0.0.1:8798/api/share")
    #expect(request.timeoutInterval == Double(ShareLimits.wait.components.seconds))
    let g = try JSONNode.parse(text)["g"]!
    #expect(try fake.sent().raw.text == "{\"g\":" + g.raw.text + "}")
  }

  @Test func aRefusalForTheShareIsThrownWithItsCode() async throws {
    let fake = FakeAPI(#"{"error":"failed","message":"x"}"#, status: 500)
    do {
      _ = try await fake.api.share(JSONText(#"{"t":"share","id":1,"g":{}}"#))
      Issue.record("no throw")
    } catch { #expect(PitchAPI.errorCode(error) == "failed") }
    await #expect(throws: PitchError("bad-message")) { _ = try await fake.api.share(JSONText(#"{"t":"share"}"#)) }
  }
}
