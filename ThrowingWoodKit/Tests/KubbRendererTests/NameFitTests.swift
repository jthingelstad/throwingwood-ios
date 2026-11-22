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
/// default text size; at larger sizes the name row's words go under each other and the
/// name wraps between words (NameRowView), and the rail shrinks its line to fit.
@MainActor struct NameFitTests {
  /// The name row's own room on a 16e: the Settings card is 375 less its padding (20 a
  /// side) and the plate's inset (20 a side), 295 pt; SHUFFLE takes about 95 of it.
  static let rowText: CGFloat = 200
  /// A word in its menu picker, beside its KEEP (the web's NAME_FIT.word).
  static let word: CGFloat = 150
  /// The handoff card's name (Londrina Solid at 44, wrapping between words): the card's
  /// content on a 16e, 375 less 22 padding and 20 inset a side.
  static let handoffWord: CGFloat = 291
  /// The rail's name (Londrina Solid at 27, one line): the rail beside its counts on a
  /// 16e, upright.
  static let rail: CGFloat = 215

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
    let headline = system(0.4), body = system(0)  // semibold, regular
    func widest(_ list: [String], _ font: CTFont, _ size: CGFloat) -> (String, CGFloat) {
      list.map { ($0, width($0, font, size)) }.max { $0.1 < $1.1 }!
    }
    let all = players + teams
    let words = Set(all.flatMap { $0.split(separator: " ").map(String.init) })
    let row = widest(all, headline, 17)
    let word = widest(Array(words), body, 17)
    let handoff = widest(Array(words), Self.display, 44)
    let rail = widest(players + teams, Self.display, 27)
    print("widest: row \(row), word \(word), handoff word \(handoff), rail \(rail)")
    #expect(row.1 <= Self.rowText, "\(row)")
    #expect(word.1 <= Self.word, "\(word)")
    #expect(handoff.1 <= Self.handoffWord, "\(handoff)")
    #expect(rail.1 <= Self.rail, "\(rail)")
  }
}
