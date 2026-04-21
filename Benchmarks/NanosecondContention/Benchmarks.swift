import Benchmark
import MutexBench

// Ported from abseil's BM_Contended / BM_ContendedNoLocking:
//   https://github.com/abseil/abseil-cpp/blob/master/absl/synchronization/mutex_benchmark.cc
//
// Rationale vs the count-based sweeps (WorkSweep/PauseSweep): delays are
// specified in nanoseconds via a calibrated busy-wait. Results are comparable
// across machines without re-normalising for CPU speed. abseil's standard
// parameter ranges are used verbatim.

struct NsConfig: Sendable {
    let tasks: Int
    let insideNs: Int
    let outsideNs: Int
    var label: String { "tasks=\(tasks) in=\(insideNs)ns out=\(outsideNs)ns" }
    var acquiresPerTask: Int { defaultTotalAcquires / tasks }
}

// abseil grid: threads {1,2,4,8,16,32,64} × delay_inside {0,50,1000,100000} × delay_outside {0,100,2000,500000}
// Trimmed to interesting cells for bench duration; keep the cross-axis spread.
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

let nsConfigs = nsConfigsFast + (BenchEnv.slow ? nsConfigsSlow : [])

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
    BenchEnv.applyDefaultConfig(
        warmupIterations: 3,
        maxDurationSecs: BenchEnv.maxSecs(default: 15),
        maxIterations: 50
    )

    for cfg in nsConfigs {
        for v in StandardVariants.defaultsWithRust() {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await nsWorkload(
                    tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask,
                    insideNs: cfg.insideNs, outsideNs: cfg.outsideNs
                ) { inside in
                    h.runLocked { _ in inside() }
                }
                benchmark.stopMeasurement()
            }
        }

        // BM_ContendedNoLocking — no lock, same loop shape. Quantifies loop overhead.
        Benchmark("\(cfg.label) no-lock baseline") { benchmark in
            benchmark.startMeasurement()
            await nsWorkload(
                tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask,
                insideNs: cfg.insideNs, outsideNs: cfg.outsideNs
            ) { inside in
                inside()
            }
            benchmark.stopMeasurement()
        }
    }
}
