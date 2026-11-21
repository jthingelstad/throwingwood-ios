// JSON as the room's wire carries it (the web's docs/ROOMS.md section 2): the text
// JavaScript's `JSON.stringify` writes, with every UTF-16 code unit above "~" written
// as a backslash-u escape (`asciiJson` in the web's src/net/room.js and
// backend/rooms/core.mjs). The text is then pure ASCII, so its length in characters is
// its size in bytes and a message can be cut anywhere.
//
// Swift's JSONEncoder does neither (it writes UTF-8, escapes "/", orders keys its own
// way and formats numbers its own way), so this is written out here, and checked against
// the web's own functions by the vectors in Tests/KubbPitchTests/Fixtures/vectors.json.

/// Text that is one JSON value, kept exactly as it came: what the engine wrote, or what
/// the room sent. Passed through, never decoded and encoded again, so a snapshot's
/// `3.0` stays `3.0` and its hash holds.
public struct JSONText: Sendable, Hashable, CustomStringConvertible {
  public let text: String
  public init(_ text: String) { self.text = text }
  public var description: String { text }
  public static let null = JSONText("null")
}

/// A JSON value as a JavaScript client would build it, to be written as ASCII JSON.
/// Objects keep their keys in the order given (JSON.stringify's insertion order).
public indirect enum JS: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  /// A JavaScript number: written as `Number.prototype.toString` writes it.
  case number(Double)
  case string(String)
  /// A JavaScript string as its UTF-16 code units, lone surrogates and all (a name
  /// the web's 16-unit cut split). Swift's String cannot hold one.
  case utf16([UInt16])
  case array([JS])
  case object([(String, JS)])
  /// JSON text written as it is (made ASCII: see `ASCIIJSON.asciify`).
  case raw(JSONText)

  public static func == (a: JS, b: JS) -> Bool {
    ASCIIJSON.encode(a) == ASCIIJSON.encode(b)
  }

  /// This value as ASCII JSON.
  public var ascii: String { ASCIIJSON.encode(self) }
  public var json: JSONText { JSONText(ascii) }
}

public enum ASCIIJSON {
  /// `asciiJson(value)`: JSON.stringify's text, everything above "~" escaped.
  public static func encode(_ value: JS) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(64)
    write(value, to: &out)
    return String(decoding: out, as: UTF8.self)
  }

  /// JSON text made ASCII without parsing it again: every code unit above "~" (which in
  /// valid JSON can only be inside a string) becomes a backslash-u escape, a character
  /// beyond U+FFFF a surrogate pair, exactly as `asciiJson` writes it. Everything else,
  /// numbers and key order included, stays as it is.
  public static func asciify(_ text: String) -> String {
    var ascii = true
    for b in text.utf8 where b > 0x7e {
      ascii = false
      break
    }
    if ascii { return text }
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count + 64)
    for u in text.utf16 {
      if u > 0x7e { escape(u, to: &out) } else { out.append(UInt8(u)) }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// A JavaScript string's length (UTF-16 code units): what the room's size rules
  /// count. For ASCII JSON it is the size in bytes.
  public static func jsLength(_ text: String) -> Int { text.utf16.count }

  /// `JSON.stringify(string)` made ASCII: the quoted string.
  public static func quote(_ s: String) -> String {
    var out: [UInt8] = []
    writeString(s.utf16, to: &out)
    return String(decoding: out, as: UTF8.self)
  }

  /// `Number.prototype.toString()`, which JSON.stringify uses for every finite number:
  /// the shortest digits that read back as the same double, written plainly from 1e-6 up
  /// to 1e21 and with an exponent outside that. `NaN` and the infinities are `null`.
  public static func number(_ d: Double) -> String {
    guard d.isFinite else { return "null" }
    if d == 0 { return "0" }  // -0 too
    // Swift's description is also the shortest round-trip digits; take them and the
    // exponent out of it, then lay them out as ECMAScript's Number::toString does.
    var text = d.magnitude.description  // "1.5", "1e-07", "1.7976931348623157e+308"
    var exp10 = 0
    if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
      exp10 = Int(text[text.index(after: e)...]) ?? 0
      text = String(text[..<e])
    }
    var intPart = text
    var frac = ""
    if let dot = text.firstIndex(of: ".") {
      intPart = String(text[..<dot])
      frac = String(text[text.index(after: dot)...])
    }
    // digits d1...dk with value 0.d1...dk x 10^n
    var digits = intPart + frac
    var n = intPart.count + exp10
    while digits.hasPrefix("0") && digits.count > 1 {
      digits.removeFirst()
      n -= 1
    }
    while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
    let k = digits.count
    var s: String
    if k <= n && n <= 21 {
      s = digits + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
      let i = digits.index(digits.startIndex, offsetBy: n)
      s = String(digits[..<i]) + "." + String(digits[i...])
    } else if -6 < n && n <= 0 {
      s = "0." + String(repeating: "0", count: -n) + digits
    } else {
      let e = n - 1
      let first = String(digits.first!)
      let rest = digits.dropFirst()
      s = first + (rest.isEmpty ? "" : "." + rest) + "e" + (e < 0 ? "-" : "+") + String(abs(e))
    }
    return d < 0 ? "-" + s : s
  }

  // MARK: - writing

  static func write(_ value: JS, to out: inout [UInt8]) {
    switch value {
    case .null: out.append(contentsOf: "null".utf8)
    case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
    case .int(let i): out.append(contentsOf: String(i).utf8)
    case .number(let d): out.append(contentsOf: number(d).utf8)
    case .string(let s): writeString(s.utf16, to: &out)
    case .utf16(let units): writeString(units, to: &out)
    case .array(let items):
      out.append(UInt8(ascii: "["))
      for (i, item) in items.enumerated() {
        if i > 0 { out.append(UInt8(ascii: ",")) }
        write(item, to: &out)
      }
      out.append(UInt8(ascii: "]"))
    case .object(let members):
      out.append(UInt8(ascii: "{"))
      // JSON.stringify keeps a key once (a JavaScript object cannot hold two); the
      // value is the last one given, in the place of the first.
      var seen: [[UInt16]: Int] = [:]
      var kept: [(String, JS)] = []
      for (k, v) in members {
        if let at = seen[Array(k.utf16)] {
          kept[at].1 = v
        } else {
          seen[Array(k.utf16)] = kept.count
          kept.append((k, v))
        }
      }
      // ECMAScript puts array-index keys first, numerically, then other keys in
      // insertion order. String equality above uses code units, not Swift's Unicode
      // canonical equivalence (two differently encoded keys remain distinct).
      func index(_ key: String) -> UInt32? {
        guard let n = UInt32(key), n != UInt32.max, String(n) == key else { return nil }
        return n
      }
      let indexed = kept.filter { index($0.0) != nil }.sorted { index($0.0)! < index($1.0)! }
      kept = indexed + kept.filter { index($0.0) == nil }
      for (i, (k, v)) in kept.enumerated() {
        if i > 0 { out.append(UInt8(ascii: ",")) }
        writeString(k.utf16, to: &out)
        out.append(UInt8(ascii: ":"))
        write(v, to: &out)
      }
      out.append(UInt8(ascii: "}"))
    case .raw(let text): out.append(contentsOf: asciify(text.text).utf8)
    }
  }

  static func writeString<S: Sequence<UInt16>>(_ units: S, to out: inout [UInt8]) {
    out.append(UInt8(ascii: "\""))
    for u in units {
      switch u {
      case 0x22: out.append(contentsOf: [0x5c, 0x22])
      case 0x5c: out.append(contentsOf: [0x5c, 0x5c])
      case 0x08: out.append(contentsOf: [0x5c, UInt8(ascii: "b")])
      case 0x09: out.append(contentsOf: [0x5c, UInt8(ascii: "t")])
      case 0x0a: out.append(contentsOf: [0x5c, UInt8(ascii: "n")])
      case 0x0c: out.append(contentsOf: [0x5c, UInt8(ascii: "f")])
      case 0x0d: out.append(contentsOf: [0x5c, UInt8(ascii: "r")])
      // Other controls, JSON.stringify's own escapes; and everything above "~",
      // asciiJson's, lone surrogates among them (JSON.stringify escapes those itself,
      // in the same lowercase form).
      case 0..<0x20, 0x7f...: escape(u, to: &out)
      default: out.append(UInt8(u))
      }
    }
    out.append(UInt8(ascii: "\""))
  }

  private static let hex = Array("0123456789abcdef".utf8)

  static func escape(_ u: UInt16, to out: inout [UInt8]) {
    out.append(contentsOf: [0x5c, UInt8(ascii: "u")])
    out.append(hex[Int(u >> 12)])
    out.append(hex[Int((u >> 8) & 0xf)])
    out.append(hex[Int((u >> 4) & 0xf)])
    out.append(hex[Int(u & 0xf)])
  }
}
