import CoreText
import Foundation
import KubbEngine
import KubbPitch
import Testing

@testable import KubbRenderer

/// Every name the engine can make (`names.all`: 4,133 player and 6,530 team names on
/// 0.13.3) fits every place the app draws one, measured in the app's own fonts (the
/// engine's docs/SESSION.md "Names", "Layout": the longest in characters is not the
/// widest). The web measures its own (its tests/game/names-fit-client.test.mjs).
///
/// The widths are the iPhone 16e's (375 pt wide, the smallest review phone), at the
/// default text size, on the 1.0 design's cards: a card is the screen less 16 a side and
/// 20 inside, 303 pt, and the name row is the name and SHUFFLE on one line. A name too
/// wide for its room shrinks (never truncates) down to its view's least scale; at the
/// largest text sizes SHUFFLE goes under the name and the name wraps between words.
@MainActor struct NameFitTests {
  /// A card's room on a 16e: 375 less 16 a side and 20 inside.
  static let card: CGFloat = 303
  /// SHUFFLE (Londrina Solid at 20, 14 and 4 in a side, its 3 pt shadow) and the gap to it.
  static func shuffle(_ t: NameFitTests) -> CGFloat { t.width("SHUFFLE", Self.display, 20) + 2 * 18 + 3 + 10 }
  /// The name row's least scale (NameRowView) and the header's (the rail).
  static let rowScale: CGFloat = 0.6
  static let headerScale: CGFloat = 0.6
  /// The header's name beside its two numbers (about 88 pt) and MENU (about 66), its
  /// plate's insets and gaps (38): upright on a 16e (375 less 12 a side) and on its side
  /// (WideLayout.railSize, 300).
  static let headerUpright: CGFloat = 351 - 88 - 66 - 38
  static let headerWide: CGFloat = 300 - 88 - 66 - 38
  /// A word in Settings' stepper, less its two 44 pt arrows, lines and padding: the two
  /// steppers side by side where both words fit in half the card, else one under the
  /// other across the whole card (NameSteppers), so every word fits whole in that.
  static let word: CGFloat = 303 - 2 * 44 - 4 * 3 - 8
  /// The handoff card's name (Londrina Solid at 44, wrapping between words): the card's
  /// content on a 16e, 375 less 22 padding and 20 inset a side.
  static let handoffWord: CGFloat = 291

  static let display: CTFont = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../ThrowingWood/Fonts/LondrinaSolid-Black.ttf").standardized
    let d = (CTFontManagerCreateFontDescriptorsFromData(try! Data(contentsOf: url) as CFData) as! [CTFontDescriptor])[0]
    return CTFontCreateWithFontDescriptor(d, 1, nil)
  }()

  func width(_ text: String, _ font: CTFont, _ size: CGFloat) -> CGFloat {
    let f = CTFontCreateCopyWithAttributes(font, size, nil, nil)
    let s = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: f])
    return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil)
  }
  /// The system face at a weight (SF, as SwiftUI's .headline and .body draw).
  func system(_ weight: CGFloat) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, 17, nil)!
    let traits = [kCTFontWeightTrait: weight] as CFDictionary
    let d = CTFontDescriptorCreateCopyWithAttributes(
      CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
    return CTFontCreateWithFontDescriptor(d, 17, nil)
  }

  @Test func everyNameFitsEveryPlaceItIsDrawn() throws {
    let names = Names(engine: try Engine(appVersion: "test"))
    let players = try names.all(.player), teams = try names.all(.team)
    #expect(players.count > 4000 && teams.count > 6000)
    let bold = system(0.4)
    func widest(_ list: [String], _ font: CTFont, _ size: CGFloat) -> (String, CGFloat) {
      list.map { ($0, width($0, font, size)) }.max { $0.1 < $1.1 }!
    }
    let all = players + teams
    let words = Set(all.flatMap { $0.split(separator: " ").map(String.init) })
    let row = Self.card - Self.shuffle(self)
    // the name rows: Settings at 30, the solo card at 26, the share card and the lobby's
    // You row at 24 (players), a side's team name at 22
    for (list, size) in [(players, CGFloat(30)), (players, 26), (players, 24), (teams, 22)] {
      let w = widest(list, Self.display, size)
      print("widest at \(size): \(w), room \(row), scale \(row / w.1)")
      #expect(w.1 * Self.rowScale <= row, "\(w) at \(size)")
    }
    // Settings' stepper words (Inter bold 15, measured here in the system's bold, about
    // as wide), whole across the card
    let word = widest(Array(words), bold, 15)
    #expect(word.1 <= Self.word, "\(word)")
    let handoff = widest(Array(words), Self.display, 44)
    #expect(handoff.1 <= Self.handoffWord, "\(handoff)")
    let upright = widest(all, Self.display, 24), wide = widest(all, Self.display, 22)
    print("header: upright \(upright) in \(Self.headerUpright), wide \(wide) in \(Self.headerWide)")
    #expect(upright.1 * Self.headerScale <= Self.headerUpright, "\(upright)")
    #expect(wide.1 * Self.headerScale <= Self.headerWide, "\(wide)")
  }
}

extension NameFitTests {
  /// A scene tile's name (SceneTiles: Londrina Solid at 16, capitals, two lines where it
  /// needs them) fits a third of a 16e's card whole word by word: (303 less two 8 pt gaps)
  /// over three, less its 1 pt sides. Inter at 14, the web's, would not hold TOURNAMENT.
  @Test func everySceneNameFitsItsTile() {
    let room = (Self.card - 16) / 3 - 2
    for e in SceneID.catalogue {
      for word in e.name.uppercased().split(separator: " ") {
        #expect(width(String(word), Self.display, 16) <= room, "\(word): \(width(String(word), Self.display, 16)) > \(room)")
      }
    }
  }
}
