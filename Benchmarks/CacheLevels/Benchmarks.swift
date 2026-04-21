import Benchmark
import MutexBench

// Sweeps protected-state size through L1 → L2 → L3 → DRAM at fixed high
// contention. Random-key access inside the lock defeats the HW prefetcher,
// so capacity maps directly to the dominant cache level:
//
//   ~48 bytes per Dictionary entry → working-set estimate:
//     64      ≈ 3 KB    → L1 (all in-core)
//     1_024   ≈ 48 KB   → spills L1, fits L2
//     16_384  ≈ 768 KB  → L2 border
//     262_144 ≈ 12 MB   → L3 (fits on shared last-level)
//     1_048_576 ≈ 48 MB → busts typical L3, hits DRAM
//
// Holds tasks=16 and work=8 fixed so only cache level changes. The question
// this answers: does the 97× Sync.Mutex regression persist when the critical
// section is memory-bound, or does memory-stall time hide the spin waste?

struct WSCase: Sendable {
    let capacity: Int
    let tasks: Int
    let work: Int
    var label: String { "ws=\(capacity) tasks=\(tasks) work=\(work)" }
    var acquiresPerTask: Int { defaultTotalAcquires / tasks }
}

let wsCases: [WSCase] = [
    .init(capacity: 64,        tasks: 16, work: 8),   // L1
    .init(capacity: 1_024,     tasks: 16, work: 8),   // L2
    .init(capacity: 16_384,    tasks: 16, work: 8),   // L2/L3 border
    .init(capacity: 262_144,   tasks: 16, work: 8),   // L3
    .init(capacity: 1_048_576, tasks: 16, work: 8),   // DRAM
]

let benchmarks: @Sendable () -> Void = {
    BenchEnv.applyDefaultConfig(
        warmupIterations: 10,
        maxDurationSecs: BenchEnv.maxSecs(default: 20),
        maxIterations: 100
    )

    for c in wsCases {
        for v in StandardVariants.defaultsWithRust() {
            Benchmark("\(c.label) \(v.name)") { benchmark in
                let h = v.make(c.capacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: c.tasks, acquiresPerTask: c.acquiresPerTask) {
                    h.runLocked { $0.updateRandom(iterations: c.work) }
                }
                benchmark.stopMeasurement()
            }
        }
    }
}
