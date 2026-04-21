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
    let consumerBackoffUs: UInt32
    var label: String {
        let b = consumerBackoffUs > 0 ? " backoff=\(consumerBackoffUs)µs" : ""
        return "consumers=\(consumers) producer=\(producerWork) consumer=\(consumerWork)\(b)"
    }
    var acquiresPerConsumer: Int { defaultTotalAcquires / consumers }
    var producerAcquires: Int { defaultTotalAcquires / 10 } // produce ~10% as many ops
}

let asymConfigsFast: [AsymConfig] = {
    var cs = [15, 24, 32, 63, 91, 127]
    if !BenchEnv.focus { cs.append(255) }
    return cs.map { .init(consumers: $0, producerWork: 256, consumerWork: 1, consumerBackoffUs: 0) }
}()

let asymConfigsSlow: [AsymConfig] = [
    // Producer holds 2.4 ms per acquire; iter ≈ 12 s. Gated.
    .init(consumers: 15, producerWork: 1024, consumerWork: 1, consumerBackoffUs: 0),
    .init(consumers: 63, producerWork: 1024, consumerWork: 1, consumerBackoffUs: 0),
]

let asymConfigs = asymConfigsFast + (BenchEnv.slow ? asymConfigsSlow : [])

// Skewed-producer workload (80-20 / 95-5). One "hot" thread acquires in a
// tight loop; remaining "cold" threads have a per-acquire usleep gap so their
// aggregate rate is lower. Models real workloads where one worker handles
// most messages and peers trickle a minority share (pool schedulers, message
// fan-in patterns). Deadline-bounded per iteration; reports hot-wait and
// cold-wait histograms separately to reveal ownership-affinity effects.
//
// Expected signal:
//   - Plain barging impls (Optimal, Rust, NIO) → hot's p50 ≪ cold's p50 (owner locality).
//   - Strict-fairness impls (Go starvation, PI handoff) → hot/cold gap shrinks.
//   - The tradeoff: fairness flatten costs hot-path throughput, wins bounded tail.
//
// Parser note: aggregators should skip `n=0` hot-wait rows. On cooperative-pool
// runtimes where tasks > cores (Darwin 10-core smoke tests) the hot Task is
// occasionally never scheduled within the deadline window. On Linux ≥40-core
// hosts where tasks ≤ cores this doesn't happen — the primary targets for this
// bench.
struct SkewedConfig: Sendable {
    let tasks: Int             // total workers including 1 hot
    let coldGapUs: UInt32      // cold tasks usleep this between acquires
    let durationMs: Int        // per-iteration deadline
    var label: String { "skewed tasks=\(tasks) coldgap=\(coldGapUs)µs" }
}

let skewedConfigs: [SkewedConfig] = {
    // tasks=16 → 1 hot + 15 cold; gap=10µs → cold does ~100K/s vs hot ~2M+/s → ~95-5
    // tasks=64 → 1 hot + 63 cold; gap=10µs → ~97-3 skew at scale
    // tasks=16 gap=2µs → ~80-20 (tight cold cycle)
    var cs: [SkewedConfig] = [
        .init(tasks: 16, coldGapUs: 2,  durationMs: 300),
        .init(tasks: 16, coldGapUs: 10, durationMs: 300),
        .init(tasks: 64, coldGapUs: 10, durationMs: 300),
    ]
    if BenchEnv.slow {
        cs.append(.init(tasks: 64, coldGapUs: 2, durationMs: 500))
    }
    return cs
}()

@inline(__always)
func skewedWorkload(
    tasks: Int,
    coldGapUs: UInt32,
    durationMs: Int,
    acquireAndRun: @Sendable @escaping (Int, () -> Void) -> Void
) async -> (hot: Histogram<UInt64>, cold: Histogram<UInt64>) {
    // Hot label separates from cold in merge step. Both run deadline-bounded
    // so contention stays sustained throughout the iteration.
    //
    // Deadline is anchored to the SyncedStart gate (not `now`), so all tasks
    // share the same stop instant even when scheduler jitter delays some of
    // them past the gate. Earlier bug: deadline relative to enqueue-time +
    // late-scheduled hot task entered its loop after deadline → n=0 hist.
    enum Role { case hot, cold }
    return await withTaskGroup(of: (Role, Histogram<UInt64>).self) { group in
        let gate = SyncedStart()
        let deadline = gate.deadline.advanced(by: .milliseconds(durationMs))

        // Hot: tight acquire-release loop, no unlocked gap. Periodic
        // Task.yield() every ~10k acquires prevents total hot-task starvation
        // on cooperative-pool runtimes where tasks > cores (e.g. tasks=16 on
        // Darwin 10-core dev box). At ~50ns/acquire yield fires every ~500µs
        // so owner-affinity is largely preserved within each burst. On Linux
        // 40+ core hosts where tasks ≤ cores this has no measurable effect.
        group.addTask {
            await gate.waitForStart()
            var h = makeLatencyHistogram()
            var yieldCounter = 0
            while ContinuousClock.now < deadline {
                var t1: UInt64 = 0
                let t0 = DispatchTime.now().uptimeNanoseconds
                acquireAndRun(1) {
                    t1 = DispatchTime.now().uptimeNanoseconds
                }
                _ = h.record(t1 &- t0)
                yieldCounter &+= 1
                if yieldCounter & 0x3FFF == 0 { await Task.yield() }
            }
            return (.hot, h)
        }

        // Cold: acquire-release-usleep loop. Gap bounds cold's acquire rate.
        let coldCount = tasks - 1
        for _ in 0..<coldCount {
            group.addTask {
                await gate.waitForStart()
                var h = makeLatencyHistogram()
                while ContinuousClock.now < deadline {
                    var t1: UInt64 = 0
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    acquireAndRun(1) {
                        t1 = DispatchTime.now().uptimeNanoseconds
                    }
                    _ = h.record(t1 &- t0)
                    if coldGapUs > 0 { usleep(coldGapUs) }
                }
                return (.cold, h)
            }
        }

        var hotHists: [Histogram<UInt64>] = []
        var coldHists: [Histogram<UInt64>] = []
        for await (role, h) in group {
            switch role {
            case .hot:  hotHists.append(h)
            case .cold: coldHists.append(h)
            }
        }
        return (mergeHistograms(hotHists), mergeHistograms(coldHists))
    }
}

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

// DepthAdaptive sweep for INSTR consumers ∈ [15,32,63]. Shared exact-parameter
// list — matches per-stanza rationale in prior inline comments.
#if os(Linux)
let asymInstrDepthSweep: [MutexVariant] = {
    var v: [MutexVariant] = []
    // pws=40 ≈ 40 pauses ≈ 1.4µs AMD / 1.7µs Alder Lake — spans ~2 producer CS cycles.
    // Tests whether post-wake spin reduces wake-then-lose-to-barger amplification.
    if !BenchEnv.focus {
        v.append(.depthAdaptive(
            name: "INSTR depth K=4 sp=20 pws=40",
            spinTries: 20, pauseBase: 64, depthThreshold: 4,
            postWakeSpinTries: 40, instrument: true
        ))
    }
    // no-starv variants: isolate depth+waiterCount cost from starvation.
    // Ship candidates (session 2026-04-19: no-starv + pws=32 selected).
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pcl=64",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postCASLostPause: 64, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pcl=128",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postCASLostPause: 128, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pws=32",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postWakeSpinTries: 32, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=20 no-starv pws=32 dcheck",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: false, postWakeSpinTries: 32,
        preWaitDoubleCheck: true, instrument: true
    ))
    // Go-style starvation mode at 1ms threshold.
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=20 starv=1ms",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: true, starvationThresholdNs: 1_000_000, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=20 starv=1ms pws=32",
        spinTries: 20, pauseBase: 64, depthThreshold: 4,
        useStarvation: true, starvationThresholdNs: 1_000_000,
        postWakeSpinTries: 32, instrument: true
    ))
    v.append(.depthAdaptive(
        name: "INSTR depth K=4 sp=5 starv=1ms pws=32",
        spinTries: 5, pauseBase: 64, depthThreshold: 4,
        useStarvation: true, starvationThresholdNs: 1_000_000,
        postWakeSpinTries: 32, instrument: true
    ))
    // Reduced-spin sweep: starvation safety net bounds tail when spin budget
    // exhausts. Test if sp=3/5/10 ties or beats sp=20 wallclock.
    if !BenchEnv.focus {
        for sp in [3, 5, 10] {
            v.append(.depthAdaptive(
                name: "INSTR depth K=4 sp=\(sp) starv=1ms",
                spinTries: sp, pauseBase: 64, depthThreshold: 4,
                useStarvation: true, starvationThresholdNs: 1_000_000,
                instrument: true
            ))
        }
    }
    return v
}()
#endif

let benchmarks: @Sendable () -> Void = {
    BenchEnv.applyDefaultConfig(
        warmupIterations: BenchEnv.focus ? 3 : 5,
        maxDurationSecs: BenchEnv.maxSecs(default: 30),
        maxIterations: BenchEnv.focus ? 10 : 20
    )

    // Per-config variant list.
    func variants(for _: AsymConfig) -> [MutexVariant] {
        var v: [MutexVariant] = []
        if !BenchEnv.focus {
            v.append(.syncMutex())
            v.append(.niolock())
        }
        #if os(Linux)
        if BenchEnv.copy { v.append(.syncMutexCopy()) }
        if !BenchEnv.focus {
            v.append(.plainFutex(name: "PlainFutexMutex (spin=100)", spinTries: 100))
            v.append(.plainFutex(name: "plain spin=14 backoff", spinTries: 14, useBackoff: true))
            v.append(.plainFutex(name: "plain spin=40 fixed", spinTries: 40))
        }
        v.append(.optimal())
        if !BenchEnv.focus { v.append(.rustMutex()) }
        if BenchEnv.slow { v.append(.pthreadAdaptive()) }
        #endif
        return v
    }

    for cfg in asymConfigs {
        // Main variants.
        for v in variants(for: cfg) {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                let hists = await asymWorkload(
                    consumers: cfg.consumers,
                    producerAcquires: cfg.producerAcquires,
                    consumerAcquires: cfg.acquiresPerConsumer,
                    producerWork: cfg.producerWork,
                    consumerWork: cfg.consumerWork,
                    consumerBackoffUs: cfg.consumerBackoffUs
                ) { w, onAcq in
                    h.runLocked(hook: onAcq) { $0.update(iterations: w) }
                }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) \(v.name) consumer-wait", merged)
            }
        }

        #if os(Linux)
        // INSTR variants at under/at/over core-count regimes. Connect fairness
        // histograms to mechanism counters: spinCASWon ratio, kernelPhaseEntries,
        // futexWakeCalls reveal WHY tail varies. +20% wallclock overhead — compare
        // INSTR-vs-INSTR only.
        if [15, 32, 63].contains(cfg.consumers) {
            var instrVariants: [MutexVariant] = [.optimal(name: "INSTR Optimal", instrument: true)]
            if !BenchEnv.focus {
                instrVariants.append(.rustMutex(name: "INSTR RustMutex", instrument: true))
            }
            instrVariants.append(contentsOf: asymInstrDepthSweep)

            for v in instrVariants {
                Benchmark("\(cfg.label) \(v.name)") { benchmark in
                    let h = v.make(defaultMapCapacity)
                    benchmark.startMeasurement()
                    let hists = await asymWorkload(
                        consumers: cfg.consumers,
                        producerAcquires: cfg.producerAcquires,
                        consumerAcquires: cfg.acquiresPerConsumer,
                        producerWork: cfg.producerWork,
                        consumerWork: cfg.consumerWork,
                        consumerBackoffUs: cfg.consumerBackoffUs
                    ) { w, onAcq in
                        h.runLocked(hook: onAcq) { $0.update(iterations: w) }
                    }
                    benchmark.stopMeasurement()
                    let merged = mergeHistograms(hists)
                    printLatencySummary("\(cfg.label) \(v.name) consumer-wait", merged)
                    // Drop variant-name prefix from dump label to keep stats-agg scripts
                    // keyed on impl shorthand (matches original Asymmetric.swift format).
                    h.dumpStats?("\(v.name.replacingOccurrences(of: "INSTR ", with: "")) \(cfg.label)")
                }
            }
        }
        #endif
    }

    // ---- Skewed-producer workload ----
    // Uses the same per-config variant list as the producer/consumer shape
    // above, minus the full INSTR depth-sweep (keep iteration time bounded).
    // Hot/cold histograms reported separately on stderr — compare p50 gap
    // between hot and cold to quantify owner-affinity bias per impl.
    for sc in skewedConfigs {
        var vs: [MutexVariant] = []
        if !BenchEnv.focus {
            vs.append(.syncMutex())
            vs.append(.niolock())
        }
        #if os(Linux)
        vs.append(.optimal())
        if !BenchEnv.focus { vs.append(.rustMutex()) }
        if BenchEnv.slow { vs.append(.pthreadAdaptive()) }
        #endif

        for v in vs {
            Benchmark("\(sc.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                let (hot, cold) = await skewedWorkload(
                    tasks: sc.tasks,
                    coldGapUs: sc.coldGapUs,
                    durationMs: sc.durationMs
                ) { w, onAcq in
                    h.runLocked(hook: onAcq) { $0.update(iterations: w) }
                }
                benchmark.stopMeasurement()
                printLatencySummary("\(sc.label) \(v.name) hot-wait", hot)
                printLatencySummary("\(sc.label) \(v.name) cold-wait", cold)
            }
        }
    }
}
