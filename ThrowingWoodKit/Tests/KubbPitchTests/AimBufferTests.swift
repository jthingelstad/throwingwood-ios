import Foundation
import Testing

@testable import KubbPitch

/// The watcher's aim, the web's src/net/aim.js rules and its tests/net/aim.test.mjs
/// cases: the clock offset, drawing 100 ms behind between samples, the arm's short way
/// round, never across a new throw or sender, and an action held for its aim.
@Suite struct AimBufferTests {
  func aim(_ seq: Int, _ x: Double, _ extra: String = "") -> JSONNode {
    try! JSONNode.parse(#"{"seq":\#(seq),"x":\#(x),"y":0,"arm":0,"phase":"back""# + extra + "}")
  }
  func field(_ text: JSONText?, _ key: String = "x") -> Double? {
    text.flatMap { try? JSONNode.parse($0) }?[key]?.double
  }

  @Test func theTuneIsTheWebs() {
    #expect(AimBuffer().delay == 100)
    #expect(AimBuffer.offsetSamples == 40 && AimBuffer.keep == 48)
    #expect(AimBuffer.holdMax == 250 && AimBuffer.stale == 1500)
    #expect(AimBuffer.linear == ["x", "y", "tx", "ty", "release", "tilt", "spin", "back", "mix"])
  }

  @Test func straightLinesTheArmTheShortWayAndTheRestFromTheEarlier() throws {
    let a = aim(1, 0, #","back":0,"stanceSet":false,"arm":350"#)
    let b = aim(1, 10, #","back":1,"phase":"flick","stanceSet":true,"arm":10"#)
    let m = try JSONNode.parse(AimBuffer.blend(a, b, 0.5))
    #expect(m["x"]?.double == 5 && m["back"]?.double == 0.5)
    #expect(m["arm"]?.double == 0)  // 350 to 10 through 0, not through 180
    #expect(m["phase"]?.string == "back" && m["stanceSet"]?.bool == false)
    #expect(AimBuffer.blend(a, b, 0) == a.raw && AimBuffer.blend(a, b, 1) == b.raw)
    // half a turn or more is a jump, not a swing: the earlier
    let far = try JSONNode.parse(AimBuffer.blend(aim(1, 0, #","arm":0"#), aim(1, 0, #","arm":180"#), 0.5))
    #expect(far["arm"]?.double == 0)
    // tilt and spin go in a straight line too
    let t = try JSONNode.parse(AimBuffer.blend(aim(1, 0, #","tilt":0,"spin":-1"#), aim(1, 0, #","tilt":2,"spin":1"#), 0.25))
    #expect(t["tilt"]?.double == 0.5 && t["spin"]?.double == -0.5)
  }

  @Test func theWatcherDrawsOneHundredMillisecondsBehindTheNewestBetweenSamples() throws {
    var b = AimBuffer()
    #expect(b.sample(now: 0) == nil)
    // the device's clock is 5000 ms ahead of the pitch's; the network takes 30 to 60 ms
    let skew = 5000
    let arrive = [30, 60, 35, 50, 45, 30]
    for (i, gap) in arrive.enumerated() {
      let ts = 1000 + i * 66
      b.add(aim(1, Double(i * 10)), from: "Member_A1", ts: ts, k: i + 1, now: ts + skew + gap)
    }
    #expect(b.offset == skew + 30)  // the smallest gap
    let now = 1000 + 2 * 66 + 33 + skew + 30 + b.delay  // half way, sample 2 to 3
    #expect(abs(field(b.sample(now: now))! - 25) < 1e-9)
    // before the first sample: the first; past the last: the last, held
    #expect(field(b.sample(now: 0)) == 0)
    #expect(field(b.sample(now: 1_000_000_000_000)) == 50)
  }

  @Test func theOffsetIsTheSmallestGapOverTheLastFortySamples() {
    var b = AimBuffer()
    b.add(aim(1, 0), from: "Member_A1", ts: 0, k: 1, now: 10)
    for i in 1...40 { b.add(aim(1, 0), from: "Member_A1", ts: i * 66, k: i + 1, now: i * 66 + 50) }
    #expect(b.offset == 50)  // the 10 ms gap has left the window
  }

  @Test func neverDrawnBetweenTwoThrowsOrTwoSenders() {
    var b = AimBuffer(delay: 0)
    b.add(aim(1, 0), from: "Member_A1", ts: 1000, k: 1, now: 1000)
    b.add(aim(2, 100), from: "Member_A1", ts: 1100, k: 2, now: 1100)
    #expect(field(b.sample(now: 1050)) == 0)  // the earlier throw's, held
    b.add(aim(2, 500), from: "Member_B1", ts: 1200, k: 1, now: 1200)
    #expect(field(b.sample(now: 1150)) == 100)
    // a late sample from the same sender is dropped
    b.add(aim(2, 9), from: "Member_B1", ts: 1150, k: 1, now: 1250)
    #expect(b.samples.count == 3)
    // a cast that is not an aim object is not kept; reset forgets the samples
    b.add(try! JSONNode.parse("[1]"), from: "Member_B1", ts: 1300, k: 2, now: 1300)
    #expect(b.samples.count == 3)
    for i in 0..<60 { b.add(aim(3, Double(i)), from: "Member_B1", ts: 2000 + i, k: 10 + i, now: 2000 + i) }
    #expect(b.samples.count == AimBuffer.keep)
    b.reset()
    #expect(b.isEmpty && b.sample(now: 9_999) == nil)
  }

  @Test func anActionWaitsForTheAimBeforeItAtMost250Milliseconds() {
    var b = AimBuffer()
    #expect(b.holdFor(ts: 1000, now: 1000) == 0)  // no aim: no wait
    b.add(aim(1, 0), from: "Member_A1", ts: 1000, k: 1, now: 1040)
    // the action was relayed 10 ms after the last aim and arrives 40 ms later
    let wait = b.holdFor(ts: 1010, now: 1050)
    #expect(wait == 1010 + 40 + b.delay - 1050)
    #expect(wait > 0 && wait <= AimBuffer.holdMax)
    #expect(b.holdFor(ts: 1010, now: 2000) == 0)  // already drawn
    #expect(b.holdFor(ts: 11_000, now: 11_040) == 0)  // a stale aim is not waited for
    #expect(b.holdFor(ts: nil, now: 1050) == 0)
    var slow = AimBuffer(delay: 1000)
    slow.add(aim(1, 0), from: "Member_A1", ts: 1000, k: 1, now: 1000)
    #expect(slow.holdFor(ts: 1000, now: 1000) == AimBuffer.holdMax)
  }
}
