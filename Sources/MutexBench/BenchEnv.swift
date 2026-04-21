import Foundation
import Benchmark

// Shared env gates + default Benchmark config. Every Benchmarks/*/Benchmarks.swift
// used to repeat the same 5-line env read + 8-line defaultConfiguration. Single
// source of truth here; per-target overrides still possible via the helper args.

public enum BenchEnv {
    private static func flag(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key] == "1"
    }

    public static let focus      = flag("MUTEX_BENCH_FOCUS")
    public static let slow       = flag("MUTEX_BENCH_SLOW")
    public static let copy       = flag("MUTEX_BENCH_COPY")
    public static let experiment = flag("MUTEX_BENCH_EXPERIMENT")
    public static let rustDemote = flag("MUTEX_BENCH_RUST_DEMOTE")

    /// MUTEX_BENCH_MAX_SECS overrides; otherwise use per-target default.
    public static func maxSecs(default d: Int) -> Int {
        Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? d
    }

    /// Standard metric set used by every benchmark target.
    public static let defaultMetrics: [BenchmarkMetric] = [
        .wallClock, .cpuUser, .cpuSystem, .throughput,
        .syscalls, .contextSwitches, .threadsRunning, .instructions,
    ]

    /// Install default Benchmark configuration. Callers pass warmup/maxIter;
    /// metrics, timeUnits, maxDuration are canonical.
    public static func applyDefaultConfig(
        warmupIterations: Int,
        maxDurationSecs: Int,
        maxIterations: Int,
        metrics: [BenchmarkMetric] = defaultMetrics,
        timeUnits: BenchmarkTimeUnits = .microseconds
    ) {
        Benchmark.defaultConfiguration = .init(
            metrics: metrics,
            timeUnits: timeUnits,
            warmupIterations: warmupIterations,
            maxDuration: .seconds(maxDurationSecs),
            maxIterations: maxIterations
        )
    }
}
