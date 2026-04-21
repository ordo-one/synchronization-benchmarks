import Benchmark
import MutexBench

// 2 = folly/abseil minimum symmetric contention point.
// 192, 384 = Go-style oversubscription (4×, 8× on a 48C EPYC).
// https://github.com/golang/go/blob/master/src/sync/mutex_test.go
let configs: [BenchConfig] = {
    let ts = BenchEnv.focus ? [1, 8, 20, 24, 32, 64, 96, 192, 384] : [1, 2, 4, 8, 16, 20, 22, 24, 32, 64, 96, 192, 384]
    return ts.map { BenchConfig(tasks: $0, work: 1) }
}()

// Ship-candidate depth-adaptive sweep at K=2 (throughput tuning). +20% wallclock
// vs plain Optimal — INSTR variants compare against INSTR Optimal, not plain.
#if os(Linux)
let csInstrSweep: [MutexVariant] = {
    var v: [MutexVariant] = [
        .optimal(name: "INSTR Optimal", instrument: true),
        .parkingLot(name: "INSTR parking_lot", instrument: true),
    ]

    if !BenchEnv.focus {
        // (sp, base) combinations: budget = sp × base avg pauses.
        //   sp=20 base=64  ≈ ~6µs Alder Lake / ~3µs AMD
        //   sp=10 base=64  ≈ ~3µs
        //   sp=10 base=32  ≈ ~1.5µs — tight, stress-test
        //   sp=5  base=64  ≈ ~1.5µs — wider pause, fewer iters
        for (sp, base) in [(20, UInt32(64)), (10, UInt32(64)), (10, UInt32(32)), (5, UInt32(64))] {
            v.append(.depthAdaptive(
                name: "INSTR depth K=2 sp=\(sp) base=\(base)",
                spinTries: sp, pauseBase: base, depthThreshold: 2, instrument: true
            ))
        }
        // K=1 axis: tighter gate → smaller spinner pool → higher per-spinner catch.
        for sp in [20, 10, 5] {
            v.append(.depthAdaptive(
                name: "INSTR depth K=1 sp=\(sp) base=64",
                spinTries: sp, pauseBase: 64, depthThreshold: 1, instrument: true
            ))
        }
        // Post-wake spin: woken thread scans word instead of immediately
        // re-exchanging. Targets wake-lose-to-barger amplification.
        for pws in [10, 40, 100] {
            v.append(.depthAdaptive(
                name: "INSTR depth K=2 sp=20 base=64 pws=\(pws)",
                spinTries: 20, pauseBase: 64, depthThreshold: 2,
                postWakeSpinTries: pws, instrument: true
            ))
        }
    }

    // Post-CAS-lost cooldown pause — reduces RFO traffic under high contention
    // on AMD high-core-count.
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=20 no-starv pcl=64",
        spinTries: 20, pauseBase: 64, depthThreshold: 2,
        useStarvation: false, postCASLostPause: 64, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=20 no-starv pcl=128",
        spinTries: 20, pauseBase: 64, depthThreshold: 2,
        useStarvation: false, postCASLostPause: 128, instrument: true
    ))
    // Isolate depth+waiterCount cost from starvation.
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=20 base=64 no-starv",
        spinTries: 20, pauseBase: 64, depthThreshold: 2,
        useStarvation: false, instrument: true
    ))
    // no-starv + pws=32: capture wake-lose p99 wins without starvation cost.
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=20 no-starv pws=32",
        spinTries: 20, pauseBase: 64, depthThreshold: 2,
        useStarvation: false, postWakeSpinTries: 32, instrument: true
    ))
    // no-starv + pws + pre-wait double-check: skip futex_wait when word
    // already changed (majority of EAGAIN cases on AMD).
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=20 no-starv pws=32 dcheck",
        spinTries: 20, pauseBase: 64, depthThreshold: 2,
        useStarvation: false, postWakeSpinTries: 32,
        preWaitDoubleCheck: true, instrument: true
    ))
    // Go-style starvation mode at 1ms (Go default, session 2026-04-19 ship candidate).
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=20 base=64 starv=1ms",
        spinTries: 20, pauseBase: 64, depthThreshold: 2,
        useStarvation: true, starvationThresholdNs: 1_000_000, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=20 base=64 starv=1ms pws=32",
        spinTries: 20, pauseBase: 64, depthThreshold: 2,
        useStarvation: true, starvationThresholdNs: 1_000_000,
        postWakeSpinTries: 32, instrument: true
    ))
    // Reduced spin sp=5: fewer CAS attempts → less AMD coherence pressure.
    v.append(.depthAdaptive(
        name: "INSTR depth K=2 sp=5 base=64 starv=1ms pws=32",
        spinTries: 5, pauseBase: 64, depthThreshold: 2,
        useStarvation: true, starvationThresholdNs: 1_000_000,
        postWakeSpinTries: 32, instrument: true
    ))
    if !BenchEnv.focus {
        for sp in [3, 5, 10] {
            v.append(.depthAdaptive(
                name: "INSTR depth K=2 sp=\(sp) base=64 starv=1ms",
                spinTries: sp, pauseBase: 64, depthThreshold: 2,
                useStarvation: true, starvationThresholdNs: 1_000_000,
                instrument: true
            ))
        }
        // Kernel-phase pre-wait spin: EAGAIN rate 78-84%; brief spin between
        // exchange and wait may dodge syscall when release lands in window.
        for ksp in [5, 10, 20] {
            v.append(.depthAdaptive(
                name: "INSTR depth K=2 sp=20 base=64 ksp=\(ksp)",
                spinTries: 20, pauseBase: 64, depthThreshold: 2,
                kernelSpinTries: ksp, instrument: true
            ))
        }
    }

    return v
}()

// Non-INSTR depth-K variants + ship-shape baselines.
let csDepthMain: [MutexVariant] = {
    var v: [MutexVariant] = []
    // K=2/K=4 × sp=40 base=128. K=1/K=8 dropped — within noise.
    for k: UInt32 in [2, 4] {
        v.append(.depthAdaptive(
            name: "depth K=\(k) sp=40 base=128",
            spinTries: 40, pauseBase: 128, depthThreshold: k
        ))
    }
    // Jitter-off variants: gate may make RDTSC jitter redundant.
    for k: UInt32 in [2, 4] {
        v.append(.depthAdaptive(
            name: "depth K=\(k) sp=40 base=128 no-jitter",
            spinTries: 40, pauseBase: 128, depthThreshold: k,
            useJitter: false
        ))
    }
    // Spin-budget sweep at K=2 base=128 (AMD knee).
    for sp in [30, 50, 60] {
        v.append(.depthAdaptive(
            name: "depth K=2 sp=\(sp) base=128",
            spinTries: sp, pauseBase: 128, depthThreshold: 2
        ))
    }
    return v
}()
#endif

let benchmarks: @Sendable () -> Void = {
    BenchEnv.applyDefaultConfig(
        warmupIterations: BenchEnv.focus ? 5 : 25,
        maxDurationSecs: BenchEnv.maxSecs(default: 15),
        maxIterations: BenchEnv.focus ? 50 : 250
    )

    for cfg in configs {
        // Main variants.
        var mains: [MutexVariant] = []
        if !BenchEnv.focus {
            mains.append(.syncMutex())
            mains.append(.niolock())
        }
        #if os(Linux)
        if BenchEnv.copy { mains.append(.syncMutexCopy()) }
        mains.append(.optimal())
        mains.append(.rustMutex())
        mains.append(.rustStdMutex())
        mains.append(.parkingLot())
        #endif

        for v in mains {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    h.runLocked { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }

        #if os(Linux)
        // INSTR sweep at tasks≥64 — counter dumps reveal gate-fire %, futex
        // wait/wake under scheduler thrash.
        if cfg.tasks >= 32 {
            for v in csInstrSweep {
                Benchmark("\(cfg.label) \(v.name)") { benchmark in
                    let h = v.make(defaultMapCapacity)
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        h.runLocked { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                    h.dumpStats?("\(v.name.replacingOccurrences(of: "INSTR ", with: "")) \(cfg.label)")
                }
            }
        }

        if !BenchEnv.focus {
            for v in csDepthMain {
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

        if !BenchEnv.focus {
            let hw128 = MutexVariant.plainFutex(
                name: "hw128 sp=40",
                spinTries: 40, earlyExitOnWaiters: true,
                backoffCap: 128, useHWJitter: true
            )
            Benchmark("\(cfg.label) \(hw128.name)") { benchmark in
                let h = hw128.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    h.runLocked { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }

        if BenchEnv.slow {
            let v = MutexVariant.pthreadAdaptive()
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    h.runLocked { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif
    }
}
