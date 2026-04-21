import Benchmark
import Foundation
import Histogram
import MutexBench

// LongRun caps differ: the per-task inner loop also reads MUTEX_BENCH_MAX_SECS
// so smoke runs truncate the 60-second probe to whatever value is set.
let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 90
let innerLongRunSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 60

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
//
// This is the bench where you see barging-induced tail latency or starvation
// that throughput metrics hide.

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
                    // Wait time = [t0: before acquire attempt] → [t1: lock granted, before body].
                    // Capture t1 inside the onAcquired callback so the body's hold time
                    // doesn't leak into the wait-latency histogram. Record after the acquire
                    // closure returns so h.record doesn't run under the lock.
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

let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"
let runExperiment = ProcessInfo.processInfo.environment["MUTEX_BENCH_EXPERIMENT"] == "1"

let benchmarks: @Sendable () -> Void = {
    // Entire target gated — 60s × 2 configs × 7 variants = ~14 min, and results
    // typically converge within fractions of a percent on lower-core machines.
    // Set MUTEX_BENCH_SLOW=1 to include.
    guard runSlow else { return }

    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: 0,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: 1
    )

    for cfg in longRunConfigs {
        Benchmark("\(cfg.label) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in box.m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) Synchronization.Mutex acquire-latency", merged)
            printFairnessSummary("\(cfg.label) Synchronization.Mutex per-task-acquires", counts: counts)
        }

        Benchmark("\(cfg.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in box.box.withLockedValue { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) NIOLockedValueBox acquire-latency", merged)
            printFairnessSummary("\(cfg.label) NIOLockedValueBox per-task-acquires", counts: counts)
        }

        #if os(Linux)
        if runCopy {
            Benchmark("\(cfg.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                let (hists, counts) = await longRunWorkload(
                    tasks: cfg.tasks,
                    durationSeconds: cfg.durationSeconds,
                    work: cfg.work
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) Synchronization.Mutex (copy) acquire-latency", merged)
                printFairnessSummary("\(cfg.label) Synchronization.Mutex (copy) per-task-acquires", counts: counts)
            }
        }

        Benchmark("\(cfg.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) PlainFutexMutex (spin=100) acquire-latency", merged)
            printFairnessSummary("\(cfg.label) PlainFutexMutex (spin=100) per-task-acquires", counts: counts)
        }

        Benchmark("\(cfg.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) plain spin=14 backoff acquire-latency", merged)
            printFairnessSummary("\(cfg.label) plain spin=14 backoff per-task-acquires", counts: counts)
        }

        Benchmark("\(cfg.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) plain spin=40 fixed acquire-latency", merged)
            printFairnessSummary("\(cfg.label) plain spin=40 fixed per-task-acquires", counts: counts)
        }

        Benchmark("\(cfg.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) Optimal acquire-latency", merged)
            printFairnessSummary("\(cfg.label) Optimal per-task-acquires", counts: counts)
        }

        Benchmark("\(cfg.label) RustMutex") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) RustMutex acquire-latency", merged)
            printFairnessSummary("\(cfg.label) RustMutex per-task-acquires", counts: counts)
        }

        if runExperiment {
            Benchmark("\(cfg.label) CLH") { benchmark in
                let m = CLHMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                let (hists, counts) = await longRunWorkload(
                    tasks: cfg.tasks,
                    durationSeconds: cfg.durationSeconds,
                    work: cfg.work
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) CLH acquire-latency", merged)
                printFairnessSummary("\(cfg.label) CLH per-task-acquires", counts: counts)
            }
        }

        Benchmark("\(cfg.label) pthread_adaptive_np") { benchmark in
            let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            let (hists, counts) = await longRunWorkload(
                tasks: cfg.tasks,
                durationSeconds: cfg.durationSeconds,
                work: cfg.work
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) pthread_adaptive_np acquire-latency", merged)
            printFairnessSummary("\(cfg.label) pthread_adaptive_np per-task-acquires", counts: counts)
        }
        #endif
    }
}
