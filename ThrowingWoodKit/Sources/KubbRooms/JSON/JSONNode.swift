// Reading JSON without losing its text: every value keeps the exact span it came in, so
// a document, a rider or an engine result can be looked into and its parts passed on
// as they were (`raw`), never encoded again.

/// A parse failure: the byte offset and what was expected.
public struct JSONParseError: Error, CustomStringConvertible, Equatable {
  public let offset: Int
  public let what: String
  public var description: String { "json: \(what) at \(offset)" }
}

final class JSONBytes: Sendable {
  let bytes: [UInt8]
  init(_ bytes: [UInt8]) { self.bytes = bytes }
}

/// One value of a parsed JSON text.
public struct JSONNode: Sendable {
  public enum Kind: Sendable, Equatable { case object, array, string, number, bool, null }

  let source: JSONBytes
  let range: Range<Int>
  public let kind: Kind
  let children: [JSONNode]
  let keys: [String]

  /// Parse one JSON value (whitespace around it allowed, nothing else).
  public static func parse(_ text: String) throws -> JSONNode {
    try parse(Array(text.utf8))
  }

  public static func parse(_ text: JSONText) throws -> JSONNode { try parse(text.text) }

  static func parse(_ bytes: [UInt8]) throws -> JSONNode {
    var p = Parser(source: JSONBytes(bytes))
    p.skip()
    let node = try p.value(depth: 0)
    p.skip()
    if p.i != bytes.count { throw JSONParseError(offset: p.i, what: "trailing text") }
    return node
  }

  /// The value's text exactly as it came.
  public var raw: JSONText { JSONText(String(decoding: source.bytes[range], as: UTF8.self)) }

  public var isNull: Bool { kind == .null }

  /// An object's member, the last one when a key repeats (as JSON.parse keeps).
  public subscript(key: String) -> JSONNode? {
    guard kind == .object else { return nil }
    for i in keys.indices.reversed() where keys[i].utf16.elementsEqual(key.utf16) {
      return children[i]
    }
    return nil
  }

  /// An array's items, or an object's values.
  public var items: [JSONNode] { kind == .array ? children : [] }

  /// An object's members in order.
  public var members: [(key: String, value: JSONNode)] {
    kind == .object ? Array(zip(keys, children)).map { (key: $0.0, value: $0.1) } : []
  }

  /// A string's value. A lone surrogate escape becomes U+FFFD, as it does when a
  /// browser hands a string to the engine (TextEncoder) and Swift's String holds one.
  public var string: String? {
    guard kind == .string else { return nil }
    return Self.unescape(source.bytes, range.lowerBound + 1, range.upperBound - 1)
  }

  public var bool: Bool? {
    guard kind == .bool else { return nil }
    return source.bytes[range.lowerBound] == UInt8(ascii: "t")
  }

  public var double: Double? {
    guard kind == .number else { return nil }
    return Double(String(decoding: source.bytes[range], as: UTF8.self))
  }

  /// A number that is a whole number (`3` or `3.0`, as JavaScript sees both).
  public var int: Int? {
    guard let d = double, d.rounded() == d, abs(d) < 9.0e15 else { return nil }
    return Int(d)
  }

  // MARK: -

  static func unescape(_ b: [UInt8], _ from: Int, _ to: Int) -> String {
    var units: [UInt16] = []
    var plain = true
    var i = from
    while i < to {
      if b[i] == 0x5c {
        plain = false
        break
      }
      i += 1
    }
    if plain { return String(decoding: b[from..<to], as: UTF8.self) }
    // Decode to UTF-16 units, then to a String: a lone surrogate turns into U+FFFD.
    var bytes: [UInt8] = []
    func flushBytes() {
      if !bytes.isEmpty {
        units.append(contentsOf: String(decoding: bytes, as: UTF8.self).utf16)
        bytes.removeAll(keepingCapacity: true)
      }
    }
    i = from
    while i < to {
      let c = b[i]
      if c != 0x5c {
        bytes.append(c)
        i += 1
        continue
      }
      flushBytes()
      let e = b[i + 1]
      switch e {
      case UInt8(ascii: "u"):
        let h = String(decoding: b[(i + 2)..<(i + 6)], as: UTF8.self)
        units.append(UInt16(h, radix: 16) ?? 0xfffd)
        i += 6
      default:
        let m: UInt16 =
          switch e {
          case UInt8(ascii: "b"): 0x08
          case UInt8(ascii: "f"): 0x0c
          case UInt8(ascii: "n"): 0x0a
          case UInt8(ascii: "r"): 0x0d
          case UInt8(ascii: "t"): 0x09
          default: UInt16(e)  // " \ /
          }
        units.append(m)
        i += 2
      }
    }
    flushBytes()
    return String(decoding: units, as: UTF16.self)
  }
}

private struct Parser {
  let source: JSONBytes
  var i = 0
  var b: [UInt8] { source.bytes }

  init(source: JSONBytes) { self.source = source }

  mutating func skip() {
    while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d { i += 1 }
  }

  func fail(_ what: String) -> JSONParseError { JSONParseError(offset: i, what: what) }

  mutating func value(depth: Int) throws -> JSONNode {
    guard depth < 512 else { throw fail("too deep") }
    guard i < b.count else { throw fail("unexpected end") }
    let start = i
    switch b[i] {
    case UInt8(ascii: "{"):
      i += 1
      var keys: [String] = []
      var children: [JSONNode] = []
      skip()
      if i < b.count, b[i] == UInt8(ascii: "}") {
        i += 1
        return node(.object, start, children, keys)
      }
      while true {
        skip()
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
        let k = try string()
        keys.append(k.string!)
        skip()
        guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected :") }
        i += 1
        skip()
        children.append(try value(depth: depth + 1))
        skip()
        guard i < b.count else { throw fail("unexpected end") }
        if b[i] == UInt8(ascii: "}") {
          i += 1
          return node(.object, start, children, keys)
        }
        guard b[i] == UInt8(ascii: ",") else { throw fail("expected , or }") }
        i += 1
      }
    case UInt8(ascii: "["):
      i += 1
      var children: [JSONNode] = []
      skip()
      if i < b.count, b[i] == UInt8(ascii: "]") {
        i += 1
        return node(.array, start, children, [])
      }
      while true {
        skip()
        children.append(try value(depth: depth + 1))
        skip()
        guard i < b.count else { throw fail("unexpected end") }
        if b[i] == UInt8(ascii: "]") {
          i += 1
          return node(.array, start, children, [])
        }
        guard b[i] == UInt8(ascii: ",") else { throw fail("expected , or ]") }
        i += 1
      }
    case UInt8(ascii: "\""):
      return try string()
    case UInt8(ascii: "t"): return try word("true", .bool, start)
    case UInt8(ascii: "f"): return try word("false", .bool, start)
    case UInt8(ascii: "n"): return try word("null", .null, start)
    default:
      return try number(start)
    }
  }

  func node(_ kind: JSONNode.Kind, _ start: Int, _ children: [JSONNode], _ keys: [String])
    -> JSONNode
  {
    JSONNode(source: source, range: start..<i, kind: kind, children: children, keys: keys)
  }

  mutating func word(_ w: String, _ kind: JSONNode.Kind, _ start: Int) throws -> JSONNode {
    let u = Array(w.utf8)
    guard i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u else {
      throw fail("unexpected character")
    }
    i += u.count
    return node(kind, start, [], [])
  }

  mutating func string() throws -> JSONNode {
    let start = i
    i += 1
    while true {
      guard i < b.count else { throw fail("unterminated string") }
      let c = b[i]
      if c == UInt8(ascii: "\"") {
        i += 1
        return node(.string, start, [], [])
      }
      if c < 0x20 { throw fail("a control character in a string") }
      if c == 0x5c {
        guard i + 1 < b.count else { throw fail("unterminated string") }
        let e = b[i + 1]
        if e == UInt8(ascii: "u") {
          guard i + 6 <= b.count,
            b[(i + 2)..<(i + 6)].allSatisfy({ isHex($0) })
          else { throw fail("bad \\u escape") }
          i += 6
        } else if Array("\"\\/bfnrt".utf8).contains(e) {
          i += 2
        } else {
          throw fail("bad escape")
        }
      } else {
        i += 1
      }
    }
  }

  func isHex(_ c: UInt8) -> Bool {
    (0x30...0x39).contains(c) || (0x61...0x66).contains(c) || (0x41...0x46).contains(c)
  }

  func isDigit(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) }

  mutating func number(_ start: Int) throws -> JSONNode {
    if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
    guard i < b.count, isDigit(b[i]) else { throw fail("unexpected character") }
    if b[i] == UInt8(ascii: "0") {
      i += 1
    } else {
      while i < b.count, isDigit(b[i]) { i += 1 }
    }
    if i < b.count, b[i] == UInt8(ascii: ".") {
      i += 1
      guard i < b.count, isDigit(b[i]) else { throw fail("bad number") }
      while i < b.count, isDigit(b[i]) { i += 1 }
    }
    if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
      i += 1
      if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
      guard i < b.count, isDigit(b[i]) else { throw fail("bad number") }
      while i < b.count, isDigit(b[i]) { i += 1 }
    }
    return node(.number, start, [], [])
  }
}
