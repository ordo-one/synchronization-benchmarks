//===----------------------------------------------------------------------===//
// MutexStats — per-mutex instrumentation counters.
//
// Off by default (init flag on RustMutex/OptimalMutex). When enabled, tracks
// every decision point in the slow path so we can answer questions like:
//   - how often does the spin CAS win vs lose a race?
//   - how many threads park per release event?
//   - how much wasted spin budget is burned before parking?
//
// Relaxed atomics — counters only need monotonic ordering, not memory
// ordering against the lock word. Incremented via hot-path branch
// (`if let s = stats`) so the non-instrumented path stays zero-overhead.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims
import Foundation

// Zero-cost stats dispatch: mutex classes are generic over `S: StatsSink`.
// - `NoStats` has an empty `@inlinable` body → specializer folds every
//   increment call to nothing at the call site. No null check, no icache cost.
// - `MutexStats` is the real counter. Conformance gives `stats.incr(_:)` the
//   same spelling in both paths.
public protocol StatsSink {
    func incr(_ c: MutexStats.Counter)
}

public struct NoStats: StatsSink, Sendable {
    @inlinable public init() {}
    @inlinable @inline(__always)
    public func incr(_ c: MutexStats.Counter) {}
}

public final class MutexStats: StatsSink, @unchecked Sendable {
    public enum Counter: Int, CaseIterable {
        case lockFastHit            // initial CAS(0→1) at top of lock()
        case lockSlowEntries        // entered lockContended()
        case gateSkipsHit           // depth gate triggered — skip spin
        case spinLoadsUnlocked      // load in spin saw state==unlocked
        case spinExitedOnContended  // spin bailed on state==contended
        case spinBudgetExhausted    // spin ran out of iterations
        case spinCASFired           // in-spin CAS attempted (Optimal only)
        case spinCASWon
        case spinCASLost            // saw 0, CAS'd, another thread won
        case postSpinCASFired       // post-spin CAS (Rust only)
        case postSpinCASWon
        case postSpinCASLost
        case kernelPhaseEntries
        case exchangeContendedWonFirstTry  // won on first exchange(2), never slept
        case exchangeContendedWonAfterWait // woke from futex_wait, then won exchange
        case futexWaitCalls
        case futexWaitEAGAIN
        case futexWaitInterrupted
        case futexWakeCalls
        case futexWakeSuppressed    // unlock saw word==contended but parkers==0
        case demoteWonEmpty         // last parker out, CAS(contended→locked) won
        case demoteLostRace         // last parker out, CAS failed (new parker entered)
        case kernelSpinCASWon       // grabbed lock during pre-wait spin (saves a futex_wait)
        case postWakeSawRelease     // post-wake load spin saw word==0 before budget exhausted
        case preWaitDoubleCheckSkipped // pre-wait load saw word != 2, skipped futex_wait syscall
        // parking_lot-specific
        case spinPauseIters         // SpinWait iter 1..=3 fired (CPU-pause phase)
        case spinYieldIters         // SpinWait iter 4..=10 fired (sched_yield phase) — collapse suspect
        case spinWaitExhausted      // SpinWait returned false → park
        case parkAttempts           // called ParkingLot.park()
        case parkInvalidRace        // validate() returned false — race with unlock
        case handoffReceived        // woken with TOKEN_HANDOFF (fair unlock handed the lock)
        case fairUnparkTriggered    // unparkOne saw beFair=true
        case unparkEmpty            // unparkOne found no waiter (race)
        case unparkFoundWaiter      // unparkOne woke one
        case unparkHaveMoreThreads  // queue still has entries after unpark
    }

    @usableFromInline let buf: UnsafeMutablePointer<UInt64>
    @usableFromInline let count: Int

    public init() {
        count = Counter.allCases.count
        buf = .allocate(capacity: count)
        buf.initialize(repeating: 0, count: count)
    }

    deinit { buf.deallocate() }

    @inlinable
    public func incr(_ c: Counter) {
        _ = atomic_fetch_add_u64_relaxed(buf.advanced(by: c.rawValue), 1)
    }

    public func snapshot() -> [(Counter, UInt64)] {
        Counter.allCases.map { ($0, atomic_load_relaxed_u64(buf.advanced(by: $0.rawValue))) }
    }

    public func dump(label: String) {
        var lines = ["--- \(label) ---"]
        for (c, v) in snapshot() where v > 0 {
            lines.append("  \(c): \(v)")
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
#endif
