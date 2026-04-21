import Benchmark
import Foundation
import Histogram
import MutexBench

// LongRun caps differ: the per-task inner loop also reads MUTEX_BENCH_MAX_SECS
// so smoke runs truncate the 60-second probe to whatever value is set.
let innerLongRunSecs = BenchEnv.maxSecs(default: 60)

// Long-duration starvation probe. 60-second wall-clock run at high contention
// with a long critical section — the shape that triggers Go-style starvation
// mode (waiter blocked > 1 ms).
//
//   https://github.com/golang/go/blob/master/src/sync/mutex.go  (starvation mode)
//   https://victoriametrics.com/blog/go-sync-mutex/
//
// Reports per-task acquire-count Gini (WebKit's unfairness metric) plus the
// merged HDR histogram of per-acquire latency:
//   https://webkit.org/blog/6161/locking-in-webkit/ (unfairness detection)

struct LongRunConfig: Sendable {
    let tasks: Int
    let work: Int
    let durationSeconds: Int
    var label: String { "tasks=\(tasks) work=\(work) dur=\(durationSeconds)s" }
}

let longRunConfigs: [LongRunConfig] = [
    .init(tasks: 64, work: 1024, durationSeconds: innerLongRunSecs),
    .init(tasks: 16, work: 1024, durationSeconds: innerLongRunSecs),
]

@inline(__always)
func longRunWorkload(
    tasks: Int,
    durationSeconds: Int,
    work: Int,
    acquire: @Sendable @escaping (Int, () -> Void) -> Void
) async -> (histograms: [Histogram<UInt64>], counts: [UInt64]) {
    let deadline = ContinuousClock.now.advanced(by: .seconds(durationSeconds))
    return await withTaskGroup(of: (Histogram<UInt64>, UInt64).self) { group in
        let gate = SyncedStart()
        for _ in 0..<tasks {
            group.addTask {
                await gate.waitForStart()
                var h = makeLatencyHistogram()
                var count: UInt64 = 0
                while ContinuousClock.now < deadline {
                    // Wait time = [t0: before acquire] → [t1: lock granted, before body].
                    // Capture t1 inside the onAcquired callback so body hold time
                    // doesn't leak into wait-latency histogram.
                    var t1: UInt64 = 0
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    acquire(work) {
                        t1 = DispatchTime.now().uptimeNanoseconds
                    }
                    _ = h.record(t1 &- t0)
                    count &+= 1
                }
                return (h, count)
            }
        }
        var hists: [Histogram<UInt64>] = []
        var counts: [UInt64] = []
        for await (h, c) in group {
            hists.append(h)
            counts.append(c)
        }
        return (hists, counts)
    }
}

let benchmarks: @Sendable () -> Void = {
    // Entire target gated — 60s × 2 configs × 7 variants = ~14 min, and results
    // typically converge within fractions of a percent on lower-core machines.
    guard BenchEnv.slow else { return }

    BenchEnv.applyDefaultConfig(
        warmupIterations: 0,
        maxDurationSecs: BenchEnv.maxSecs(default: 90),
        maxIterations: 1
    )

    var variants = StandardVariants.defaultsWithRust()
    #if os(Linux)
    // LongRun had pthread_adaptive_np unconditional in original.
    if !variants.contains(where: { $0.name == "pthread_adaptive_np" }) {
        variants.append(.pthreadAdaptive())
    }
    #endif

    for cfg in longRunConfigs {
        for v in variants {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                let (hists, counts) = await longRunWorkload(
                    tasks: cfg.tasks, durationSeconds: cfg.durationSeconds, work: cfg.work
                ) { w, onAcq in
                    h.runLocked(hook: onAcq) { $0.update(iterations: w) }
                }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) \(v.name) acquire-latency", merged)
                printFairnessSummary("\(cfg.label) \(v.name) per-task-acquires", counts: counts)
            }
        }
    }
}
