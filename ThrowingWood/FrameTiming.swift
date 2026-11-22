#if targetEnvironment(simulator)
  import QuartzCore
  import Foundation

  /// Opt-in simulator review only. Time actual display callbacks and UIKit draw passes.
  struct FrameTiming {
    private var intervals = [Double](), costs = [Double]()
    private var lastTick: Double?, tickMS: Double?
    mutating func tick(_ start: Double) {
      if let lastTick { intervals.append((start - lastTick) * 1000) }
      lastTick = start
      tickMS = (CACurrentMediaTime() - start) * 1000
    }
    mutating func draw(_ start: Double) {
      guard let tickMS else { return }
      costs.append(tickMS + (CACurrentMediaTime() - start) * 1000)
      self.tickMS = nil
    }
    mutating func finish() {
      guard !intervals.isEmpty, !costs.isEmpty else { return }
      func percentiles(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return [0.5, 0.95, 0.99, 1].map {
          String(format: "%.2f", sorted[Int(Double(sorted.count - 1) * $0)])
        }
        .joined(separator: "/")
      }
      let line =
        "Practice playback, \(costs.count) draws. p50/p95/p99/max ms: update+draw \(percentiles(costs)); callback spacing \(percentiles(intervals))\n"
      FileHandle.standardOutput.write(Data(line.utf8))
      self = Self()
    }
  }

  import CoreGraphics
  import KubbRenderer

  /// Opt-in simulator measure of the Tournament's live neighbours (MATCH_REVIEW
  /// neighbourstiming, --scene tournament): each frame drawn again off the screen at the
  /// screen's scale with the live field and with the fixed pitches, and the neighbours'
  /// own `advance` calls as their queue timed them. Prints a line every 600 frames.
  @MainActor struct NeighbourTiming {
    private var with = [Double](), without = [Double](), intervals = [Double]()
    private var last: Double?
    mutating func frame(board: BoardView, look: String, reduced: Bool) {
      let now = CACurrentMediaTime()
      if let last { intervals.append((now - last) * 1000) }
      last = now
      guard board.timingNeighbours.live, board.bounds.width > 0 else { return }
      let scale = board.contentScaleFactor
      let w = Int(board.bounds.width * scale), h = Int(board.bounds.height * scale)
      guard
        let ctx = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      ctx.translateBy(x: 0, y: Double(h))
      ctx.scaleBy(x: scale, y: -scale)
      for live in [true, false] {
        let t0 = CACurrentMediaTime()
        board.drawForTiming(ctx, look: look, reduced: reduced, live: live)
        let ms = (CACurrentMediaTime() - t0) * 1000
        if live { with.append(ms) } else { without.append(ms) }
      }
      if with.count >= 600 {
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }
        func p(_ v: [Double], _ q: Double) -> Double { let s = v.sorted(); return s[Int(Double(s.count - 1) * q)] }
        let c = board.timingNeighbours.cost
        let extra = zip(with, without).map { $0 - $1 }
        let line = String(
          format:
            "Neighbours, %d frames at %d Hz (spacing p50 %.1f ms): draw with %.2f ms mean (p95 %.2f), fixed %.2f, extra %.2f mean (p95 %.2f); advance %d calls mean %.3f ms p99 %.3f max %.3f, skipped %d\n",
          with.count, board.timingRate, p(intervals, 0.5), mean(with), p(with, 0.95), mean(without), mean(extra),
          p(extra, 0.95), c.calls, c.mean, c.percentile(0.99), c.worst, board.timingNeighbours.skipped)
        FileHandle.standardOutput.write(Data(line.utf8))
        with = []
        without = []
        intervals = []
      }
    }
  }
#endif
