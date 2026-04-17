import Benchmark
import Foundation
import MutexBench

let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 15

// Main sweep: uniform hold-time axis at fixed tasks=16.
// work=0 is the empty-CS floor (pure lock/unlock overhead).
//   See: https://matklad.github.io/2020/01/04/mutexes-are-faster-than-spinlocks.html
//        https://webkit.org/blog/6161/locking-in-webkit/ — LockSpeedTest worksInsideLock=0
let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"
let fastWork = [0, 1, 16, 64, 128]
let slowWork = [256, 1024]
let configs = (fastWork + (runSlow ? slowWork : [])).map { BenchConfig(tasks: 16, work: $0) }

// Bimodal hold-time: short path most of the time, long path rarely.
// Tests whether fixed-spin budgets match the median (short) or the mean (skewed).
// Adaptive algorithms should track median. Source:
//   folly bench varies hold-time distributions; Go starvation-mode is bimodal-triggered.
struct BimodalConfig: Sendable {
    let tasks: Int
    let shortWork: Int
    let longWork: Int
    let longProbPct: Int
    var label: String { "tasks=\(tasks) bimodal(\(shortWork)/\(longWork))@\(longProbPct)%" }
    var acquiresPerTask: Int { defaultTotalAcquires / tasks }
}

let bimodalConfigs: [BimodalConfig] = [
    .init(tasks: 16, shortWork: 1, longWork: 256, longProbPct: 10),
    .init(tasks: 16, shortWork: 1, longWork: 1024, longProbPct: 5),
    .init(tasks: 64, shortWork: 1, longWork: 256, longProbPct: 10),
]

// Sleep-inside-lock: holder blocks in kernel rather than burning CPU.
// Forces every waiter through the kernel-wait path and, for PI-futex,
// through the rt_mutex PI-chain walk — different regime from CPU-busy holds.
// Adapted from https://github.com/cuongleqq/mutex-benches LongHold scenario
// (thread::sleep inside the lock; default hold_us=200).
struct SleepHoldConfig: Sendable {
    let tasks: Int
    let holdUs: UInt32
    var label: String { "tasks=\(tasks) sleepHold=\(holdUs)µs" }
    // Small count — 64 × holdUs already dominates wall time at tasks ≥ 8.
    var acquiresPerTask: Int { 64 }
}

let sleepHoldConfigs: [SleepHoldConfig] = [
    .init(tasks: 8,  holdUs: 200),
    .init(tasks: 16, holdUs: 200),
]

@inline(__always)
func bimodalBody(
    acquiresPerTask: Int,
    taskSeed: UInt64,
    shortWork: Int,
    longWork: Int,
    longProbPct: Int,
    acquire: (Int) -> Void
) {
    var r = taskSeed | 1
    let threshold = UInt64(longProbPct) * (UInt64.max / 100)
    for _ in 0..<acquiresPerTask {
        r ^= r &<< 13
        r ^= r &>> 7
        r ^= r &<< 17
        let w = r < threshold ? longWork : shortWork
        acquire(w)
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

    for bc in bimodalConfigs {
        Benchmark("\(bc.label) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<bc.tasks {
                    let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                    group.addTask {
                        bimodalBody(
                            acquiresPerTask: bc.acquiresPerTask,
                            taskSeed: seed,
                            shortWork: bc.shortWork,
                            longWork: bc.longWork,
                            longProbPct: bc.longProbPct
                        ) { w in box.work(w) }
                    }
                }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(bc.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<bc.tasks {
                    let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                    group.addTask {
                        bimodalBody(
                            acquiresPerTask: bc.acquiresPerTask,
                            taskSeed: seed,
                            shortWork: bc.shortWork,
                            longWork: bc.longWork,
                            longProbPct: bc.longProbPct
                        ) { w in box.work(w) }
                    }
                }
            }
            benchmark.stopMeasurement()
        }

        #if os(Linux)
        if runCopy {
            Benchmark("\(bc.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await withTaskGroup(of: Void.self) { group in
                    for t in 0..<bc.tasks {
                        let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                        group.addTask {
                            bimodalBody(
                                acquiresPerTask: bc.acquiresPerTask,
                                taskSeed: seed,
                                shortWork: bc.shortWork,
                                longWork: bc.longWork,
                                longProbPct: bc.longProbPct
                            ) { w in m.withLock { $0.update(iterations: w) } }
                        }
                    }
                }
                benchmark.stopMeasurement()
            }
        }

        Benchmark("\(bc.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<bc.tasks {
                    let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                    group.addTask {
                        bimodalBody(
                            acquiresPerTask: bc.acquiresPerTask,
                            taskSeed: seed,
                            shortWork: bc.shortWork,
                            longWork: bc.longWork,
                            longProbPct: bc.longProbPct
                        ) { w in m.withLock { $0.update(iterations: w) } }
                    }
                }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(bc.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<bc.tasks {
                    let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                    group.addTask {
                        bimodalBody(
                            acquiresPerTask: bc.acquiresPerTask,
                            taskSeed: seed,
                            shortWork: bc.shortWork,
                            longWork: bc.longWork,
                            longProbPct: bc.longProbPct
                        ) { w in m.withLock { $0.update(iterations: w) } }
                    }
                }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(bc.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<bc.tasks {
                    let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                    group.addTask {
                        bimodalBody(
                            acquiresPerTask: bc.acquiresPerTask,
                            taskSeed: seed,
                            shortWork: bc.shortWork,
                            longWork: bc.longWork,
                            longProbPct: bc.longProbPct
                        ) { w in m.withLock { $0.update(iterations: w) } }
                    }
                }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(bc.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<bc.tasks {
                    let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                    group.addTask {
                        bimodalBody(
                            acquiresPerTask: bc.acquiresPerTask,
                            taskSeed: seed,
                            shortWork: bc.shortWork,
                            longWork: bc.longWork,
                            longProbPct: bc.longProbPct
                        ) { w in m.withLock { $0.update(iterations: w) } }
                    }
                }
            }
            benchmark.stopMeasurement()
        }

        if runSlow {
            Benchmark("\(bc.label) pthread_adaptive_np") { benchmark in
                let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await withTaskGroup(of: Void.self) { group in
                    for t in 0..<bc.tasks {
                        let seed = UInt64(t + 1) &* 0x9E37_79B9_7F4A_7C15
                        group.addTask {
                            bimodalBody(
                                acquiresPerTask: bc.acquiresPerTask,
                                taskSeed: seed,
                                shortWork: bc.shortWork,
                                longWork: bc.longWork,
                                longProbPct: bc.longProbPct
                            ) { w in m.withLock { $0.update(iterations: w) } }
                        }
                    }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif
    }

    for sc in sleepHoldConfigs {
        let sleepSec = Double(sc.holdUs) / 1_000_000.0

        Benchmark("\(sc.label) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                box.m.withLock { _ in Thread.sleep(forTimeInterval: sleepSec) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(sc.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                box.box.withLockedValue { _ in Thread.sleep(forTimeInterval: sleepSec) }
            }
            benchmark.stopMeasurement()
        }

        #if os(Linux)
        if runCopy {
            Benchmark("\(sc.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                    m.withLock { _ in Thread.sleep(forTimeInterval: sleepSec) }
                }
                benchmark.stopMeasurement()
            }
        }

        Benchmark("\(sc.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                m.withLock { _ in Thread.sleep(forTimeInterval: sleepSec) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(sc.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                m.withLock { _ in Thread.sleep(forTimeInterval: sleepSec) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(sc.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                m.withLock { _ in Thread.sleep(forTimeInterval: sleepSec) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(sc.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                m.withLock { _ in Thread.sleep(forTimeInterval: sleepSec) }
            }
            benchmark.stopMeasurement()
        }

        if runSlow {
            Benchmark("\(sc.label) pthread_adaptive_np") { benchmark in
                let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                    m.withLock { _ in Thread.sleep(forTimeInterval: sleepSec) }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif
    }
}
