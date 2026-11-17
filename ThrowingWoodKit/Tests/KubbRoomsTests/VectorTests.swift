import Foundation
import Testing

@testable import KubbRooms

struct VectorTests {
  let vectors: JSONNode
  init() throws {
    let url = Bundle.module.url(forResource: "Fixtures/vectors", withExtension: "json")!
    vectors = try JSONNode.parse(String(contentsOf: url, encoding: .utf8))
  }
  func value(_ node: JSONNode) -> JS {
    switch node["type"]!.string! {
    case "null": return .null
    case "bool": return .bool(node["value"]!.bool!)
    case "number":
      return .number(Double(bitPattern: UInt64(node["bits"]!.string!.dropFirst(2), radix: 16)!))
    case "string": return .utf16(node["units"]!.items.map { UInt16($0.int!) })
    case "array": return .array(node["items"]!.items.map(value))
    default:
      return .object(
        node["members"]!.items.map { pair in
          (
            String(decoding: pair.items[0].items.map { UInt16($0.int!) }, as: UTF16.self),
            value(pair.items[1])
          )
        })
    }
  }
  @Test func asciiAndNumbers() throws {
    for v in vectors["ascii"]!.items {
      let text = value(v["value"]!).ascii
      #expect(text == v["text"]!.string)
      #expect(text.utf8.count == v["length"]!.int)
    }
    for v in vectors["numberText"]!.items + vectors["specialNumbers"]!.items {
      let d = Double(bitPattern: UInt64(v["bits"]!.string!.dropFirst(2), radix: 16)!)
      #expect(ASCIIJSON.number(d) == v["text"]!.string, "bits: \(v["bits"]!.string!)")
    }
    for v in vectors["asciify"]!.items {
      #expect(ASCIIJSON.asciify(v["raw"]!.string!) == v["text"]!.string)
    }
  }
  @Test func objectKeysFollowJavaScriptOrderAndCodeUnits() throws {
    let decomposed = "e" + String(UnicodeScalar(0x301)!)
    let value = JS.object([
      ("b", .int(1)), ("10", .int(10)), ("2", .int(2)),
      ("b", .int(3)), ("é", .int(4)), (decomposed, .int(5)),
    ])
    #expect(value.ascii.hasPrefix(#"{"2":2,"10":10,"b":3,"#))
    let node = try JSONNode.parse(value.ascii)
    #expect(node.members.count == 5)
    #expect(node["é"]?.int == 4)
    #expect(node[decomposed]?.int == 5)
  }

  @Test func readingKeepsRawText() throws {
    for v in vectors["readStrings"]!.items {
      let node = try JSONNode.parse(v["text"]!.string!)
      #expect(node.raw.text == v["text"]!.string)
      #expect(node.string!.utf8.map { String(format: "%02x", $0) }.joined() == v["utf8"]!.string)
    }
    let raw = #"{"snap":"{\"x\":3.0,\"y\":1e-7}","action":{"launch":{"speed":3.0}},"future":null}"#
    let node = try JSONNode.parse(raw)
    #expect(node["snap"]?.string == #"{"x":3.0,"y":1e-7}"#)
    #expect(node["action"]?.raw.text == #"{"launch":{"speed":3.0}}"#)
    #expect(JS.raw(node.raw).ascii == raw)
    for text in ["[", "{", "01", "[1,]", "{\"a\":}", "1e", "-", "true false", "\"\\uXXYY\""] {
      #expect(throws: JSONParseError.self) { try JSONNode.parse(text) }
    }
  }
  @Test func framesAndJoin() throws {
    for v in vectors["frames"]!.items {
      let frames = Frames.split(
        v["text"]!.string!, frame: v["frame"]!.int!, id: v["id"]?.string ?? "x")
      #expect(frames == v["frames"]!.items.map { $0.string! })
      #expect(frames.allSatisfy { $0.utf8.count <= v["frame"]!.int! })
    }
    var reader = Frames.Reassembler()
    for v in vectors["join"]!.items {
      let messages = v["frames"]!.items.compactMap { reader.accept($0.string!) }.compactMap {
        try? JSONNode.parse($0)
      }
      let expected = v["messages"]!.items.map { try! JSONNode.parse($0.string!) }
      #expect(
        messages.map { ASCIIJSON.asciify($0.raw.text) }
          == expected.map { ASCIIJSON.asciify($0.raw.text) }, "\(v["name"]!.string!)")
    }
  }
}
