import Testing
@testable import MutexBench

#if os(Linux)
import Dispatch
import Foundation
import Synchronization

// DispatchQueue.concurrentPerform is used instead of `Task`s so the workers
// are real kernel threads. Cooperative Tasks would serialize on the fixed
// pool and never exercise the futex park/wake path.

// MARK: - Test-local payload types

fileprivate struct Pair: Sendable {
    var a: Int = 0
    var b: Int = 0
}

@Suite("Mutex correctness")
struct MutexCorrectnessTests {

    // A factory produces a fresh mutex and returns Sendable closures bound
    // to it. Lets parameterized tests iterate over mutex variants that share
    // the `.withLock` method but no common protocol.
    typealias Runner = (inc: @Sendable () -> Void, read: @Sendable () -> Int)
    typealias Factory = @Sendable () -> Runner

    static let variants: [(name: String, make: Factory)] = [
        ("OptimalMutex", {
            let m = OptimalMutex(0)
            return (inc: { m.withLock { $0 += 1 } }, read: { m.withLock { $0 } })
        }),
        ("ParkingLotMutex", {
            let m = ParkingLotMutex(0)
            return (inc: { m.withLock { $0 += 1 } }, read: { m.withLock { $0 } })
        }),
    ]

    // MARK: - Uncontended

    /// Sequential acquire/increment/read loop. Catches mutexes that either
    /// don't actually protect their payload or drop writes on the fast path.
    @Test(arguments: variants)
    func uncontendedLockUnlock(name: String, make: Factory) {
        let r = make()
        for i in 1...100 {
            r.inc()
            #expect(r.read() == i, "variant=\(name) at i=\(i)")
        }
    }

    // MARK: - Mutual exclusion under moderate contention

    /// `cores` real kernel threads × 20 000 increments. If the mutex fails
    /// even once, two threads race the load→add→store and the final counter
    /// reads less than `cores × 20_000`. 2-minute cap so a deadlock produces
    /// a clear failure instead of hanging.
    @Test(.timeLimit(.minutes(2)), arguments: variants)
    func mutualExclusion(name: String, make: Factory) {
        let r = make()
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount)
        let iters = 20_000
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<iters { r.inc() }
        }
        #expect(r.read() == threads * iters, "variant=\(name) threads=\(threads)")
    }

    // MARK: - Oversubscription stress

    /// 2× cores threads × 2 000 increments. Drives most acquires through
    /// SpinWait exhaustion → park → unpark instead of the fast-path CAS.
    /// Catches park/unpark mismatch
    /// (wrong thread woken, dropped queue entry, handoff-token mis-stored).
    /// Dimensions chosen to keep per-variant wall-clock under ~1 s while
    /// still producing ~hundreds of thousands of park/unpark cycles.
    @Test(.timeLimit(.minutes(2)), arguments: variants)
    func oversubscription(name: String, make: Factory) {
        let r = make()
        let threads = ProcessInfo.processInfo.activeProcessorCount * 2
        let iters = 2_000
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<iters { r.inc() }
        }
        #expect(r.read() == threads * iters, "variant=\(name) threads=\(threads)")
    }

    // MARK: - Value-pair atomicity
    //
    // Integer-counter tests catch lost writes but NOT ordering bugs inside
    // the critical section — `counter += 1` has only one memory effect so
    // there's no "torn" state to observe. Protect a two-field payload, have
    // writers set a=n then b=n (in that source order), readers assert a == b.
    // Any reader that sees a==N and b<N means the compiler/CPU reordered the
    // stores across the lock's release barrier, or the payload slipped out
    // of the protected region.

    typealias PairRunner = (
        write: @Sendable (Int) -> Void,
        read: @Sendable () -> (a: Int, b: Int)
    )
    typealias PairFactory = @Sendable () -> PairRunner

    static let pairVariants: [(name: String, make: PairFactory)] = [
        ("OptimalMutex", {
            let m = OptimalMutex(Pair())
            return (
                write: { n in m.withLock { $0.a = n; $0.b = n } },
                read: { m.withLock { (a: $0.a, b: $0.b) } }
            )
        }),
        ("ParkingLotMutex", {
            let m = ParkingLotMutex(Pair())
            return (
                write: { n in m.withLock { $0.a = n; $0.b = n } },
                read: { m.withLock { (a: $0.a, b: $0.b) } }
            )
        }),
    ]

    @Test(.timeLimit(.minutes(2)), arguments: pairVariants)
    func valuePairAtomicity(name: String, make: PairFactory) {
        let r = make()
        let cores = max(4, ProcessInfo.processInfo.activeProcessorCount)
        let writers = cores / 2
        let readers = cores - writers
        let iters = 10_000
        let mismatches = Atomic<Int>(0)

        DispatchQueue.concurrentPerform(iterations: writers + readers) { i in
            if i < writers {
                for n in 1...iters { r.write(n) }
            } else {
                for _ in 0..<iters {
                    let (a, b) = r.read()
                    if a != b { mismatches.add(1, ordering: .relaxed) }
                }
            }
        }
        #expect(
            mismatches.load(ordering: .relaxed) == 0,
            "variant=\(name) — reader observed a != b; critical section or release barrier broken"
        )
    }

    // MARK: - Two mutexes, independent totals
    //
    // Allocate two mutex INSTANCES with separate counters. Run concurrent
    // increments on each. Each counter must equal its own `threads × iters`
    // — NOT the combined sum. Catches bucket-hash mis-routing where
    // `unpark_one` on lock A wakes a waiter of lock B (a structural bug in
    // ParkingLotCore's key check would show up as lost wakes on one side
    // and/or ghost wakes on the other).

    typealias DualRunner = (a: Runner, b: Runner)
    typealias DualFactory = @Sendable () -> DualRunner

    static let dualVariants: [(name: String, make: DualFactory)] = [
        ("OptimalMutex", {
            let m1 = OptimalMutex(0); let m2 = OptimalMutex(0)
            return (
                a: (inc: { m1.withLock { $0 += 1 } }, read: { m1.withLock { $0 } }),
                b: (inc: { m2.withLock { $0 += 1 } }, read: { m2.withLock { $0 } })
            )
        }),
        ("ParkingLotMutex", {
            let m1 = ParkingLotMutex(0); let m2 = ParkingLotMutex(0)
            return (
                a: (inc: { m1.withLock { $0 += 1 } }, read: { m1.withLock { $0 } }),
                b: (inc: { m2.withLock { $0 += 1 } }, read: { m2.withLock { $0 } })
            )
        }),
    ]

    @Test(.timeLimit(.minutes(2)), arguments: dualVariants)
    func twoMutexIndependence(name: String, make: DualFactory) {
        let r = make()
        let cores = max(4, ProcessInfo.processInfo.activeProcessorCount)
        // Half the threads pound lock A, half pound lock B.
        let perSideThreads = cores / 2
        let iters = 10_000

        DispatchQueue.concurrentPerform(iterations: perSideThreads * 2) { i in
            if i < perSideThreads {
                for _ in 0..<iters { r.a.inc() }
            } else {
                for _ in 0..<iters { r.b.inc() }
            }
        }

        let expected = perSideThreads * iters
        #expect(r.a.read() == expected, "variant=\(name) counter A — cross-mutex leak?")
        #expect(r.b.read() == expected, "variant=\(name) counter B — cross-mutex leak?")
    }
}

#endif
