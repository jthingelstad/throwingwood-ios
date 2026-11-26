import Foundation
import Testing

@testable import KubbPitch

// HOLLER's lists are the web's docs/MULTIPLAYER.md "What the iPhone app mirrors" (its
// src/net/hollers.json), in that order, exactly.
@Suite struct HollerTests {
  @Test func theListsAreTheWebsInItsOrder() {
    #expect(Holler.groups.map(\.name) == ["Cheers", "Groans", "Banter", "Calls"])
    #expect(Holler.groups.map(\.id) == ["cheers", "groans", "banter", "calls"])
    #expect(
      Holler.groups.map(\.phrases) == [
        ["NICE!", "NICE STICK!", "HOLY COW!", "LIGHTS OUT!", "YOU CAN DO IT!", "NEXT ONE!"],
        ["OOH!", "UNLUCKY", "OH NO!", "TICKLED IT!", "KNOCKERHEAD!", "SO CLOSE!"],
        ["SHORT PORCH!", "WOOD ON WOOD!", "CHERRY PICKED!", "NO PRESSURE", "WATCH THIS", "TOO EASY"],
        ["TOK!", "DOUBLE!", "WOODPILE!", "IN THE BASKET!", "EIGHT METER!", "KING SHOT!"],
      ])
    #expect(Holler.emoji == ["🎯", "🔥", "🎉", "😮", "😬", "😅", "😭", "😏", "😂", "👀", "👑", "🪵"])
    // each emoji one scalar, no variation selector, and each has a spoken name
    #expect(Holler.emoji.map { $0.unicodeScalars.map(\.value) } == [
      [0x1F3AF], [0x1F525], [0x1F389], [0x1F62E], [0x1F62C], [0x1F605],
      [0x1F62D], [0x1F60F], [0x1F602], [0x1F440], [0x1F451], [0x1FAB5],
    ])
    #expect(Set(Holler.emojiNames.keys) == Set(Holler.emoji))
    // the 1.0.0 shouts are all still on it, so the App Store build and this one agree
    #expect(["NICE!", "OOH!", "TOK!", "UNLUCKY"].allSatisfy(Holler.phrases.contains))
  }

  @Test func theCastIsAPhraseOrAnEmojiNeverBoth() {
    #expect(Holler.Piece.phrase("TOK!").payload.ascii == #"{"t":"shout","w":"TOK!"}"#)
    // the wire is ASCII JSON: the emoji goes as its surrogate pair
    let e = Holler.Piece.emoji("🪵").payload.ascii
    #expect(e == #"{"t":"shout","e":"\#u{5C}ud83e\#u{5C}udeb5"}"#)
  }

  /// A receiver reads only a listed `w`, else a listed `e` (the web's hollerOf).
  @Test func aReceiverReadsOnlyTheList() throws {
    func read(_ s: String) throws -> Holler.Piece? { Holler.read(try JSONNode.parse(s)) }
    for w in Holler.phrases {
      #expect(try read(Holler.Piece.phrase(w).payload.ascii) == .phrase(w))
    }
    for e in Holler.emoji {
      #expect(try read(Holler.Piece.emoji(e).payload.ascii) == .emoji(e))
    }
    for dropped in [
      #"{"t":"shout","w":"HELLO"}"#, #"{"t":"shout","w":"nice!"}"#, #"{"t":"shout","w":"NICE! "}"#,
      #"{"t":"shout","w":"🔥"}"#, #"{"t":"shout","e":"NICE!"}"#, #"{"t":"shout","e":"🐐"}"#,
      #"{"t":"shout","e":"🔥\#u{5C}ufe0f"}"#, #"{"t":"shout","w":1}"#, #"{"t":"shout"}"#,
      #"{"t":"aim","w":"NICE!"}"#, #"["shout"]"#,
    ] {
      #expect(try read(dropped) == nil, "\(dropped)")
    }
  }
}
