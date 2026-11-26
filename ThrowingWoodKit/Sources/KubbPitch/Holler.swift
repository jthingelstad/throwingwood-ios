// HOLLER, the preset words and emoji a player sends to everyone on the pitch.
//
// The source is the web's docs/MULTIPLAYER.md, "What the iPhone app mirrors" (its
// src/net/hollers.json): these lists in that order, exactly. This is the app's one copy:
// the panel, the sender (`PitchController.shout`) and the receiver (`OnlinePitch`) all
// read it, and `HollerTests` pins it word for word. Change it there first, then here.
//
// On the wire a phrase is the cast `{ "t": "shout", "w": "<phrase>" }` and an emoji
// `{ "t": "shout", "e": "<emoji>" }` with no `w`. A receiver shows one only when it is
// exactly a member of these lists and drops anything else without a word, so no text a
// player could write ever reaches a screen (docs/DISTRIBUTION.md).

public enum Holler {
  public struct Group: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let phrases: [String]
  }

  public static let groups: [Group] = [
    Group(
      id: "cheers", name: "Cheers",
      phrases: ["NICE!", "NICE STICK!", "HOLY COW!", "LIGHTS OUT!", "YOU CAN DO IT!", "NEXT ONE!"]),
    Group(
      id: "groans", name: "Groans",
      phrases: ["OOH!", "UNLUCKY", "OH NO!", "TICKLED IT!", "KNOCKERHEAD!", "SO CLOSE!"]),
    Group(
      id: "banter", name: "Banter",
      phrases: ["SHORT PORCH!", "WOOD ON WOOD!", "CHERRY PICKED!", "NO PRESSURE", "WATCH THIS", "TOO EASY"]),
    Group(
      id: "calls", name: "Calls",
      phrases: ["TOK!", "DOUBLE!", "WOODPILE!", "IN THE BASKET!", "EIGHT METER!", "KING SHOT!"]),
  ]

  public static let emoji = ["🎯", "🔥", "🎉", "😮", "😬", "😅", "😭", "😏", "😂", "👀", "👑", "🪵"]

  /// What VoiceOver reads for each emoji (the panel's buttons and a received one).
  public static let emojiNames: [String: String] = [
    "🎯": "Bullseye", "🔥": "Fire", "🎉": "Party", "😮": "Wow", "😬": "Yikes",
    "😅": "Phew", "😭": "Crying", "😏": "Smirk", "😂": "Laughing", "👀": "Eyes",
    "👑": "Crown", "🪵": "Wood",
  ]

  public static var phrases: [String] { groups.flatMap(\.phrases) }

  /// One holler: a phrase or an emoji, always one of the lists' own.
  public enum Piece: Sendable, Hashable {
    case phrase(String)
    case emoji(String)

    public var text: String {
      switch self {
      case .phrase(let w), .emoji(let w): w
      }
    }
    public var isEmoji: Bool { if case .emoji = self { true } else { false } }

    /// The cast's payload.
    public var payload: JS {
      switch self {
      case .phrase(let w): .object([("t", .string("shout")), ("w", .string(w))])
      case .emoji(let e): .object([("t", .string("shout")), ("e", .string(e))])
      }
    }
  }

  /// A phrase, when `w` is exactly one of the lists' (unicode scalar for scalar).
  public static func listedPhrase(_ w: String) -> Piece? {
    phrases.contains { same($0, w) } ? .phrase(w) : nil
  }
  public static func listedEmoji(_ e: String) -> Piece? {
    emoji.contains { same($0, e) } ? .emoji(e) : nil
  }

  /// A received cast, read as the web's `hollerOf` (src/net/hollers.js): `t` "shout" and
  /// a `w` that is exactly one of the phrases, else an `e` that is exactly one of the
  /// emoji. Anything else is nil and is dropped silently.
  public static func read(_ d: JSONNode) -> Piece? {
    guard d.kind == .object, d["t"]?.string == "shout" else { return nil }
    if let w = d["w"]?.string, let p = listedPhrase(w) { return p }
    if let e = d["e"]?.string, let p = listedEmoji(e) { return p }
    return nil
  }

  private static func same(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
  }
}
