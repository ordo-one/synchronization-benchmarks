import Benchmark
import Foundation
import MutexBench

let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 15

// Ported from abseil's BM_Contended / BM_ContendedNoLocking:
//   https://github.com/abseil/abseil-cpp/blob/master/absl/synchronization/mutex_benchmark.cc
//
// Rationale vs the count-based sweeps (WorkSweep/PauseSweep): delays are
// specified in nanoseconds via a calibrated busy-wait. Results are comparable
// across machines without re-normalising for CPU speed. abseil's standard
// parameter ranges are used verbatim.
//
// Includes:
//   - BM_Contended grid: (threads × delay_inside_ns × delay_outside_ns)
//   - BM_ContendedNoLocking baseline: same loop without a lock — measures
//     loop-overhead floor so "NIOLock" time is not conflated with loop cost.
//   - Synchronized start via shared deadline so all tasks hit the lock from
//     iteration 0 (abseil uses absl::Notification for this).

struct NsConfig: Sendable {
    let tasks: Int
    let insideNs: Int
    let outsideNs: Int
    var label: String { "tasks=\(tasks) in=\(insideNs)ns out=\(outsideNs)ns" }
    var acquiresPerTask: Int { defaultTotalAcquires / tasks }
}

// abseil grid: threads {1,2,4,8,16,32,64} × delay_inside {0,50,1000,100000} × delay_outside {0,100,2000,500000}
// Trimmed to interesting cells for bench duration; keep the cross-axis spread.
let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"

let nsConfigsFast: [NsConfig] = [
    // Inside sweep at high contention
    .init(tasks: 16, insideNs: 0,      outsideNs: 0),
    .init(tasks: 16, insideNs: 50,     outsideNs: 0),
    .init(tasks: 16, insideNs: 1_000,  outsideNs: 0),
    // Outside sweep (contention ratio) at fixed tight inside
    .init(tasks: 16, insideNs: 50,     outsideNs: 100),
    .init(tasks: 16, insideNs: 50,     outsideNs: 2_000),
    // Threads sweep at fixed middle point
    .init(tasks: 2,  insideNs: 50,     outsideNs: 100),
    .init(tasks: 8,  insideNs: 50,     outsideNs: 100),
    .init(tasks: 64, insideNs: 50,     outsideNs: 100),
]

let nsConfigsSlow: [NsConfig] = [
    // Long CS — ~5s per iter. Gated behind MUTEX_BENCH_SLOW=1.
    .init(tasks: 16, insideNs: 100_000, outsideNs: 0),
]

let nsConfigs = nsConfigsFast + (runSlow ? nsConfigsSlow : [])

@inline(__always)
func nsWorkload(
    tasks: Int,
    acquiresPerTask: Int,
    insideNs: Int,
    outsideNs: Int,
    acquire: @Sendable @escaping (@Sendable () -> Void) -> Void
) async {
    let gate = SyncedStart()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<tasks {
            group.addTask {
                await gate.waitForStart()
                for _ in 0..<acquiresPerTask {
                    acquire { burnNs(insideNs) }
                    if outsideNs > 0 { burnNs(outsideNs) }
                }
            }
        }
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: 3,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: 50
    )

    for cfg in nsConfigs {
        Benchmark("\(cfg.label) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                box.m.withLock { _ in inside() }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                box.box.withLockedValue { _ in inside() }
            }
            benchmark.stopMeasurement()
        }

        #if os(Linux)
        if runCopy {
            Benchmark("\(cfg.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                    m.withLock { _ in inside() }
                }
                benchmark.stopMeasurement()
            }
        }

        Benchmark("\(cfg.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                m.withLock { _ in inside() }
            }
            benchmark.stopMeasurement()
        }

        // Tuned variants — prior SpinSweepExperiments winners.
        Benchmark("\(cfg.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                m.withLock { _ in inside() }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                m.withLock { _ in inside() }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                m.withLock { _ in inside() }
            }
            benchmark.stopMeasurement()
        }

        if runSlow {
            Benchmark("\(cfg.label) pthread_adaptive_np") { benchmark in
                let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                    m.withLock { _ in inside() }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif

        // BM_ContendedNoLocking — no lock, same loop shape. Quantifies loop overhead.
        Benchmark("\(cfg.label) no-lock baseline") { benchmark in
            benchmark.startMeasurement()
            await nsWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask, insideNs: cfg.insideNs, outsideNs: cfg.outsideNs) { inside in
                inside()
            }
            benchmark.stopMeasurement()
        }
    }
}
