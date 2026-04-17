import Benchmark
import Foundation
import MutexBench

let maxDurationSecs = Int(ProcessInfo.processInfo.environment["MUTEX_BENCH_MAX_SECS"] ?? "") ?? 20
let runSlow = ProcessInfo.processInfo.environment["MUTEX_BENCH_SLOW"] == "1"
let runCopy = ProcessInfo.processInfo.environment["MUTEX_BENCH_COPY"] == "1"

// Ported from Go's BenchmarkMutexSlack:
//   https://github.com/golang/go/blob/master/src/sync/mutex_test.go
//
// Adds non-contending background goroutines alongside N contenders. Tests how
// the scheduler / thread-pool reacts when idle work exists on the same pool
// as active lock-contending work. Directly relevant to Swift Task runtime:
// Swift's cooperative thread pool is bounded, and idle Tasks may still hold
// pool slots. If the mutex's userspace spin fights the runtime for scheduling,
// slack tasks will amplify the effect.
//
// Configuration: N=16 contenders (at the known cliff point from TaskSweep),
// M ∈ {0, 16, 64, 256} idle slack tasks that burn inside their own loop
// without ever touching the lock.

struct SlackConfig: Sendable {
    let contenders: Int
    let slack: Int
    let work: Int
    var label: String { "contenders=\(contenders) slack=\(slack) work=\(work)" }
    var acquiresPerTask: Int { defaultTotalAcquires / contenders }
}

let slackConfigs: [SlackConfig] = [
    .init(contenders: 16, slack: 0,   work: 1),
    .init(contenders: 16, slack: 16,  work: 1),
    .init(contenders: 16, slack: 64,  work: 1),
    .init(contenders: 16, slack: 256, work: 1),
]

@inline(__always)
func slackWorkload(
    contenders: Int,
    slack: Int,
    acquiresPerTask: Int,
    work: Int,
    acquire: @Sendable @escaping () -> Void
) async {
    await withTaskGroup(of: Void.self) { group in
        // Slack tasks: do unlocked work until a shared flag flips.
        // `await Task.yield()` is mandatory — Swift cooperative pool does NOT
        // preempt inside sync code, so without yield the slack tasks would
        // monopolize the pool threads and the contenders would never run.
        // Go's BenchmarkMutexSlack works without this because Go has async
        // goroutine preemption (since 1.14); Swift does not.
        let stop = UnsafeFlag()
        for _ in 0..<slack {
            group.addTask {
                while !stop.load() {
                    doUnlockedWork(64)
                    await Task.yield()
                }
            }
        }
        // Contenders
        for _ in 0..<contenders {
            group.addTask {
                for _ in 0..<acquiresPerTask { acquire() }
            }
        }
        // Wait for contenders to finish, then stop slack.
        var contendersDone = 0
        for await _ in group {
            contendersDone += 1
            if contendersDone == contenders {
                stop.store(true)
            }
        }
    }
}

// Atomic flag — NOT a Mutex. Using Mutex<Bool> here would make slack tasks
// contend on the very primitive under test, inflating runtimes at high slack.
import Synchronization
final class UnsafeFlag: @unchecked Sendable {
    let a = Atomic<Bool>(false)
    func store(_ v: Bool) { a.store(v, ordering: .relaxed) }
    func load() -> Bool { a.load(ordering: .relaxed) }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuUser, .cpuSystem, .throughput, .syscalls, .contextSwitches, .threadsRunning, .instructions],
        timeUnits: .microseconds,
        warmupIterations: 15,
        maxDuration: .seconds(maxDurationSecs),
        maxIterations: 100
    )

    for cfg in slackConfigs {
        Benchmark("\(cfg.label) Synchronization.Mutex") { benchmark in
            let box = SyncMutexBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                box.work(cfg.work)
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) NIOLockedValueBox") { benchmark in
            let box = NIOLockBox(capacity: defaultMapCapacity)
            benchmark.startMeasurement()
            await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                box.work(cfg.work)
            }
            benchmark.stopMeasurement()
        }

        #if os(Linux)
        if runCopy {
            Benchmark("\(cfg.label) Synchronization.Mutex (copy)") { benchmark in
                let m = SynchronizationMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }

        Benchmark("\(cfg.label) PlainFutexMutex (spin=100)") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 100)
            benchmark.startMeasurement()
            await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) plain spin=14 backoff") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 14, useBackoff: true)
            benchmark.startMeasurement()
            await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) plain spin=40 fixed") { benchmark in
            let m = PlainFutexMutex(MapState(capacity: defaultMapCapacity), spinTries: 40)
            benchmark.startMeasurement()
            await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        Benchmark("\(cfg.label) Optimal") { benchmark in
            let m = OptimalMutex(MapState(capacity: defaultMapCapacity))
            benchmark.startMeasurement()
            await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                m.withLock { $0.update(iterations: cfg.work) }
            }
            benchmark.stopMeasurement()
        }

        if runSlow {
            Benchmark("\(cfg.label) pthread_adaptive_np") { benchmark in
                let m = AdaptiveMutex(MapState(capacity: defaultMapCapacity))
                benchmark.startMeasurement()
                await slackWorkload(contenders: cfg.contenders, slack: cfg.slack, acquiresPerTask: cfg.acquiresPerTask, work: cfg.work) {
                    m.withLock { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
        #endif
    }
}
