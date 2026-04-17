import Benchmark
import Foundation
import MutexBench

// 2 = folly/abseil minimum symmetric contention point.
// 192, 384 = Go-style oversubscription (4×, 8× on a 48C EPYC).
// https://github.com/golang/go/blob/master/src/sync/mutex_test.go
let configs = [1, 2, 4, 8, 16, 64, 96, 192, 384].map { BenchConfig(tasks: $0, work: 1) }

// Set MUTEX_BENCH_MAX_SECS=1 for a quick smoke run across all configs.
let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 15

// pthread_adaptive_np gated — it tracks NIOLock closely on most workloads,
// provides low differential signal per run. Set MUTEX_BENCH_SLOW=1 to include.
let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"

// Synchronization.Mutex (copy) gated — the faithful stdlib copy tracks the
// real stdlib Mutex within noise, so it's redundant on most runs. Set
// MUTEX_BENCH_COPY=1 to include (e.g. when validating a stdlib change).
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: 25,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: 250
    )

    for cfg in configs {
        Benchmark("\(cfg.label) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) { box.work(cfg.work) }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) { box.work(cfg.work) }
            benchmark.stopMeasurement()
        }

        #if os(Linux)
        if runCopy {
            Benchmark("\(cfg.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }

        Benchmark("\(cfg.label) PI no-spin") { benchmark in
            let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity), spinTries: 0)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        if runSlow {
            Benchmark("\(cfg.label) pthread_adaptive_np") { benchmark in
                let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif
    }
}
