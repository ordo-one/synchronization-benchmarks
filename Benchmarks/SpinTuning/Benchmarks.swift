import Benchmark
import Foundation
import MutexBench
#if os(Linux)
import CFutexShims
#endif

let runFocus = ProcessInfo.processInfo.environment["MUTEX_BENCH_FOCUS"] == "1"
let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? (runFocus ? 5 : 15)

// Default suite: Optimal + RustMutex + NIO + Stdlib + a small set of best
// variations. Set MUTEX_BENCH_EXPERIMENT=1 to enable the full exploration
// matrix (budget sweeps, adaptive/two-stage/epoch/hint variants, historical
// reference points).
let runExperiment = ProcessInfo.processInfo.environment["MUTEX_BENCH_EXPERIMENT"] == "1"

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: runFocus ? 5 : 25,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: runFocus ? 50 : 250
    )

    let taskList = runFocus ? [8, 16, 64, 192] : [1, 2, 4, 8, 16, 64, 192]
    for tasks in taskList {
        let cfg = BenchConfig(tasks: tasks, work: 1)

        // ---- Baselines ----

        if !runFocus {
        Benchmark("tasks=\(tasks) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) { box.work(cfg.work) }
            benchmark.stopMeasurement()
        }
        } // !runFocus

        #if os(Linux)

        // ---- Proposed replacement + Rust-style reference ----

        // Current shipped winner: depth-adaptive gate + in-spin CAS + RDTSC jitter.
        Benchmark("tasks=\(tasks) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        if !runFocus {
        // Like-for-like Rust std::sync::Mutex: 100-iter load-only spin, post-spin
        // CAS + kernel swap, re-spin after wake. No jitter, no depth gate.
        Benchmark("tasks=\(tasks) RustMutex") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Tuned RustMutex variants: same structure, bigger budget to match
        // pthread park cost (10-30µs wake). Two tuning axes:
        //   A. More iterations × 1 PAUSE (more loads, same ~35ns spacing)
        //   B. Same iterations × more PAUSE (same load count, wider spacing)
        // Axis A keeps Rust's load frequency; axis B keeps Rust's load count.

        // A1: 500 × 1 PAUSE = ~17µs Skylake, ~7µs Alder Lake
        Benchmark("tasks=\(tasks) RustMutex sp=500 × 1") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity), spinTries: 500, pausesPerIter: 1)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // A2: 1000 × 1 PAUSE = ~35µs Skylake, ~14µs Alder Lake
        Benchmark("tasks=\(tasks) RustMutex sp=1000 × 1") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity), spinTries: 1000, pausesPerIter: 1)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // B1: 100 × 16 PAUSE = ~56µs Skylake, load spacing ~560ns (close to Optimal's 700ns)
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 16") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity), spinTries: 100, pausesPerIter: 16)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // B2: 100 × 32 PAUSE = ~112µs Skylake, load spacing ~1.1µs (wider than Optimal)
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 32") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity), spinTries: 100, pausesPerIter: 32)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // C: middle ground — 40 iter × 32 PAUSE = ~45µs Skylake, load spacing ~1.1µs
        Benchmark("tasks=\(tasks) RustMutex sp=40 × 32") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity), spinTries: 40, pausesPerIter: 32)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Retry axis: load-only main spin, then N extra load-gated CAS
        // attempts with pauses between, before parking. Hybrid between
        // Rust's load-only and Optimal's in-spin CAS — gives losers another
        // chance to catch subsequent release events within budget.
        // Kept at base Rust spin=100×1 so retry is the only variable.

        Benchmark("tasks=\(tasks) RustMutex sp=100 × 1 retry=5") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 1, outerRetries: 5)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("tasks=\(tasks) RustMutex sp=100 × 1 retry=20") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 1, outerRetries: 20)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Combined: wider spacing (100×16) + retry=20. Approaches Optimal's
        // total attempt count while keeping Rust's load-only main spin.
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 16 retry=20") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 16, outerRetries: 20)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Bounded-retrier experiment: cap simultaneous CAS retriers.
        // limit=N means up to N threads enter retry loop concurrently; others
        // either park (default) or keep load-only spinning (spinIfLimited).
        // Tested with sweet-spot 100×8 retry=5 budget from earlier runs.

        // Limit=1, overflow parks: should match pure Rust (overflow parks anyway).
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 8 retry=5 limit=1 park") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 8, outerRetries: 5,
                              retrierLimit: 1, spinIfLimited: false)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Limit=1, overflow spins: classic "many loaders, 1 racer" shape.
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 8 retry=5 limit=1 spin") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 8, outerRetries: 5,
                              retrierLimit: 1, spinIfLimited: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Limit=2, overflow spins: match cpu/wall=2 pattern.
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 8 retry=5 limit=2 spin") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 8, outerRetries: 5,
                              retrierLimit: 2, spinIfLimited: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Limit=4, overflow spins: middle ground.
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 8 retry=5 limit=4 spin") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 8, outerRetries: 5,
                              retrierLimit: 4, spinIfLimited: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Depth-adaptive gate (OptimalMutex #8) grafted onto Rust-style spin.
        // K=4 parkers-in-kernel threshold. Tests whether the gate closes the
        // p99 tail without the pause-spacing and in-spin CAS changes.

        // Gate on top of upstream Rust defaults (100 × 1, no retry).
        Benchmark("tasks=\(tasks) RustMutex gate=4") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity), depthThreshold: 4)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Gate + wider pause spacing (B1 winner shape, closer to Optimal).
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 16 gate=4") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 16, depthThreshold: 4)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Gate + widest variant: wider spacing + retries (matches Optimal's
        // attempt budget, keeps Rust's load-only main spin).
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 16 retry=20 gate=4") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 16, outerRetries: 20,
                              depthThreshold: 4)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // ---- Stuck-at-2 fixes: demote word 2→1 when last parker leaves ----

        // Demote only: addresses the "word stuck at 2" cascade. Expect
        // fast-path rate to climb toward Optimal's 99%.
        Benchmark("tasks=\(tasks) RustMutex demote") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              demoteOnEmpty: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Demote + skipSpuriousWake: also skip FUTEX_WAKE when parkers==0.
        // Complementary — demote reduces the stuck-at-2 window; skipWake
        // catches the residual spurious wakes inside that window.
        Benchmark("tasks=\(tasks) RustMutex demote+skipWake") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              skipSpuriousWake: true, demoteOnEmpty: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Both fixes + wider pause spacing (best Rust-shape combo).
        Benchmark("tasks=\(tasks) RustMutex sp=100 × 16 demote+skipWake") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity),
                              spinTries: 100, pausesPerIter: 16,
                              skipSpuriousWake: true, demoteOnEmpty: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        } // !runFocus — Rust variants, gate/retry/demote/skipWake sweeps

        // ---- Instrumented runs (t=8 and t=16, stats dumped to stderr) ----

        if tasks == 8 || tasks == 16 {
            // OptimalMutex counters — in-spin CAS wins, gate hits, kernel entries.
            Benchmark("tasks=\(tasks) INSTR Optimal") { benchmark in
                let m = OptimalMutex(MapState(capacity: defaultMapCapacity), instrument: true)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
                m.stats?.dump(label: "Optimal t=\(tasks)")
            }

            if !runFocus {
            // RustMutex counters — post-spin CAS wins/losses, kernel entries.
            Benchmark("tasks=\(tasks) INSTR RustMutex") { benchmark in
                let m = RustMutex(MapState(capacity: defaultMapCapacity), instrument: true)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
                m.stats?.dump(label: "RustMutex t=\(tasks)")
            }

            // Best Rust-tuned variant (sp=100×16 retry=20) for comparison.
            Benchmark("tasks=\(tasks) INSTR RustMutex sp=100 × 16 retry=20") { benchmark in
                let m = RustMutex(MapState(capacity: defaultMapCapacity),
                                  spinTries: 100, pausesPerIter: 16, outerRetries: 20,
                                  instrument: true)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
                m.stats?.dump(label: "RustMutex sp=100x16 retry=20 t=\(tasks)")
            }

            // Stuck-at-2 fix counters: should show fast-path climb, fewer
            // kernelPhaseEntries, demoteWonEmpty > 0, futexWakeSuppressed > 0.
            Benchmark("tasks=\(tasks) INSTR RustMutex demote+skipWake") { benchmark in
                let m = RustMutex(MapState(capacity: defaultMapCapacity),
                                  skipSpuriousWake: true, demoteOnEmpty: true,
                                  instrument: true)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
                m.stats?.dump(label: "RustMutex demote+skipWake t=\(tasks)")
            }
            } // !runFocus — INSTR Rust variants

            // Ship candidate: OptimalMutex shape + Go-style starvation at
            // 1ms. Validates starvation+gate don't regress the symmetric
            // low-tasks regime where plain Optimal already dominates 5-6×.
            // Direct comparison with "INSTR Optimal" row above.
            Benchmark("tasks=\(tasks) INSTR depth K=4 sp=20 base=64 starv=1ms") { benchmark in
                let m = DepthAdaptiveMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 20, pauseBase: 64, depthThreshold: 4,
                    useStarvation: true, starvationThresholdNs: 1_000_000,
                    instrument: true
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
                m.stats?.dump(label: "depth K=4 sp=20 base=64 starv=1ms t=\(tasks)")
            }
        }

        // ---- Best variations (retained in default suite for comparison) ----

        if !runFocus {
        // sp=40 hwjitter base=128: the pre-depth-gate winner. Flat pauses with
        // RDTSC jitter, in-spin CAS, no gate. Matches hw128 sp=40 from the
        // cross-machine sweep.
        Benchmark("tasks=\(tasks) best: sp=40 hwjitter base=128") { benchmark in
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

        // sp=20 hwjitter base=128: half-budget version, tied with sp=40 on
        // arnold (within 1-2%). Useful cross-machine comparison for budget
        // sensitivity.
        Benchmark("tasks=\(tasks) best: sp=20 hwjitter base=128") { benchmark in
            let m = PlainFutexMutex(
                MapState(capacity: defaultMapCapacity),
                spinTries: 20, earlyExitOnWaiters: true,
                useBackoff: false, backoffCap: 128, useHWJitter: true
            )
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // AdaptiveSpinMutex cap=100 base=128: unexpectedly tight p99 at t=8
        // on arnold (1,530µs vs sp=40's 2,073µs). EWMA-learned budget.
        // Kept for cross-machine validation.
        Benchmark("tasks=\(tasks) best: adaptive cap=100 base=128") { benchmark in
            let m = AdaptiveSpinMutex(MapState(capacity: defaultMapCapacity), maxCap: 100, pauseBase: 128)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }
        } // !runFocus — best variations

        // ---- Experimental sweep (set MUTEX_BENCH_EXPERIMENT=1) ----

        if runExperiment {
            // Stdlib PI-futex baseline — 10-43× worse than plain futex on every machine.
            Benchmark("tasks=\(tasks) EXP Synchronization.Mutex") { benchmark in
                let box = SyncMutexBox(capacity: defaultMapCapacity)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) { box.work(cfg.work) }
                benchmark.stopMeasurement()
            }

            // PI-futex isolation.
            Benchmark("tasks=\(tasks) EXP PI no-spin") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity), spinTries: 0)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Reference points: park immediately, fixed spin counts.
            Benchmark("tasks=\(tasks) EXP spin=0") { benchmark in
                let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 0)
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            for spin in [14, 40] {
                Benchmark("tasks=\(tasks) EXP spin=\(spin) fixed") { benchmark in
                    let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: spin)
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                }
            }

            // glibc-style exp backoff + jitter (pre-depth-gate Optimal).
            Benchmark("tasks=\(tasks) EXP early-exit spin=40 jitter") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 40, earlyExitOnWaiters: true,
                    useBackoff: true, backoffCap: 32, backoffFloor: 4,
                    useJitter: true
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Reduced iterations with high base.
            for spins in [3, 5, 10] {
                Benchmark("tasks=\(tasks) EXP early-exit spin=\(spins) hwjitter base=128") { benchmark in
                    let m = PlainFutexMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: spins, earlyExitOnWaiters: true,
                        useBackoff: false, backoffCap: 128, useHWJitter: true
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                }
            }

            // sp=20 base=64 (tighter spacing variant).
            Benchmark("tasks=\(tasks) EXP early-exit spin=20 hwjitter base=64") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 20, earlyExitOnWaiters: true,
                    useBackoff: false, backoffCap: 64, useHWJitter: true
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Flat + HW jitter base sweep: find optimal polling interval.
            for base: UInt32 in [16, 32, 64, 96, 128] {
                let isPow2 = base & (base - 1) == 0
                if isPow2 {
                    Benchmark("tasks=\(tasks) EXP early-exit spin=40 hwjitter base=\(base)") { benchmark in
                        let m = PlainFutexMutex(
                            MapState(capacity: defaultMapCapacity),
                            spinTries: 40, earlyExitOnWaiters: true,
                            useBackoff: false, backoffCap: base, useHWJitter: true
                        )
                        benchmark.startMeasurement()
                        await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                            m.withLock { $0.update(iterations: cfg.work) }
                        }
                        benchmark.stopMeasurement()
                    }
                }
                Benchmark("tasks=\(tasks) EXP early-exit spin=40 flat\(base)") { benchmark in
                    let m = PlainFutexMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: 40, earlyExitOnWaiters: true,
                        useBackoff: true, backoffCap: base, backoffFloor: base
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                }
            }

            // AdaptiveSpinMutex cap × base grid (the tight p99 outlier is in "best" above).
            for (cap, base): (UInt32, UInt32) in [
                (10, 64), (10, 128),
                (20, 64), (20, 128),
                (40, 64), (40, 128),
                (100, 64),
            ] {
                Benchmark("tasks=\(tasks) EXP adaptive cap=\(cap) base=\(base)") { benchmark in
                    let m = AdaptiveSpinMutex(MapState(capacity: defaultMapCapacity), maxCap: cap, pauseBase: base)
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                }
            }

            // TwoStage, Epoch, Hint — all characterized, none beat Optimal.
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
            Benchmark("tasks=\(tasks) EXP early-exit spin=40 hwjitter64+sep") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 40, earlyExitOnWaiters: true,
                    useBackoff: false, backoffCap: 64,
                    separateCacheLine: true, useHWJitter: true
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif
    }

    // ---- t=32 OptimalMutex INSTR (standalone — 32 not in main loop) ----
    #if os(Linux)
    do {
        let cfg = BenchConfig(tasks: 32, work: 1)
        Benchmark("tasks=32 INSTR Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity), instrument: true)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
            m.stats?.dump(label: "Optimal t=32")
        }
    }
    #endif
}
