// Frames and chunking (the web's docs/ROOMS.md section 2.1, `toFrames` and the part
// reader in src/net/room.js): API Gateway takes at most 32 KB a frame, so a message
// longer than `limits.frame` (30 000) characters is sent as parts
//
//   ~<id>.<i>.<n>~<slice i of the message text>
//
// each slice `frame - 40` characters (room for the header), joined by the receiver in
// `i` order once all `n` have come, in whatever order they came. Messages are ASCII
// JSON, so a character is a byte and a slice can end anywhere.

public enum Frames {
  /// What a part's header leaves of a frame for its slice (room.js FRAME_HEAD).
  public static let head = 40
  /// The frame limit before the room says its own (`limits.frame` in `joined`).
  public static let defaultFrame = 30_000
  /// Room codes' alphabet, also the part ids': no 0, 1, i, l or o.
  public static let codeAlphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

  /// The frames that carry `text`: itself when it fits, else its parts.
  public static func split(_ text: String, frame: Int = defaultFrame, id: String = randomID())
    -> [String]
  {
    precondition(frame > head, "A frame must leave room for a part header")
    let units = Array(text.utf16)
    if units.count <= frame { return [text] }
    let size = frame - head
    let n = (units.count + size - 1) / size
    return (0..<n).map { i in
      let slice = units[(i * size)..<min(units.count, (i + 1) * size)]
      return "~\(id).\(i).\(n)~" + String(decoding: slice, as: UTF16.self)
    }
  }

  /// 8 characters of the code alphabet, as room.js makes a part id.
  public static func randomID() -> String {
    var g = SystemRandomNumberGenerator()
    return String((0..<8).map { _ in codeAlphabet[Int(g.next() % UInt64(codeAlphabet.count))] })
  }

  /// A part's header: `~id.i.n~` (1 to 16 of a-z, 0-9; 1 to 3 digits each), and the
  /// slice after it. Nil for anything else, which room.js ignores.
  public static func part(_ frame: String) -> (id: String, i: Int, n: Int, slice: Substring)? {
    var s = Substring(frame)
    guard s.first == "~" else { return nil }
    s = s.dropFirst()
    func take(_ ok: (Character) -> Bool, _ lo: Int, _ hi: Int) -> Substring? {
      let t = s.prefix(while: ok)
      guard t.count >= lo, t.count <= hi else { return nil }
      s = s.dropFirst(t.count)
      return t
    }
    let idChar: (Character) -> Bool = { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    let digit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
    // The id may be followed by "." only after 1 to 16 characters.
    guard let id = take(idChar, 1, 16), s.first == "." else { return nil }
    s = s.dropFirst()
    guard let i = take(digit, 1, 3), s.first == "." else { return nil }
    s = s.dropFirst()
    guard let n = take(digit, 1, 3), s.first == "~" else { return nil }
    s = s.dropFirst()
    return (String(id), Int(i)!, Int(n)!, s)
  }

  /// Puts parts back together, one connection's worth (room.js keeps them until the
  /// socket closes).
  public struct Reassembler: Sendable {
    private var parts: [String: [Int: Substring]] = [:]
    public init() {}

    /// A whole message (the frame itself, or the last part's message), or nil while
    /// parts are missing or the frame is not one (room.js drops those).
    public mutating func accept(_ frame: String) -> String? {
      guard frame.hasPrefix("~") else { return frame }
      guard let p = Frames.part(frame), p.n >= 2, p.n <= 16, p.i < p.n, frame.utf8.count <= 30_000
      else { return nil }
      if parts[p.id] == nil, parts.count >= 32 { parts.removeAll() }
      var got = parts[p.id] ?? [:]
      got[p.i] = p.slice
      guard got.values.reduce(0, { $0 + $1.utf8.count }) <= 300 * 1024 else {
        parts[p.id] = nil
        return nil
      }
      if got.count < p.n {
        parts[p.id] = got
        return nil
      }
      parts[p.id] = nil
      return (0..<p.n).map { String(got[$0] ?? "") }.joined()
    }

    public mutating func reset() { parts.removeAll() }
    public var pending: Int { parts.count }
  }
}
