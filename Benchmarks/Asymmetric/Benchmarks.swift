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

let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 30

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

let asymConfigsFast: [AsymConfig] = [
    .init(consumers: 15, producerWork: 256,  consumerWork: 1, consumerBackoffUs: 0),
    .init(consumers: 63, producerWork: 256,  consumerWork: 1, consumerBackoffUs: 0),
    // Hog with consumer backoff — producer gets near-clear runway between
    // short consumer bursts. Probes worst-case starvation shape.
    .init(consumers: 15, producerWork: 256,  consumerWork: 1, consumerBackoffUs: 300),
]

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
        warmupIterations: 5,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: 20
    )

    for cfg in asymConfigs {
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
