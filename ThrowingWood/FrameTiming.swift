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
#endif
