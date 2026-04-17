import Foundation
import Histogram

// Instrumentation helpers for fairness/tail-latency benches.
// References:
//   - WebKit unfairness detection (per-thread acquisition counts, Gini-like):
//     https://webkit.org/blog/6161/locking-in-webkit/
//   - Go starvation mode trigger (waiter blocked >1ms):
//     https://github.com/golang/go/blob/master/src/sync/mutex.go
//   - HDR histogram:
//     https://github.com/HdrHistogram/hdrhistogram-swift

public func makeLatencyHistogram() -> Histogram<UInt64> {
    // 1 ns lowest, 10 s highest, 3 sigfigs — tail-latency standard.
    Histogram<UInt64>(
        lowestDiscernibleValue: 1,
        highestTrackableValue: 10_000_000_000,
        numberOfSignificantValueDigits: .three
    )
}

public func mergeHistograms(_ hists: [Histogram<UInt64>]) -> Histogram<UInt64> {
    var merged = makeLatencyHistogram()
    for h in hists {
        var it = h.recordedValues().makeIterator()
        while let v = it.next() {
            _ = merged.record(v.value, count: v.count)
        }
    }
    return merged
}

/// Gini coefficient of per-task acquire counts.
/// 0 = perfect equality, approaching 1 = total starvation.
/// Formula: (2 * Σ i*xᵢ - (n+1)*Σxᵢ) / (n * Σxᵢ), xᵢ sorted ascending.
public func gini(_ counts: [UInt64]) -> Double {
    guard counts.count > 1 else { return 0 }
    let sorted = counts.sorted()
    let n = sorted.count
    var sum: Double = 0
    var weighted: Double = 0
    for (i, c) in sorted.enumerated() {
        let x = Double(c)
        sum += x
        weighted += x * Double(i + 1)
    }
    if sum == 0 { return 0 }
    return (2.0 * weighted) / (Double(n) * sum) - Double(n + 1) / Double(n)
}

public func printLatencySummary(_ label: String, _ h: Histogram<UInt64>) {
    let line = "  [\(label)] n=\(h.totalCount) p50=\(h.valueAtPercentile(50))ns p90=\(h.valueAtPercentile(90))ns p99=\(h.valueAtPercentile(99))ns p999=\(h.valueAtPercentile(99.9))ns max=\(h.max)ns\n"
    FileHandle.standardError.write(Data(line.utf8))
}

public func printFairnessSummary(_ label: String, counts: [UInt64]) {
    guard !counts.isEmpty else { return }
    let sorted = counts.sorted()
    let g = gini(counts)
    let minC = sorted.first!
    let maxC = sorted.last!
    let total = sorted.reduce(UInt64(0), +)
    let mean = Double(total) / Double(sorted.count)
    let line = "  [\(label)] tasks=\(counts.count) total=\(total) min=\(minC) max=\(maxC) mean=\(String(format: "%.0f", mean)) gini=\(String(format: "%.3f", g))\n"
    FileHandle.standardError.write(Data(line.utf8))
}

/// Synchronized-start barrier for Swift Tasks.
///
/// abseil: https://github.com/abseil/abseil-cpp/blob/master/absl/synchronization/mutex_benchmark.cc
/// uses `absl::Notification` so all threads enter the contended section simultaneously.
/// Here: compute a shared deadline a bit in the future; every task `Task.sleep(until:)` to it.
/// Scheduler wakes all near the same instant (tens of µs jitter).
public struct SyncedStart: Sendable {
    public let deadline: ContinuousClock.Instant
    public init(lead: Duration = .milliseconds(20)) {
        deadline = ContinuousClock.now.advanced(by: lead)
    }
    @inlinable
    public func waitForStart() async {
        try? await Task.sleep(until: deadline, clock: ContinuousClock())
    }
}
