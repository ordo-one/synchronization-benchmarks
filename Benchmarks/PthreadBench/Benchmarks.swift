import Benchmark
import Foundation
import MutexBench

let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 15

let pthreadBenchCases: [PthreadBenchCase] = [
    .init(threads: 1, locks: 1, ops: 50_000),
    .init(threads: 4, locks: 1, ops: 50_000),
    .init(threads: 4, locks: 10, ops: 50_000),
    .init(threads: 16, locks: 1, ops: 25_000),
    .init(threads: 16, locks: 10, ops: 25_000),
    .init(threads: 16, locks: 100, ops: 25_000),
    .init(threads: 64, locks: 1, ops: 10_000),
    .init(threads: 64, locks: 10, ops: 10_000),
    .init(threads: 64, locks: 100, ops: 10_000),
    .init(threads: 128, locks: 1, ops: 5_000),
    .init(threads: 128, locks: 10, ops: 5_000),
    .init(threads: 128, locks: 100, ops: 5_000),
]

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: 5,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: 50
    )

    for cfg in pthreadBenchCases {
        Benchmark("\(cfg.label) Synchronization.Mutex") { benchmark in
            benchmark.startMeasurement()
            let result = runPthreadBenchCase(cfg, lockFactory: PthreadBenchSyncMutexCounter.make)
            benchmark.stopMeasurement()
            precondition(result.total == UInt64(cfg.threads * cfg.ops))
        }

        Benchmark("\(cfg.label) NIOLockedValueBox") { benchmark in
            benchmark.startMeasurement()
            let result = runPthreadBenchCase(cfg, lockFactory: PthreadBenchNIOLockCounter.make)
            benchmark.stopMeasurement()
            precondition(result.total == UInt64(cfg.threads * cfg.ops))
        }

        #if os(Linux)
        Benchmark("\(cfg.label) Stdlib PI") { benchmark in
            benchmark.startMeasurement()
            let result = runPthreadBenchCase(cfg, lockFactory: PthreadBenchStdlibPICounter.make)
            benchmark.stopMeasurement()
            precondition(result.total == UInt64(cfg.threads * cfg.ops))
        }

        Benchmark("\(cfg.label) spin=0") { benchmark in
            benchmark.startMeasurement()
            let result = runPthreadBenchCase(cfg, lockFactory: PthreadBenchPlainFutexSpin0Counter.make)
            benchmark.stopMeasurement()
            precondition(result.total == UInt64(cfg.threads * cfg.ops))
        }

        Benchmark("\(cfg.label) spin=14 backoff") { benchmark in
            benchmark.startMeasurement()
            let result = runPthreadBenchCase(cfg, lockFactory: PthreadBenchPlainFutexSpin14BackoffCounter.make)
            benchmark.stopMeasurement()
            precondition(result.total == UInt64(cfg.threads * cfg.ops))
        }

        Benchmark("\(cfg.label) spin=40 fixed") { benchmark in
            benchmark.startMeasurement()
            let result = runPthreadBenchCase(cfg, lockFactory: PthreadBenchPlainFutexSpin40FixedCounter.make)
            benchmark.stopMeasurement()
            precondition(result.total == UInt64(cfg.threads * cfg.ops))
        }

        Benchmark("\(cfg.label) Optimal") { benchmark in
            benchmark.startMeasurement()
            let result = runPthreadBenchCase(cfg, lockFactory: PthreadBenchOptimalCounter.make)
            benchmark.stopMeasurement()
            precondition(result.total == UInt64(cfg.threads * cfg.ops))
        }
        #endif
    }
}
