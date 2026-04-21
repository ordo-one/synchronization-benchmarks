import Benchmark
import Foundation
import Histogram
import MutexBench

// Bursty arrivals — thundering-herd probe.
//
// Pattern: all N tasks wait on a shared deadline, then simultaneously try to
// acquire the lock (burst). After `opsPerBurst` acquires each, quiet period,
// then repeat. Captures settling-time distribution: the very first few
// acquires in each burst are the worst case for fairness.
//
// Relevant prior art:
//   glibc jitter: https://www.gnu.org/software/libc/manual/html_node/POSIX-Thread-Tunables.html
//     "exp_backoff + (jitter & (exp_backoff - 1))" — targets this exact shape.
//   WebKit WTF::Lock unfairness detection under bursty load:
//     https://webkit.org/blog/6161/locking-in-webkit/

struct BurstConfig: Sendable {
    let burstSize: Int
    let bursts: Int
    let opsPerBurst: Int
    let quietMs: Int
    var label: String { "burst=\(burstSize)×\(bursts) ops=\(opsPerBurst) quiet=\(quietMs)ms" }
}

let burstConfigs: [BurstConfig] = [
    .init(burstSize: 4,  bursts: 200, opsPerBurst: 64, quietMs: 2),
    .init(burstSize: 16, bursts: 200, opsPerBurst: 64, quietMs: 2),
    .init(burstSize: 64, bursts: 100, opsPerBurst: 32, quietMs: 2),
    // Macro-cycle burst (~1 s gap) — probes lock behavior after scheduler/cache
    // state has fully drained between bursts. Adapted from
    // https://github.com/cuongleqq/mutex-benches (Burst scenario: 200 ms on / 800 ms off).
    .init(burstSize: 8,  bursts: 5,   opsPerBurst: 2_048, quietMs: 800),
]

@inline(__always)
func burstyWorkload(
    burstSize: Int,
    bursts: Int,
    opsPerBurst: Int,
    quietMs: Int,
    acquire: @Sendable @escaping () -> Void
) async -> [Histogram<UInt64>] {
    let startBase = ContinuousClock.now.advanced(by: .milliseconds(20))
    let gap = Duration.milliseconds(quietMs + 1) // include lock-op time in budget
    return await withTaskGroup(of: Histogram<UInt64>.self) { group in
        for _ in 0..<burstSize {
            group.addTask {
                var h = makeLatencyHistogram()
                for b in 0..<bursts {
                    let deadline = startBase.advanced(by: gap * b)
                    try? await Task.sleep(until: deadline, clock: ContinuousClock())
                    // First acquire of the burst — the interesting latency.
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    acquire()
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    _ = h.record(t1 &- t0)
                    // Remaining acquires in the burst — drain.
                    for _ in 1..<opsPerBurst { acquire() }
                }
                return h
            }
        }
        var hists: [Histogram<UInt64>] = []
        for await h in group { hists.append(h) }
        return hists
    }
}

let benchmarks: @Sendable () -> Void = {
    // Entire target gated — results converged within 0.3% on 12C test host.
    // Set MUTEX_BENCH_SLOW=1 to include.
    guard BenchEnv.slow else { return }

    BenchEnv.applyDefaultConfig(
        warmupIterations: 3,
        maxDurationSecs: BenchEnv.maxSecs(default: 30),
        maxIterations: 10
    )

    var variants = StandardVariants.defaultsWithRust()
    #if os(Linux)
    // Bursty had pthread_adaptive_np unconditional (not gated by runSlow) in original.
    // Keep unconditional here.
    if !variants.contains(where: { $0.name == "pthread_adaptive_np" }) {
        variants.append(.pthreadAdaptive())
    }
    #endif

    for cfg in burstConfigs {
        for v in variants {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                let hists = await burstyWorkload(
                    burstSize: cfg.burstSize,
                    bursts: cfg.bursts,
                    opsPerBurst: cfg.opsPerBurst,
                    quietMs: cfg.quietMs
                ) {
                    h.runLocked { $0.update(iterations: 1) }
                }
                benchmark.stopMeasurement()
                let merged = mergeHistograms(hists)
                printLatencySummary("\(cfg.label) \(v.name) first-of-burst", merged)
            }
        }
    }
}
