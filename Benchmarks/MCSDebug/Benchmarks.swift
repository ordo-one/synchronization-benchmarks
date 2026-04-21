import Benchmark
import Foundation
import MutexBench

// MCSDebug — small, fast reproducer for MCSMutex perf investigation.
//
// Goal: isolate whether bad perf comes from queue logic, cache-line layout,
// or memory ordering. Runs in ~15s total (3 configs × 5s each).
//
// Invocation:
//   swift package benchmark --target MCSDebug
//   MUTEX_BENCH_MAX_SECS=2 swift package benchmark --target MCSDebug   # faster
//
// Reference: NIOLock baseline at the same contention to distinguish an
// MCS-specific bug from a workload artefact.

let cfg = BenchConfig(tasks: 16, work: 1)   // single hot point, max contention

let maxSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 5

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .throughput, .contextSwitches],
        timeUnits: .microseconds,
        warmupIterations: 5,
        maxDuration: .seconds(maxSecs),
        maxIterations: 50
    )

    // Baseline: park-immediately pthread wrapper. If MCS is slower than this,
    // the MCS queue is worse than no spinning at all — a clear red flag.
    Benchmark("\(cfg.label) NIOLock (baseline)") { benchmark in
        let box = NIOLockBox(capacity: defaultMapCapacity)
        benchmark.startMeasurement()
        await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
            box.work(cfg.work)
        }
        benchmark.stopMeasurement()
    }

    #if os(Linux)
    // MCS current defaults (spinTries=200, pauseBase=128).
    Benchmark("\(cfg.label) MCS sp=200 base=128") { benchmark in
        let m = MCSMutex(MapState(capacity: defaultMapCapacity),
                         spinTries: 200, pauseBase: 128)
        benchmark.startMeasurement()
        await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
            m.withLock { $0.update(iterations: cfg.work) }
        }
        benchmark.stopMeasurement()
    }

    // MCS with tighter spin — isolates whether the spin loop itself is wrong.
    // If perf is similar, bug is in queue logic; if much different, spin loop.
    Benchmark("\(cfg.label) MCS sp=0 (straight to futex)") { benchmark in
        let m = MCSMutex(MapState(capacity: defaultMapCapacity),
                         spinTries: 0, pauseBase: 128)
        benchmark.startMeasurement()
        await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
            m.withLock { $0.update(iterations: cfg.work) }
        }
        benchmark.stopMeasurement()
    }
    #endif
}
