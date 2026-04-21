import Benchmark
import Foundation
import MutexBench

// 2 = folly/abseil minimum symmetric contention point.
// 192, 384 = Go-style oversubscription (4×, 8× on a 48C EPYC).
// https://github.com/golang/go/blob/master/src/sync/mutex_test.go
let runFocus = ProcessInfo.processInfo.environment["MUTEX_BENCH_FOCUS"] == "1"
let configs: [BenchConfig] = {
    let ts = runFocus ? [1, 8, 64, 96, 192, 384] : [1, 2, 4, 8, 16, 64, 96, 192, 384]
    return ts.map { BenchConfig(tasks: $0, work: 1) }
}()

// Set MUTEX_BENCH_MAX_SECS=1 for a quick smoke run across all configs.
let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? (runFocus ? 5 : 15)

// pthread_adaptive_np gated — it tracks NIOLock closely on most workloads,
// provides low differential signal per run. Set MUTEX_BENCH_SLOW=1 to include.
let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"

// Synchronization.Mutex (copy) gated — the faithful stdlib copy tracks the
// real stdlib Mutex within noise, so it's redundant on most runs. Set
// MUTEX_BENCH_COPY=1 to include (e.g. when validating a stdlib change).
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: runFocus ? 5 : 25,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: runFocus ? 50 : 250
    )

    for cfg in configs {
        if !runFocus {
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
        } // !runFocus

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

        // PI no-spin: 100x slower than all other variants on every machine.
        // Sanity baseline — kernel priority-inheritance path without userspace spin.
        // Re-enable only when validating PI stdlib changes.
        //
        // Benchmark("\(cfg.label) PI no-spin") { benchmark in
        //     let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity), spinTries: 0)
        //     ...
        // }

        // PlainFutexMutex (spin=100), plain spin=14 backoff, plain spin=40 fixed:
        // all pre-depth variants dominated by hw128 sp=40 everywhere. No new signal.
        // Re-enable if re-tuning PlainFutexMutex defaults.
        //
        // Benchmark("\(cfg.label) PlainFutexMutex (spin=100)") { ... spinTries: 100 }
        // Benchmark("\(cfg.label) plain spin=14 backoff") { ... spinTries: 14, useBackoff: true }
        // Benchmark("\(cfg.label) plain spin=40 fixed") { ... spinTries: 40 }

        Benchmark("\(cfg.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // INSTR Optimal at saturation + oversubscription — counter dumps
        // reveal gate-fire %, futex wait/wake counts under scheduler thrash,
        // whether spinBudgetExhausted comes back at t≥core_count regimes.
        if cfg.tasks >= 64 {
            Benchmark("\(cfg.label) INSTR Optimal") { benchmark in
                let m = OptimalMutex(MapState(capacity: defaultMapCapacity), instrument: true)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
                m.stats?.dump(label: "Optimal \(cfg.label)")
            }

            if !runFocus {
            // INSTR sweep — shorter spin and shorter pauses via DepthAdaptiveMutex
            // (parameterized cousin with same algorithm shape as Optimal).
            // Probes whether gate alone carries the load when budget shrinks.
            // (sp, base) combinations: budget = sp * (base avg pauses) ≈ wallclock cost.
            //   sp=20 base=64  ≈   ~6µs Alder Lake / ~3µs AMD Zen 4
            //   sp=10 base=64  ≈   ~3µs
            //   sp=10 base=32  ≈ ~1.5µs (probably too tight — stress test)
            //   sp=5  base=64  ≈ ~1.5µs (alternate shape — wider pause, fewer iters)
            for (sp, base) in [(20, UInt32(64)), (10, UInt32(64)), (10, UInt32(32)), (5, UInt32(64))] {
                Benchmark("\(cfg.label) INSTR depth K=2 sp=\(sp) base=\(base)") { benchmark in
                    let m = DepthAdaptiveMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: sp, pauseBase: base, depthThreshold: 2,
                        instrument: true
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                    m.stats?.dump(label: "depth K=2 sp=\(sp) base=\(base) \(cfg.label)")
                }
            }

            // K-axis sweep: tighter gate (K=1) → smaller spinner pool →
            // each spinner faces less coherence traffic + higher per-spinner
            // catch rate (~1/N scaling). Tests if K-axis has more headroom
            // than sp-axis. Pair K=1 with the same short-budget configs.
            for sp in [20, 10, 5] {
                Benchmark("\(cfg.label) INSTR depth K=1 sp=\(sp) base=64") { benchmark in
                    let m = DepthAdaptiveMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: sp, pauseBase: 64, depthThreshold: 1,
                        instrument: true
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                    m.stats?.dump(label: "depth K=1 sp=\(sp) base=64 \(cfg.label)")
                }
            }

            // Post-wake load-only spin. Targets wake-then-lose-to-barger
            // amplification (5-8× W/P on arnold; 1.7× on bigdata). After
            // futex_wait wake, scan word for release instead of immediately
            // re-exchanging. Only the woken thread spins — not a parallel
            // herd like the abandoned kernelSpinTries. Default sp=20 base=64.
            for pws in [10, 40, 100] {
                Benchmark("\(cfg.label) INSTR depth K=2 sp=20 base=64 pws=\(pws)") { benchmark in
                    let m = DepthAdaptiveMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: 20, pauseBase: 64, depthThreshold: 2,
                        postWakeSpinTries: pws, instrument: true
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                    m.stats?.dump(label: "depth K=2 sp=20 base=64 pws=\(pws) \(cfg.label)")
                }
            }
            } // !runFocus — K=2/K=1/pws sweeps

            // Go-style starvation mode at 1ms (Go default, our ship candidate).
            Benchmark("\(cfg.label) INSTR depth K=2 sp=20 base=64 starv=1ms") { benchmark in
                let m = DepthAdaptiveMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 20, pauseBase: 64, depthThreshold: 2,
                    useStarvation: true, starvationThresholdNs: 1_000_000,
                    instrument: true
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
                m.stats?.dump(label: "depth K=2 sp=20 base=64 starv=1ms \(cfg.label)")
            }

            // Reduced-spin with starvation safety net. Test if fewer
            // iterations (sp=3/5/10) tie or beat sp=20 when starvation
            // bounds tail. Less spin = quieter coherence + less CPU waste.
            if !runFocus {
            for sp in [3, 5, 10] {
                Benchmark("\(cfg.label) INSTR depth K=2 sp=\(sp) base=64 starv=1ms") { benchmark in
                    let m = DepthAdaptiveMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: sp, pauseBase: 64, depthThreshold: 2,
                        useStarvation: true, starvationThresholdNs: 1_000_000,
                        instrument: true
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                    m.stats?.dump(label: "depth K=2 sp=\(sp) base=64 starv=1ms \(cfg.label)")
                }
            }
            } // !runFocus — sp sweep

            if !runFocus {
            // Kernel-phase pre-wait spin (Linux kernel mutex pattern).
            // EAGAIN rate is 78-84% across machines — most futex_wait calls
            // return immediately because word changed mid-syscall. Brief
            // spin between exchange and wait dodges the syscall when the
            // release happens in that window. Pair with default sp=20 base=64.
            for ksp in [5, 10, 20] {
                Benchmark("\(cfg.label) INSTR depth K=2 sp=20 base=64 ksp=\(ksp)") { benchmark in
                    let m = DepthAdaptiveMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: 20, pauseBase: 64, depthThreshold: 2,
                        kernelSpinTries: ksp, instrument: true
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                    m.stats?.dump(label: "depth K=2 sp=20 base=64 ksp=\(ksp) \(cfg.label)")
                }
            }
            } // !runFocus — ksp sweep
        }

        // hw64 sp=20, hw128 sp=20: earlier cliff-containment sweeps.
        // hw128 sp=40 beats both on every machine. Dropped to reduce noise.
        //
        // Benchmark("\(cfg.label) hw64 sp=20") { ... backoffCap: 64, spinTries: 20 }
        // Benchmark("\(cfg.label) hw128 sp=20") { ... backoffCap: 128, spinTries: 20 }

        if !runFocus {
        // DepthAdaptiveMutex: single-word futex + adjacent waiter counter.
        // Skip spin if state==2 AND parkers >= threshold.
        // K=1/K=8 dropped — arnold/40c/64c show K choice within noise at all t.
        for k: UInt32 in [2, 4] {
            Benchmark("\(cfg.label) depth K=\(k) sp=40 base=128") { benchmark in
                let m = DepthAdaptiveMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 40, pauseBase: 128, depthThreshold: k
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }

        // Budget-reduced depth variants (~240µs vs 476µs sp=40 base=128):
        //   sp=20 base=128: arnold +1%, 40c +3%, 64c AMD +25% @ t=8
        //   sp=40 base=64:  arnold +5%, 40c +45%, 64c AMD +203% @ t=8
        // base=64 catastrophic on AMD — CCX inter-core latency needs longer pause.
        // Conclusion: sp=40 base=128 is the floor. Re-enable only to re-test on new hardware.
        //
        // for k: UInt32 in [2, 4] {
        //     Benchmark("... depth K=\(k) sp=20 base=128") { ... }
        //     Benchmark("... depth K=\(k) sp=40 base=64")  { ... }
        // }

        // Jitter-off variants: does gate make RDTSC jitter redundant?
        // Pre-cliff (t=2-7) may regress; post-cliff gate caps active spinners.
        for k: UInt32 in [2, 4] {
            Benchmark("\(cfg.label) depth K=\(k) sp=40 base=128 no-jitter") { benchmark in
                let m = DepthAdaptiveMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 40, pauseBase: 128, depthThreshold: k, useJitter: false
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }

        // Spin-budget sweep at K=2 base=128 to find AMD knee.
        // sp=20 regressed AMD +25% @ t=8; sp=40 is current default.
        // Question: is sp=40 the floor, or has slack we can trim?
        for sp in [30, 50, 60] {
            Benchmark("\(cfg.label) depth K=2 sp=\(sp) base=128") { benchmark in
                let m = DepthAdaptiveMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: sp, pauseBase: 128, depthThreshold: 2
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
        } // !runFocus — depth K=2/K=4 + no-jitter + spin-budget sweep

        // MCS: design mismatch for ns-scale CS. 100x slow across all 5 rewrites.
        // Chain handoff works; MCS just pays 3x cache-line traffic vs single-word NIOLock,
        // and non-head spinners gain nothing from local spin (blocked on head, not release).
        // Keep one variant as reference behind runSlow to verify design mismatch isn't machine-specific.
        if runSlow {
            Benchmark("\(cfg.label) MCS sp=40 base=64") { benchmark in
                let m = MCSMutex(MapState(capacity: defaultMapCapacity), spinTries: 40, pauseBase: 64)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
        // MCS sp=10 base=64 dropped — identical verdict, no extra signal.
        // Benchmark("\(cfg.label) MCS sp=10 base=64") { ... spinTries: 10, pauseBase: 64 }

        // CLH: predecessor-spin queue lock. No `next` pointer, no unlock-wait-for-link
        // preemption gap (MCSMutex §2). Pure single-state-word node + futex park.
        // Compare directly against MCS at same spin/pause budget.
        if !runFocus {
        Benchmark("\(cfg.label) CLH sp=40 base=64") { benchmark in
            let m = CLHMutex(MapState(capacity: defaultMapCapacity), spinTries: 40, pauseBase: 64)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) hw128 sp=40") { benchmark in
            let m = PlainFutexMutex(
                MapState(capacity: defaultMapCapacity),
                spinTries: 40, earlyExitOnWaiters: true,
                useBackoff: false, backoffCap: 128, useHWJitter: true
            )
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }
        } // !runFocus — depth K=2/K=4 + no-jitter + spin-budget + CLH + hw128

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
}
