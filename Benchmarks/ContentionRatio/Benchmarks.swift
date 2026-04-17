import Benchmark
import Foundation
import MutexBench

let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 15
let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"

let configs: [BenchConfig] = [
    // Main pause sweep at tasks=16, work=1.
    BenchConfig(tasks: 16, work: 1, pause: 0),
    BenchConfig(tasks: 16, work: 1, pause: 10),
    BenchConfig(tasks: 16, work: 1, pause: 100),
    // Cross-axis: pause effect at different contention levels.
    BenchConfig(tasks: 4, work: 1, pause: 10),
    BenchConfig(tasks: 64, work: 1, pause: 10),
    // Ordo-realistic: dict lookup under lock + message processing between acquires.
    BenchConfig(tasks: 16, work: 4, pause: 10),
]

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
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                box.work(cfg.work)
                if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                box.work(cfg.work)
                if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
            }
            benchmark.stopMeasurement()
        }

        #if os(Linux)
        if runCopy {
            Benchmark("\(cfg.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                    if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
                }
                benchmark.stopMeasurement()
            }
        }

        Benchmark("\(cfg.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
                if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
                if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
                if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
                if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
            }
            benchmark.stopMeasurement()
        }

        if runSlow {
            Benchmark("\(cfg.label) pthread_adaptive_np") { benchmark in
                let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                    if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif
    }
}
