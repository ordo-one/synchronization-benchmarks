import Benchmark
import MutexBench
#if os(Linux)
import CFutexShims
#endif

// Default suite: Optimal + RustMutex + NIO + a small set of best variations.
// Set MUTEX_BENCH_EXPERIMENT=1 to enable the full exploration matrix
// (budget sweeps, adaptive/two-stage/epoch/hint variants, historical reference).

// RustMutex tuning grid — two axes to match pthread park cost (10-30µs wake):
//   A. More iterations × 1 PAUSE (more loads, same ~35ns spacing)
//   B. Same iterations × more PAUSE (same load count, wider spacing)
#if os(Linux)
let rustTuningGrid: [MutexVariant] = [
    // A1/A2: more iterations × 1 PAUSE.
    .rustMutex(name: "RustMutex sp=500 × 1",  spinTries: 500,  pausesPerIter: 1),
    .rustMutex(name: "RustMutex sp=1000 × 1", spinTries: 1000, pausesPerIter: 1),
    // B1/B2: same iterations × more PAUSE.
    .rustMutex(name: "RustMutex sp=100 × 16", spinTries: 100, pausesPerIter: 16),
    .rustMutex(name: "RustMutex sp=100 × 32", spinTries: 100, pausesPerIter: 32),
    // C: middle ground.
    .rustMutex(name: "RustMutex sp=40 × 32",  spinTries: 40,  pausesPerIter: 32),
    // Retry axis — hybrid between Rust load-only and Optimal in-spin CAS.
    .rustMutex(name: "RustMutex sp=100 × 1 retry=5",   spinTries: 100, pausesPerIter: 1,  outerRetries: 5),
    .rustMutex(name: "RustMutex sp=100 × 1 retry=20",  spinTries: 100, pausesPerIter: 1,  outerRetries: 20),
    .rustMutex(name: "RustMutex sp=100 × 16 retry=20", spinTries: 100, pausesPerIter: 16, outerRetries: 20),
    // Bounded-retrier experiment.
    // NOTE: `retrierLimit=1, spinIfLimited=true` was removed — livelocks at
    // tasks≥8. With only 1 retrier slot, remaining 7+ threads spin forever
    // in load-only mode instead of parking, bench never completes.
    // `limit=1 park` (spinIfLimited=false) is fine — excess threads park.
    // `limit≥2 spin` is fine — enough retrier slots to avoid the live-lock.
    .rustMutex(name: "RustMutex sp=100 × 8 retry=5 limit=1 park", spinTries: 100, pausesPerIter: 8, outerRetries: 5, retrierLimit: 1, spinIfLimited: false),
    .rustMutex(name: "RustMutex sp=100 × 8 retry=5 limit=2 spin", spinTries: 100, pausesPerIter: 8, outerRetries: 5, retrierLimit: 2, spinIfLimited: true),
    .rustMutex(name: "RustMutex sp=100 × 8 retry=5 limit=4 spin", spinTries: 100, pausesPerIter: 8, outerRetries: 5, retrierLimit: 4, spinIfLimited: true),
    // Depth-adaptive gate grafted onto Rust-style spin.
    .rustMutex(name: "RustMutex gate=4",                      depthThreshold: 4),
    .rustMutex(name: "RustMutex sp=100 × 16 gate=4",          spinTries: 100, pausesPerIter: 16, depthThreshold: 4),
    .rustMutex(name: "RustMutex sp=100 × 16 retry=20 gate=4", spinTries: 100, pausesPerIter: 16, outerRetries: 20, depthThreshold: 4),
]

// Stuck-at-2 fix variants hang reproducibly on SpinTuning tasks=2/16 across
// AMD Zen 4 64c, Skylake 40c NUMA, Broadwell 44c NUMA, and Apple M1 Ultra.
// Gated behind MUTEX_BENCH_RUST_DEMOTE=1.
let rustDemoteVariants: [MutexVariant] = [
    .rustMutex(name: "RustMutex demote", demoteOnEmpty: true),
    .rustMutex(name: "RustMutex demote+skipWake", skipSpuriousWake: true, demoteOnEmpty: true),
    .rustMutex(name: "RustMutex sp=100 × 16 demote+skipWake",
               spinTries: 100, pausesPerIter: 16,
               skipSpuriousWake: true, demoteOnEmpty: true),
]

// INSTR DepthAdaptive sweep for t∈[8,16]. K=4 variant.
let stInstrDepthSweep: [MutexVariant] = [
    .depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pcl=64",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postCASLostPause: 64, instrument: true
    ),
    .depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pcl=128",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postCASLostPause: 128, instrument: true
    ),
    .depthAdaptive(
        name: "INSTR depth K=4 sp=20 base=64 no-starv",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, instrument: true
    ),
    .depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pws=32",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postWakeSpinTries: 32, instrument: true
    ),
    .depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pws=32 dcheck",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postWakeSpinTries: 32,
        preWaitDoubleCheck: true, instrument: true
    ),
    .depthAdaptive(
        name: "INSTR depth K=4 sp=20 base=64 starv=1ms",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: true, starvationThresholdNs: 1_000_000, instrument: true
    ),
    .depthAdaptive(
        name: "INSTR depth K=4 sp=20 base=64 starv=1ms pws=32",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: true, starvationThresholdNs: 1_000_000,
        postWakeSpinTries: 32, instrument: true
    ),
    .depthAdaptive(
        name: "INSTR depth K=4 sp=5 base=64 starv=1ms pws=32",
        spinTries: 5, pauseBase: 64, depthThreshold: 4,
        useStarvation: true, starvationThresholdNs: 1_000_000,
        postWakeSpinTries: 32, instrument: true
    ),
]

// Best variations retained in default suite.
let stBestVariations: [MutexVariant] = [
    .plainFutex(name: "best: sp=40 hwjitter base=128",
                spinTries: 40, earlyExitOnWaiters: true,
                backoffCap: 128, useHWJitter: true),
    .plainFutex(name: "best: sp=20 hwjitter base=128",
                spinTries: 20, earlyExitOnWaiters: true,
                backoffCap: 128, useHWJitter: true),
    .adaptiveSpin(name: "best: adaptive cap=100 base=128", maxCap: 100, pauseBase: 128),
]
#endif

let benchmarks: @Sendable () -> Void = {
    BenchEnv.applyDefaultConfig(
        warmupIterations: BenchEnv.focus ? 5 : 25,
        maxDurationSecs: BenchEnv.maxSecs(default: 15),
        maxIterations: BenchEnv.focus ? 50 : 250
    )

    let taskList = BenchEnv.focus ? [8, 16, 64, 192] : [1, 2, 4, 8, 16, 64, 192]

    func emit(_ tasks: Int, _ cfg: BenchConfig, _ v: MutexVariant, dumpLabel: String? = nil) {
        Benchmark("tasks=\(tasks) \(v.name)") { benchmark in
            let h = v.make(defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                h.runLocked { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
            if let label = dumpLabel { h.dumpStats?(label) }
        }
    }

    for tasks in taskList {
        let cfg = BenchConfig(tasks: tasks, work: 1)

        if !BenchEnv.focus {
            emit(tasks, cfg, .niolock())
        }

        #if os(Linux)
        emit(tasks, cfg, .optimal())

        if !BenchEnv.focus {
            emit(tasks, cfg, .rustMutex())
            for v in rustTuningGrid { emit(tasks, cfg, v) }
            if BenchEnv.rustDemote {
                for v in rustDemoteVariants { emit(tasks, cfg, v) }
            }
        }

        // ---- Instrumented runs (t=8, t=16, stats dumped to stderr) ----
        if tasks == 8 || tasks == 16 {
            emit(tasks, cfg, .optimal(name: "INSTR Optimal", instrument: true),
                 dumpLabel: "Optimal t=\(tasks)")

            if !BenchEnv.focus {
                emit(tasks, cfg, .rustMutex(name: "INSTR RustMutex", instrument: true),
                     dumpLabel: "RustMutex t=\(tasks)")
                emit(tasks, cfg, .rustMutex(
                    name: "INSTR RustMutex sp=100 × 16 retry=20",
                    spinTries: 100, pausesPerIter: 16, outerRetries: 20, instrument: true
                ), dumpLabel: "RustMutex sp=100x16 retry=20 t=\(tasks)")
                if BenchEnv.rustDemote {
                    emit(tasks, cfg, .rustMutex(
                        name: "INSTR RustMutex demote+skipWake",
                        skipSpuriousWake: true, demoteOnEmpty: true, instrument: true
                    ), dumpLabel: "RustMutex demote+skipWake t=\(tasks)")
                }
            }

            for v in stInstrDepthSweep {
                let dumpName = v.name.replacingOccurrences(of: "INSTR ", with: "")
                emit(tasks, cfg, v, dumpLabel: "\(dumpName) t=\(tasks)")
            }
        }

        if !BenchEnv.focus {
            for v in stBestVariations { emit(tasks, cfg, v) }
        }

        if BenchEnv.experiment {
            emit(tasks, cfg, .syncMutex(name: "EXP Synchronization.Mutex"))
            emit(tasks, cfg, .piNoSpin(name: "EXP PI no-spin"))
            emit(tasks, cfg, .plainFutex(name: "EXP spin=0", spinTries: 0))
            for spin in [14, 40] {
                emit(tasks, cfg, .plainFutex(name: "EXP spin=\(spin) fixed", spinTries: spin))
            }
            emit(tasks, cfg, .plainFutex(
                name: "EXP early-exit spin=40 jitter",
                spinTries: 40, earlyExitOnWaiters: true,
                useBackoff: true, backoffCap: 32, backoffFloor: 4,
                useJitter: true
            ))
            for spins in [3, 5, 10] {
                emit(tasks, cfg, .plainFutex(
                    name: "EXP early-exit spin=\(spins) hwjitter base=128",
                    spinTries: spins, earlyExitOnWaiters: true,
                    backoffCap: 128, useHWJitter: true
                ))
            }
            emit(tasks, cfg, .plainFutex(
                name: "EXP early-exit spin=20 hwjitter base=64",
                spinTries: 20, earlyExitOnWaiters: true,
                backoffCap: 64, useHWJitter: true
            ))
            for base: UInt32 in [16, 32, 64, 96, 128] {
                let isPow2 = base & (base - 1) == 0
                if isPow2 {
                    emit(tasks, cfg, .plainFutex(
                        name: "EXP early-exit spin=40 hwjitter base=\(base)",
                        spinTries: 40, earlyExitOnWaiters: true,
                        backoffCap: base, useHWJitter: true
                    ))
                }
                emit(tasks, cfg, .plainFutex(
                    name: "EXP early-exit spin=40 flat\(base)",
                    spinTries: 40, earlyExitOnWaiters: true,
                    useBackoff: true, backoffCap: base, backoffFloor: base
                ))
            }
            for (cap, base): (UInt32, UInt32) in [
                (10, 64), (10, 128),
                (20, 64), (20, 128),
                (40, 64), (40, 128),
                (100, 64),
            ] {
                emit(tasks, cfg, .adaptiveSpin(
                    name: "EXP adaptive cap=\(cap) base=\(base)",
                    maxCap: cap, pauseBase: base
                ))
            }
            // TwoStage/Epoch/Hint: none beat Optimal; kept inline (no variant
            // factories since these are rarely used and take no params).
            Benchmark("tasks=\(tasks) EXP two-stage 5/128 + 5/32") { benchmark in
                let m = TwoStageMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
            Benchmark("tasks=\(tasks) EXP epoch spin=40 base=128") { benchmark in
                let m = EpochMutex(MapState(capacity: defaultMapCapacity), spinTries: 40, pauseBase: 128)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
            Benchmark("tasks=\(tasks) EXP hint spin=40 base=128") { benchmark in
                let m = HintMutex(MapState(capacity: defaultMapCapacity), spinTries: 40, pauseBase: 128)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
            // Separate cache line: 17-22% help on Intel single-die, hurts AMD.
            emit(tasks, cfg, .plainFutex(
                name: "EXP early-exit spin=40 hwjitter64+sep",
                spinTries: 40, earlyExitOnWaiters: true,
                backoffCap: 64, useHWJitter: true, separateCacheLine: true
            ))
        }
        #endif
    }

    // ---- t=32 OptimalMutex INSTR (standalone — 32 not in main loop) ----
    #if os(Linux)
    do {
        let cfg = BenchConfig(tasks: 32, work: 1)
        emit(32, cfg, .optimal(name: "INSTR Optimal", instrument: true),
             dumpLabel: "Optimal t=32")
    }
    #endif
}
