import Foundation
import Testing

@testable import KubbRenderer

/// A card's text fields keep their focus while the keyboard is up (the owner, 2026-11-26:
/// "the keyboard would not show in either Feedback mode"). The card's rows were two copies
/// in a `ViewThatFits`, shown whole or in a scroll view: the keyboard took the room, the
/// other copy was shown, and the focused field went with its keyboard. The shell now holds
/// one copy in one scroll view (`FitHeight`), and the button row scrolls with the rows
/// where pinning it would leave them no room (a phone on its side with the keyboard up).
struct CardFieldTests {
  private var app: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../ThrowingWood").standardized
  }

  /// The rows are as tall as they are where they fit, and as tall as offered where not.
  @Test func theRowsAreTheirHeightOrTheRoom() {
    #expect(FitHeightRule.height(ideal: 300, offered: 500) == 300)
    #expect(FitHeightRule.height(ideal: 300, offered: 120) == 120)
    #expect(FitHeightRule.height(ideal: 300, offered: nil) == 300)
    #expect(FitHeightRule.height(ideal: 300, offered: .infinity) == 300)
  }

  /// The button row stays pinned while the rows keep 120 pt beside it; with the
  /// keyboard up on a phone on its side (a card about 180 pt tall) it scrolls with them.
  @Test func theButtonsScrollOnlyWhereTheRowsWouldHaveNoRoom() {
    // the 16e on its side, no keyboard: 390 less the edges and the card's padding
    let side: CGFloat = 390 - 10 - 16 - 40
    // upright on an SE with the keyboard up
    let seTyping: CGFloat = 667 - 216 - 40 - 64 - 16 - 40
    // on its side with the keyboard up
    let sideTyping: CGFloat = 181 - 10 - 16 - 40
    #expect(FitHeightRule.pinsButtons(room: side, buttons: 48))
    #expect(FitHeightRule.pinsButtons(room: seTyping, buttons: 48))
    #expect(!FitHeightRule.pinsButtons(room: sideTyping, buttons: 48))
    #expect(FitHeightRule.pinsButtons(room: .infinity, buttons: 48))
  }

  /// No card holds its rows twice: every vertical `ViewThatFits` in the app is outside
  /// the cards that hold a text field, and the shells hold one copy of their content.
  @Test func noCardHoldsATextFieldTwice() throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
    let design = try String(contentsOf: app.appending(path: "Design.swift"), encoding: .utf8)
    let shell = try #require(design.range(of: "struct CardScreen<")).lowerBound
    let shellEnd = try #require(design.range(of: "struct FitHeight: Layout")).lowerBound
    let card = String(design[shell..<shellEnd])
    #expect(!card.contains("ViewThatFits"))
    #expect(card.components(separatedBy: "rows()").count - 1 == 2)  // one for `fill`, one scrolled
    let game = try String(contentsOf: app.appending(path: "GameView.swift"), encoding: .utf8)
    let fit = try #require(game.range(of: "struct FitOrScroll")).lowerBound
    #expect(!String(game[fit...].prefix(600)).contains("ViewThatFits"))
    for name in files {
      let text = try String(contentsOf: app.appending(path: name), encoding: .utf8)
      guard text.contains("TextField(") else { continue }
      #expect(!text.contains("ViewThatFits(in: .vertical)"), "\(name)")
    }
  }
}
