import Benchmark
import Foundation
import MutexBench

// Main sweep: uniform hold-time axis at fixed tasks=16.
// work=0 is the empty-CS floor (pure lock/unlock overhead).
//   See: https://matklad.github.io/2020/01/04/mutexes-are-faster-than-spinlocks.html
//        https://webkit.org/blog/6161/locking-in-webkit/ — LockSpeedTest worksInsideLock=0
let fastWork = [0, 1, 16, 64, 128]
let slowWork = [256, 1024]
let configs = (fastWork + (BenchEnv.slow ? slowWork : [])).map { BenchConfig(tasks: 16, work: $0) }

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
// Adapted from https://github.com/cuongleqq/mutex-benches LongHold scenario.
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
    BenchEnv.applyDefaultConfig(
        warmupIterations: 3,
        maxDurationSecs: BenchEnv.maxSecs(default: 15),
        maxIterations: 50
    )

    let variants = StandardVariants.defaultsWithRust()

    // Uniform hold-time sweep.
    for cfg in configs {
        for v in variants {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    h.runLocked { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
    }

    // Bimodal hold-time.
    for bc in bimodalConfigs {
        for v in variants {
            Benchmark("\(bc.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
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
                            ) { w in h.runLocked { $0.update(iterations: w) } }
                        }
                    }
                }
                benchmark.stopMeasurement()
            }
        }
    }

    // Sleep-inside-lock.
    for sc in sleepHoldConfigs {
        let sleepSec = Double(sc.holdUs) / 1_000_000.0
        for v in variants {
            Benchmark("\(sc.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: sc.tasks, acquiresPerTask: sc.acquiresPerTask) {
                    h.runLocked { _ in Thread.sleep(forTimeInterval: sleepSec) }
                }
                benchmark.stopMeasurement()
            }
        }
    }
}
