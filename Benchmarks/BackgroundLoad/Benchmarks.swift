import Benchmark
import MutexBench
import Synchronization

// Ported from Go's BenchmarkMutexSlack:
//   https://github.com/golang/go/blob/master/src/sync/mutex_test.go
//
// Adds non-contending background goroutines alongside N contenders. Tests how
// the scheduler / thread-pool reacts when idle work exists on the same pool
// as active lock-contending work. Directly relevant to Swift Task runtime:
// Swift's cooperative thread pool is bounded, and idle Tasks may still hold
// pool slots. If the mutex's userspace spin fights the runtime for scheduling,
// slack tasks will amplify the effect.

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

// Atomic flag — NOT a Mutex. Using Mutex<Bool> here would make slack tasks
// contend on the very primitive under test, inflating runtimes at high slack.
final class UnsafeFlag: @unchecked Sendable {
    let a = Atomic<Bool>(false)
    func store(_ v: Bool) { a.store(v, ordering: .relaxed) }
    func load() -> Bool { a.load(ordering: .relaxed) }
}

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
        let stop = UnsafeFlag()
        for _ in 0..<slack {
            group.addTask {
                while !stop.load() {
                    doUnlockedWork(64)
                    await Task.yield()
                }
            }
        }
        for _ in 0..<contenders {
            group.addTask {
                for _ in 0..<acquiresPerTask { acquire() }
            }
        }
        var contendersDone = 0
        for await _ in group {
            contendersDone += 1
            if contendersDone == contenders {
                stop.store(true)
            }
        }
    }
}

let benchmarks: @Sendable () -> Void = {
    BenchEnv.applyDefaultConfig(
        warmupIterations: 15,
        maxDurationSecs: BenchEnv.maxSecs(default: 20),
        maxIterations: 100
    )

    for cfg in slackConfigs {
        for v in StandardVariants.defaultsWithRust() {
            Benchmark("\(cfg.label) \(v.name)") { benchmark in
                let h = v.make(defaultMapCapacity)
                benchmark.startMeasurement()
                await slackWorkload(
                    contenders: cfg.contenders, slack: cfg.slack,
                    acquiresPerTask: cfg.acquiresPerTask, work: cfg.work
                ) {
                    h.runLocked { $0.update(iterations: cfg.work) }
                }
                benchmark.stopMeasurement()
            }
        }
    }
}
