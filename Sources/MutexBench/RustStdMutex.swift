//===----------------------------------------------------------------------===//
// RustStdMutex — knob-less ship form of Rust std::sync::Mutex futex impl.
//
// Mirrors library/std/src/sys/sync/mutex/futex.rs (rustc upstream) exactly:
//   - spin 100 iterations, 1 PAUSE per iter
//   - no outer retries, no retrier pool, no depth gate, no demote logic
//   - no parkers counter
//
// Compared to RustMutex (the knobbed experimentation class):
//   - No stored config flags → compiler folds `if depthThreshold>0` etc. away
//   - No activeRetriers / parkers allocations
//   - No tracksParkers / demoteOnEmpty branches in kernel phase
//   - No spinIfLimited / skipSpuriousWake branches
//
// Stats instrumentation dispatched via generic `S: StatsSink`. Default
// `NoStats` erases every increment call at compile time — the plain path is
// untouched. Construct with `stats: MutexStats()` for INSTR runs.
//
// If you want to experiment with the knob space, use RustMutex. If you want
// to compare Rust-upstream semantics to OptimalMutex without parameterization
// overhead, use this.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class RustStdMutex<Value, S: StatsSink>: @unchecked Sendable {
    @usableFromInline
    enum State: UInt32 {
        case unlocked
        case locked
        case contended
    }

    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>
    public let stats: S

    @usableFromInline static var spinTries: Int { 100 }
    @usableFromInline static var pausesPerIter: UInt32 { 1 }

    public init(_ initialValue: Value, stats: S) {
        self.stats = stats

        // Layout: [word:u32 @0 | padding | value]
        let headerBytes = 4
        let valueAlign = Swift.max(MemoryLayout<Value>.alignment, 1)
        let valueOffset = (headerBytes + valueAlign - 1) / valueAlign * valueAlign
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(
            MemoryLayout<UInt32>.alignment,
            MemoryLayout<Value>.alignment
        )
        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: State.unlocked.rawValue)
        valuePtr = (buffer + valueOffset).assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
    }

    deinit {
        valuePtr.deinitialize(count: 1)
        buffer.deallocate()
    }

    @inlinable
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body(&valuePtr.pointee)
    }

    @inlinable
    public func lock() {
        if atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) {
            stats.incr(.lockFastHit)
            return
        }
        lockContended()
    }

    @inlinable
    func lockContended() {
        stats.incr(.lockSlowEntries)

        var state = spin()
        if state == State.unlocked.rawValue {
            stats.incr(.spinLoadsUnlocked)
            stats.incr(.postSpinCASFired)
            if atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) {
                stats.incr(.postSpinCASWon)
                return
            }
            stats.incr(.postSpinCASLost)
            state = atomic_load_relaxed_u32(word)
        } else if state == State.contended.rawValue {
            stats.incr(.spinExitedOnContended)
        } else {
            stats.incr(.spinBudgetExhausted)
        }

        // Kernel phase: swap to CONTENDED or park.
        stats.incr(.kernelPhaseEntries)
        var firstTry = true
        while true {
            if state != State.contended.rawValue
                && atomic_exchange_acquire_u32(word, State.contended.rawValue) == State.unlocked.rawValue {
                stats.incr(firstTry ? .exchangeContendedWonFirstTry : .exchangeContendedWonAfterWait)
                return
            }
            firstTry = false

            stats.incr(.futexWaitCalls)
            let err = futex_wait(word, State.contended.rawValue)
            switch err {
            case 0: break
            case 11: stats.incr(.futexWaitEAGAIN)
            case 4: stats.incr(.futexWaitInterrupted)
            default: fatalError("Unknown error in futex_wait: \(err)")
            }

            state = spin()
        }
    }

    @inlinable
    func spin() -> UInt32 {
        var remaining = Self.spinTries
        while true {
            let state = atomic_load_relaxed_u32(word)
            if state != State.locked.rawValue || remaining == 0 {
                return state
            }
            for _ in 0..<Self.pausesPerIter { spin_loop_hint() }
            remaining -= 1
        }
    }

    @inlinable
    public func unlock() {
        guard atomic_exchange_release_u32(word, State.unlocked.rawValue) == State.contended.rawValue else {
            return
        }
        stats.incr(.futexWakeCalls)
        _ = futex_wake(word, 1)
    }
}

extension RustStdMutex where S == NoStats {
    public convenience init(_ initialValue: Value) {
        self.init(initialValue, stats: NoStats())
    }
}
#endif
