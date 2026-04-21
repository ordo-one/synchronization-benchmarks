import Benchmark
import Foundation
import Histogram
import MutexBench
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#endif

let runFocus = ProcessInfo.processInfo.environment["MUTEX_BENCH_FOCUS"] == "1"
let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? (runFocus ? 5 : 30)

// Producer + consumer asymmetric workload.
//
// Shape: 1 producer holds the lock for a long critical section (work=1024).
// N consumers acquire briefly (work=1). Fairness-sensitive: a starving
// consumer will see long tails even if aggregate throughput looks healthy.
//
// Reports per-consumer wait-time HDR histogram (p50/p90/p99/p999/max) via
// stderr in addition to the normal throughput metric. Compare:
//   - abseil BM_MutexEnqueue (1 producer, N consumers, dequeue pattern):
//     https://github.com/abseil/abseil-cpp/blob/master/absl/synchronization/mutex_benchmark.cc
//   - folly uncontended-alternating / DistributedMutex asymmetric tests:
//     https://github.com/facebook/folly/blob/main/folly/synchronization/test/SmallLocksBenchmark.cpp

struct AsymConfig: Sendable {
    let consumers: Int
    let producerWork: Int
    let consumerWork: Int
    // Consumer sleeps this many µs before each acquire attempt, giving the
    // producer clear runway. 0 = consumers always compete (original behavior).
    // Adapted from https://github.com/cuongleqq/mutex-benches Hog scenario
    // (nonhog_backoff_us=300).
    let consumerBackoffUs: UInt32
    var label: String {
        let b = consumerBackoffUs > 0 ? " backoff=\(consumerBackoffUs)µs" : ""
        return "consumers=\(consumers) producer=\(producerWork) consumer=\(consumerWork)\(b)"
    }
    var acquiresPerConsumer: Int { defaultTotalAcquires / consumers }
    var producerAcquires: Int { defaultTotalAcquires / 10 } // produce ~10% as many ops
}

let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"
let runExperiment = ProcessInfo.processInfo.environment["MUTEX_BENCH_EXPERIMENT"] == "1"

let asymConfigsFast: [AsymConfig] = {
    var cs = [15, 24, 32, 63, 91, 127]
    if !runFocus { cs.append(255) }
    return cs.map { .init(consumers: $0, producerWork: 256, consumerWork: 1, consumerBackoffUs: 0) }
}()

let asymConfigsSlow: [AsymConfig] = [
    // Producer holds 2.4 ms per acquire; iter ≈ 12 s. Gated.
    .init(consumers: 15, producerWork: 1024, consumerWork: 1, consumerBackoffUs: 0),
    .init(consumers: 63, producerWork: 1024, consumerWork: 1, consumerBackoffUs: 0),
]

let asymConfigs = asymConfigsFast + (runSlow ? asymConfigsSlow : [])

@inline(__always)
func asymWorkload(
    consumers: Int,
    producerAcquires: Int,
    consumerAcquires: Int,
    producerWork: Int,
    consumerWork: Int,
    consumerBackoffUs: UInt32,
    acquireAndRun: @Sendable @escaping (Int, () -> Void) -> Void
) async -> [Histogram<UInt64>] {
    return await withTaskGroup(of: Histogram<UInt64>?.self, returning: [Histogram<UInt64>].self) { group in
        let gate = SyncedStart()

        // Producer — long hold. No histogram.
        group.addTask {
            await gate.waitForStart()
            for _ in 0..<producerAcquires {
                acquireAndRun(producerWork, {})
            }
            return nil
        }

        // Consumers — short hold, record wait.
        // onAcq captures t1 inside the locked region so hold time doesn't leak
        // into the wait histogram; h.record runs after the acquire returns.
        for _ in 0..<consumers {
            group.addTask {
                await gate.waitForStart()
                var h = makeLatencyHistogram()
                for _ in 0..<consumerAcquires {
                    if consumerBackoffUs > 0 { usleep(consumerBackoffUs) }
                    var t1: UInt64 = 0
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    acquireAndRun(consumerWork) {
                        t1 = DispatchTime.now().uptimeNanoseconds
                    }
                    _ = h.record(t1 &- t0)
                }
                return h
            }
        }

        var hists: [Histogram<UInt64>] = []
        for await h in group {
            if let h { hists.append(h) }
        }
        return hists
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: runFocus ? 3 : 5,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: runFocus ? 10 : 20
    )

    for cfg in asymConfigs {
        if !runFocus {
        Benchmark("\(cfg.label) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            let hists = await asymWorkload(
                consumers: cfg.consumers,
                producerAcquires: cfg.producerAcquires,
                consumerAcquires: cfg.acquiresPerConsumer,
                producerWork: cfg.producerWork,
                consumerWork: cfg.consumerWork,
                consumerBackoffUs: cfg.consumerBackoffUs
            ) { w, onAcq in box.m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) Synchronization.Mutex consumer-wait", merged)
        }

        Benchmark("\(cfg.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            let hists = await asymWorkload(
                consumers: cfg.consumers,
                producerAcquires: cfg.producerAcquires,
                consumerAcquires: cfg.acquiresPerConsumer,
                producerWork: cfg.producerWork,
                consumerWork: cfg.consumerWork,
                consumerBackoffUs: cfg.consumerBackoffUs
            ) { w, onAcq in box.box.withLockedValue { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) NIOLockedValueBox consumer-wait", merged)
        }
        } // !runFocus

        #if os(Linux)
        if runCopy {
            Benchmark("\(cfg.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) Synchronization.Mutex (copy) consumer-wait", merged)
            }
        }

        if !runFocus {
        Benchmark("\(cfg.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            let hists = await asymWorkload(
                consumers: cfg.consumers,
                producerAcquires: cfg.producerAcquires,
                consumerAcquires: cfg.acquiresPerConsumer,
                producerWork: cfg.producerWork,
                consumerWork: cfg.consumerWork,
                consumerBackoffUs: cfg.consumerBackoffUs
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) PlainFutexMutex (spin=100) consumer-wait", merged)
        }

        Benchmark("\(cfg.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            let hists = await asymWorkload(
                consumers: cfg.consumers,
                producerAcquires: cfg.producerAcquires,
                consumerAcquires: cfg.acquiresPerConsumer,
                producerWork: cfg.producerWork,
                consumerWork: cfg.consumerWork,
                consumerBackoffUs: cfg.consumerBackoffUs
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) plain spin=14 backoff consumer-wait", merged)
        }

        Benchmark("\(cfg.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            let hists = await asymWorkload(
                consumers: cfg.consumers,
                producerAcquires: cfg.producerAcquires,
                consumerAcquires: cfg.acquiresPerConsumer,
                producerWork: cfg.producerWork,
                consumerWork: cfg.consumerWork,
                consumerBackoffUs: cfg.consumerBackoffUs
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) plain spin=40 fixed consumer-wait", merged)
        }
        } // !runFocus

        Benchmark("\(cfg.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            let hists = await asymWorkload(
                consumers: cfg.consumers,
                producerAcquires: cfg.producerAcquires,
                consumerAcquires: cfg.acquiresPerConsumer,
                producerWork: cfg.producerWork,
                consumerWork: cfg.consumerWork,
                consumerBackoffUs: cfg.consumerBackoffUs
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) Optimal consumer-wait", merged)
        }

        // INSTR variants at under/at/over core-count regimes. Connect the
        // fairness histograms to mechanism counters: spinCASWon ratio,
        // kernelPhaseEntries, futexWakeCalls reveal WHY tail varies.
        // +20% wallclock overhead — compare INSTR-vs-INSTR only.
        if [15, 32, 63].contains(cfg.consumers) {
            Benchmark("\(cfg.label) INSTR Optimal") { benchmark in
                let m = OptimalMutex(MapState(capacity: defaultMapCapacity), instrument: true)
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) INSTR Optimal consumer-wait", merged)
                m.stats?.dump(label: "Optimal \(cfg.label)")
            }

            if !runFocus {
            Benchmark("\(cfg.label) INSTR RustMutex") { benchmark in
                let m = RustMutex(MapState(capacity: defaultMapCapacity), instrument: true)
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) INSTR RustMutex consumer-wait", merged)
                m.stats?.dump(label: "RustMutex \(cfg.label)")
            }

            // Optimal-shape with post-wake spin. Tests whether post-wake spin
            // reduces wake-then-lose-to-barger amplification (W/P ratio) and
            // tightens the max tail. pws=40 ≈ 40 pauses ≈ 1.4µs AMD / 1.7µs
            // Alder Lake — spans ~2 producer CS cycles.
            Benchmark("\(cfg.label) INSTR depth K=4 sp=20 pws=40") { benchmark in
                let m = DepthAdaptiveMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 20, pauseBase: 64, depthThreshold: 4,
                    postWakeSpinTries: 40, instrument: true
                )
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) INSTR depth K=4 sp=20 pws=40 consumer-wait", merged)
                m.stats?.dump(label: "depth K=4 sp=20 pws=40 \(cfg.label)")
            }
            } // !runFocus — INSTR RustMutex/pws

            // Go-style starvation mode. STARVING bit (0x4) latched by a
            // waiter whose wait exceeds threshold. Default 1ms matches Go.
            // Collapses wake-amp W/P 6-8× → ~1.1× on arnold at zero cost.
            // Doesn't help preempt-held-lock tails (plain-futex limitation).
            Benchmark("\(cfg.label) INSTR depth K=4 sp=20 starv=1ms") { benchmark in
                let m = DepthAdaptiveMutex(
                    MapState(capacity: defaultMapCapacity),
                    spinTries: 20, pauseBase: 64, depthThreshold: 4,
                    useStarvation: true, starvationThresholdNs: 1_000_000,
                    instrument: true
                )
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) INSTR depth K=4 sp=20 starv=1ms consumer-wait", merged)
                m.stats?.dump(label: "depth K=4 sp=20 starv=1ms \(cfg.label)")
            }

            // Reduced-spin sweep with starvation safety net. Starvation
            // bounds tail regardless of spin budget → spin becomes optional
            // optimization. Less spin = less coherency traffic + less CPU
            // waste. Test if sp=3/5/10 can tie or beat sp=20 wallclock.
            // base=64 is the portable floor (base=32 crashes arnold).
            if !runFocus {
            for sp in [3, 5, 10] {
                Benchmark("\(cfg.label) INSTR depth K=4 sp=\(sp) starv=1ms") { benchmark in
                    let m = DepthAdaptiveMutex(
                        MapState(capacity: defaultMapCapacity),
                        spinTries: sp, pauseBase: 64, depthThreshold: 4,
                        useStarvation: true, starvationThresholdNs: 1_000_000,
                        instrument: true
                    )
                    benchmark.startMeasurement()
                    let hists = await asymWorkload(
                        consumers: cfg.consumers,
                        producerAcquires: cfg.producerAcquires,
                        consumerAcquires: cfg.acquiresPerConsumer,
                        producerWork: cfg.producerWork,
                        consumerWork: cfg.consumerWork,
                        consumerBackoffUs: cfg.consumerBackoffUs
                    ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                    benchmark.stopMeasurement()
                    let merged = mergeHistograms(hists)
                    printLatencySummary("\(cfg.label) INSTR depth K=4 sp=\(sp) starv=1ms consumer-wait", merged)
                    m.stats?.dump(label: "depth K=4 sp=\(sp) starv=1ms \(cfg.label)")
                }
            }
            } // !runFocus — sp sweep
        }

        // RustMutex defaults (upstream Rust 1.62+ futex shape: 100-iter load-only
        // spin, post-spin CAS + kernel swap, re-spin after wake; no jitter, no gate).
        if !runFocus {
        Benchmark("\(cfg.label) RustMutex") { benchmark in
            let m = RustMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            let hists = await asymWorkload(
                consumers: cfg.consumers,
                producerAcquires: cfg.producerAcquires,
                consumerAcquires: cfg.acquiresPerConsumer,
                producerWork: cfg.producerWork,
                consumerWork: cfg.consumerWork,
                consumerBackoffUs: cfg.consumerBackoffUs
            ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
            benchmark.stopMeasurement()
            let merged = mergeHistograms(hists)
            printLatencySummary("\(cfg.label) RustMutex consumer-wait", merged)
        }
        } // !runFocus — RustMutex

        // CLH queue lock — FIFO fair by construction. Each acquirer links to its
        // predecessor and spins on predecessor's slot. Reveals whether queue
        // fairness is worth its coherency overhead on this workload.
        // Gated on MUTEX_BENCH_EXPERIMENT=1 — CLH costs 2.5-6× throughput for
        // its fairness bound, only useful for comparative analysis.
        if runExperiment {
            Benchmark("\(cfg.label) CLH") { benchmark in
                let m = CLHMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) CLH consumer-wait", merged)
            }
        }

        if runSlow {
            Benchmark("\(cfg.label) pthread_adaptive_np") { benchmark in
                let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in m.withLock { onAcq(); $0.update(iterations: w) } }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) pthread_adaptive_np consumer-wait", merged)
            }
        }
        #endif
    }
}
