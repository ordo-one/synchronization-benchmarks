import Benchmark
import MutexBench

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
    BenchEnv.applyDefaultConfig(
        warmupIterations: 25,
        maxDurationSecs: BenchEnv.maxSecs(default: 15),
        maxIterations: 250
    )

    for cfg in configs {
        for v in StandardVariants.defaultsWithRust() {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    h.runLocked { $0.update(iterations: cfg.work) }
                    if cfg.pause > 0 { doUnlockedWork(cfg.pause) }
                }
                benchmark.stopMeasurement()
            }
        }
    }
}
