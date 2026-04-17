import Benchmark
import Foundation
import MutexBench
#if os(Linux)
import CFutexShims
#endif

let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 15

// Sweep spin strategies at fixed high-contention points.
//
// Previous results:
//   - Backoff essential on 12-core (fixed spin regresses)
//   - cap=32 too coarse for long hold times
//   - PI no-spin: 10× worse than plain futex park (PI syscall is the cost)
//
// This round: test backoff cap=8 (new default, Rust-style) vs cap=32 (old).

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: 25,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: 250
    )

    for tasks in [1, 2, 4, 8, 16, 64, 192] {
        let cfg = BenchConfig(tasks: tasks, work: 1)

        // Baselines
        Benchmark("tasks=\(tasks) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) { box.work(cfg.work) }
            benchmark.stopMeasurement()
        }

        Benchmark("tasks=\(tasks) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) { box.work(cfg.work) }
            benchmark.stopMeasurement()
        }

        #if os(Linux)
        // The recommended algorithm — hardcoded winner config.
        Benchmark("tasks=\(tasks) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // PI-futex with no spinning — isolates PI syscall overhead
        Benchmark("tasks=\(tasks) PI no-spin") { benchmark in
            let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity), spinTries: 0)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Plain futex, park immediately
        Benchmark("tasks=\(tasks) spin=0") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 0)
            benchmark.startMeasurement()
            await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        // Fixed spin
        for spin in [14, 40] {
            Benchmark("tasks=\(tasks) spin=\(spin) fixed") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }

        // Backoff with different caps
        for spin in [14, 40] {
            // cap=8 (Rust-style)
            Benchmark("tasks=\(tasks) spin=\(spin) backoff cap=8") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    backoffCap: 8
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // cap=32 (previous)
            Benchmark("tasks=\(tasks) spin=\(spin) backoff cap=32") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    backoffCap: 32
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Adaptive cap: 256/nproc, clamped [4,32]
            Benchmark("tasks=\(tasks) spin=\(spin) backoff adaptive") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    backoffCap: adaptive_backoff_cap()
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Adaptive + separate cache line (lock word and value on different 64B lines)
            Benchmark("tasks=\(tasks) spin=\(spin) backoff adaptive+sep") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    backoffCap: adaptive_backoff_cap(),
                    separateCacheLine: true
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Regime-gated cap: cap flips based on observed state each iter.
            //   state==1 (no waiters parked)       → capHigh=32 (long backoff)
            //   state==2 (waiters parked / busy)   → capLow=6   (tight checks)
            // Confirmed winner on 12c+40c+64c (see project_findings_40c.md).
            Benchmark("tasks=\(tasks) spin=\(spin) regime-gated") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    regimeGatedCap: true,
                    capHigh: 32,
                    capLow: 6
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Regime-gated + separateCacheLine (lock word and value on
            // different 64B lines). §10 showed separation helps 17-22% on
            // 12c single-die Intel but is neutral/negative on 64c EPYC
            // chiplet (Infinity Fabric penalty). Question: does the regime-
            // gated win stack additively with separation on 12c, and does
            // 64c's chiplet penalty still dominate here?
            Benchmark("tasks=\(tasks) spin=\(spin) regime-gated+sep") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    separateCacheLine: true,
                    regimeGatedCap: true,
                    capHigh: 32,
                    capLow: 6
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Regime-gated + backoff floor=4: hypothesis for closing the
            // 64c state==2 chiplet gap. Starting backoff at 4 instead of 1
            // skips tight early iterations that on EPYC cause cross-CCD
            // cache-line traffic before any release can arrive. capLow=6
            // stays the ceiling for state==2 regime.
            Benchmark("tasks=\(tasks) spin=\(spin) regime-gated floor=4") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    regimeGatedCap: true,
                    capHigh: 32,
                    capLow: 6,
                    backoffFloor: 4
                )
                benchmark.startMeasurement()
                await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }

            // Regime-gated + sticky parked-regime detection.
            // Addresses the Phase B cache-traffic cost the base regime-gated
            // still pays: once state==2 has been stable for N iterations,
            // bail to futex_wait rather than keep polling the hot shared
            // line. Also jump backoff to capLow on state==2 entry to avoid
            // ramping up from lower values in a regime about to terminate.
            // Expected to help 64c tasks≥16 and 40c tasks=64 (the residual
            // gaps where plain regime-gated shows cache-pressure symptoms).
            for threshold: UInt32 in [3, 5] {
                Benchmark("tasks=\(tasks) spin=\(spin) regime-gated sticky=\(threshold)") { benchmark in
                    let m = PlainFutexMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: spin,
                        useBackoff: true,
                        regimeGatedCap: true,
                        capHigh: 32,
                        capLow: 6,
                        stickyParkThreshold: threshold
                    )
                    benchmark.startMeasurement()
                    await runWorkload(tasks: cfg.tasks, acquiresPerTask: cfg.acquiresPerTask) {
                        m.withLock { $0.update(iterations: cfg.work) }
                    }
                    benchmark.stopMeasurement()
                }
            }

            // Sticky + floor=4 stacked.
            Benchmark("tasks=\(tasks) spin=\(spin) regime-gated sticky=3 floor=4") { benchmark in
                let m = PlainFutexMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: spin,
                    useBackoff: true,
                    regimeGatedCap: true,
                    capHigh: 32,
                    capLow: 6,
                    backoffFloor: 4,
                    stickyParkThreshold: 3
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
}
