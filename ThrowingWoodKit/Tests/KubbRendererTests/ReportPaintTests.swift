import Foundation
import Testing

@testable import KubbPitch
@testable import KubbRenderer

// A report's `paint` (backend/api/API.md "report", the web's src/net/paint.js and
// src/net/report.js): its shape and limits, and the pieces it is painted over.
@Suite struct ReportPaintTests {
  private func piece(_ id: String, x: Double, y: Double, pad: Int = 0) throws -> ReportPiece {
    let team = String(repeating: "a", count: pad)
    return try #require(
      ReportPiece(try JSONNode.parse(#"{"id":"\#(id)","kind":"kubb","team":"\#(team)","x":\#(x),"y":\#(y),"z":0.075,"qw":1,"qx":0,"qy":0,"qz":0}"#)))
  }

  private func report(now: String = "{}", shown: [ReportPiece], current: [ReportPiece]) -> PitchReport {
    PitchReport(
      fields: [("mode", .string("solo"))], ids: [], trail: ReportTrail(snapshot: "{}").with(now: now),
      candidates: shown, pieces: current.map(\.pose), practiceBefore: nil, surface: "grass")
  }

  @Test func paintIsRoundedClampedAndLimited() throws {
    // rounded to 2 decimals, clamped to the pitch's box, a repeated point left out
    let p = ReportPaint(
      brush: 0.123,
      strokes: [
        [CGPoint(x: 0.004, y: 4.006), CGPoint(x: 0.001, y: 4.009), CGPoint(x: -9, y: 20)], [],
        [CGPoint(x: 1.555, y: -7)],
      ])
    #expect(p.wire?.ascii == #"{"brush":0.12,"strokes":[[[0,4.01],[-6,12]],[[1.56,-4]]]}"#)
    #expect(ReportPaint(brush: 3, strokes: [[.zero]]).wire?.ascii == #"{"brush":1,"strokes":[[[0,0]]]}"#)
    #expect(ReportPaint(brush: 0.01, strokes: [[.zero]]).wire?.ascii == #"{"brush":0.05,"strokes":[[[0,0]]]}"#)
    // nothing painted is no paint
    #expect(ReportPaint(brush: 0.2).wire == nil && ReportPaint(brush: 0.2, strokes: [[], []]).wire == nil)
    // at most 32 strokes and 800 points in all, every stroke at least one point
    let many = ReportPaint(
      brush: 0.2,
      strokes: (0..<40).map { s in (0..<30).map { CGPoint(x: Double($0) * 0.1 - 2, y: Double(s) * 0.1) } })
    let wire = try JSONNode.parse(try #require(many.wire).json)
    let strokes = wire["strokes"]?.items ?? []
    #expect(strokes.count <= ReportPaint.maxStrokes)
    #expect(strokes.reduce(0) { $0 + $1.items.count } == ReportPaint.maxPoints)
    #expect(strokes.allSatisfy { !$0.items.isEmpty })
    #expect(!ReportPaint(brush: 0.2, strokes: Array(repeating: [.zero], count: 32)).hasRoom(newStroke: true))
    #expect(ReportPaint(brush: 0.2, strokes: Array(repeating: [.zero], count: 32)).hasRoom(newStroke: false))
  }

  /// With a paint, `pieces` are the pieces the picture showed (the last throw's rest),
  /// not the pitch when the card opened, and they are never dropped to fit; and no
  /// report names a piece in `selectedPieces` any more.
  @Test func aPaintedReportKeepsThePiecesItsPictureShowed() throws {
    let rest = try (0..<180).map { try piece("k\($0)", x: 0.1, y: Double($0) * 0.01, pad: 40) }
    let now = try (0..<180).map { try piece("k\($0)", x: 2.2, y: Double($0) * 0.01, pad: 40) }
    let paint = ReportPaint(brush: 0.2, strokes: [[CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.2, y: 0.6)]])

    // small: everything goes; painted, the pieces are the rest's
    let small = report(shown: rest, current: now)
    let painted = try JSONNode.parse(small.message(happened: "It stopped", should: "", paint: paint))
    #expect(painted["pieces"]?.items.first?["x"]?.double == 0.1)
    #expect(painted["paint"]?["strokes"]?.items.count == 1)
    #expect(painted["selectedPieces"] == nil && painted["dropped"] == nil)
    let plain = try JSONNode.parse(small.message(happened: "It stopped", should: ""))
    #expect(plain["pieces"]?.items.first?["x"]?.double == 2.2)
    #expect(plain["paint"] == nil)
    let feedback = try JSONNode.parse(small.feedback("Hi", paint: paint))
    #expect(feedback["paint"] != nil && feedback["pieces"]?.items.first?["x"]?.double == 0.1)
    for key in ["happened", "should", "selectedPieces"] { #expect(feedback[key] == nil) }

    // too big: unpainted, the pieces go before the snapshot after; painted, they stay
    let big = report(now: String(repeating: "x", count: 48_000), shown: rest, current: now)
    let cut = try JSONNode.parse(big.message(happened: "It stopped", should: ""))
    #expect(cut["dropped"]?.items.compactMap(\.string) == ["history", "pieces"])
    #expect(cut["pieces"]?.isNull == true && cut["snapshots"]?["now"]?.string != nil)
    let kept = try JSONNode.parse(big.message(happened: "It stopped", should: "", paint: paint))
    #expect(kept["dropped"]?.items.compactMap(\.string) == ["history", "after"])
    #expect(kept["pieces"]?.items.count == rest.count && kept["pieces"]?.items.first?["x"]?.double == 0.1)
    #expect(kept["paint"]?["brush"]?.double == 0.2)
  }
  /// The picture (the web's src/net/paint.js pictureBounds, footprint and src/ui/paint.js
  /// pictureFit): its box, a standing and a lying kubb, and the mapping both ways.
  @Test func thePictureShowsThePitchAndItsPieces() throws {
    let far = try piece("k1", x: 3.4, y: 9, pad: 0)
    #expect(ReportPicture.bounds([]) == .init(x0: -3, x1: 3, y0: -0.6, y1: 8.6))
    #expect(ReportPicture.bounds([far]) == .init(x0: -3, x1: 3.9, y0: -0.6, y1: 9.6))
    let standing = ReportPicture.footprint(far)
    #expect(!standing.lying && standing.poly.count == 4)
    let xs = standing.poly.map(\.x), ys = standing.poly.map(\.y)
    #expect(abs((xs.max()! - xs.min()!) - 0.07) < 1e-9 && abs((ys.max()! - ys.min()!) - 0.07) < 1e-9)
    // a kubb on its side (a quarter turn about x): its 15 cm length lies along y
    let s = 0.5.squareRoot()
    let lying = try #require(
      ReportPiece(try JSONNode.parse(#"{"id":"k2","kind":"kubb","x":0,"y":4,"qw":\#(s),"qx":\#(s),"qy":0,"qz":0}"#)))
    let lf = ReportPicture.footprint(lying)
    #expect(lf.lying && abs((lf.poly.map(\.y).max()! - lf.poly.map(\.y).min()!) - 0.15) < 1e-9)
    // a narrow card stands the picture up, a wide short one lays it on its side
    let up = ReportPicture.Fit(bounds: ReportPicture.bounds([]), width: 330, maxHeight: 400)
    #expect(up.upright && up.size.width <= 330 && up.size.height <= 400)
    let side = ReportPicture.Fit(bounds: ReportPicture.bounds([]), width: 700, maxHeight: 190)
    #expect(!side.upright && side.size.height <= 190)
    for f in [up, side] {
      let m = CGPoint(x: 1.25, y: 6.5)
      let back = f.metres(f.point(m))
      #expect(abs(back.x - m.x) < 1e-9 && abs(back.y - m.y) < 1e-9)
      #expect(ReportPaint.brushRange.contains(f.brush))
    }
    // upright, the far baseline is at the top
    #expect(up.point(CGPoint(x: 0, y: 8)).y < up.point(CGPoint(x: 0, y: 0)).y)
  }
}

extension ReportTrail {
  fileprivate func with(now: String) -> ReportTrail {
    var t = self
    t.now = now
    return t
  }
}
