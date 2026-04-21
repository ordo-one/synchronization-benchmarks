//===----------------------------------------------------------------------===//
// OptimalMutexStats — instrumented twin of OptimalMutex.
//
// Algorithm body mirrors OptimalMutex.swift 1:1 (which itself mirrors
// swiftlang/swift#88523). The only additions are `MutexStats` counter
// increments at every decision point, gated behind an optional `stats`
// reference so a non-instrumented path stays zero-overhead — but in practice
// this class is only constructed when a benchmark asks for INSTR counters.
// If OptimalMutex is updated, apply the same edit here.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

// Spin-phase iteration budget.
private let spinTries: Int = 20

// CPU pauses per spin iteration, before jitter. Must be a power of two (masked to generate the jitter via
// `jitter & (pauseBase - 1)`).
private let pauseBase: UInt32 = 64

// Once this many threads are already waiting for the lock, new arrivals skip the spin loop and go to sleep
// immediately. Keeps the set of actively-spinning threads bounded so the lock holder's critical section runs
// without cache-line interference from the spinners.
private let maxActiveSpinners: UInt32 = 4

public final class OptimalMutexStats<Value>: @unchecked Sendable {
    @usableFromInline
    enum State: UInt32 {
        case unlocked
        case locked      // held, no waiters parked in the kernel
        case contended   // held, at least one waiter parked in the kernel
    }

    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let storage: UnsafeMutablePointer<UInt32>
    @usableFromInline let slowPathDepth: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>
    public let stats: MutexStats

    public init(_ initialValue: Value) {
        self.stats = MutexStats()
        let valueOffset = Swift.max(8, MemoryLayout<Value>.alignment)
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(
            MemoryLayout<UInt32>.alignment,
            MemoryLayout<Value>.alignment
        )
        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        storage = buffer.assumingMemoryBound(to: UInt32.self)
        storage.initialize(to: State.unlocked.rawValue)
        slowPathDepth = (buffer + 4).assumingMemoryBound(to: UInt32.self)
        slowPathDepth.initialize(to: 0)
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
        if atomic_cas_acquire_u32(storage, State.unlocked.rawValue, State.locked.rawValue) {
            stats.incr(.lockFastHit)
            return
        }
        lockSlow(0)
    }

    @usableFromInline
    func lockSlow(_ selfId: UInt32) {
        stats.incr(.lockSlowEntries)

        let initialState = atomic_load_acquire_u32(storage)
        let depth = atomic_load_acquire_u32(slowPathDepth)
        let skipSpin = (initialState == State.contended.rawValue) && (depth >= maxActiveSpinners)

        if skipSpin { stats.incr(.gateSkipsHit) }

        if !skipSpin {
            let jitter = fast_jitter()
            let mask = pauseBase &- 1
            var spinsRemaining = spinTries

            while spinsRemaining > 0 {
                let state = atomic_load_relaxed_u32(storage)

                if state == State.unlocked.rawValue {
                    stats.incr(.spinLoadsUnlocked)
                    stats.incr(.spinCASFired)
                    if atomic_cas_acquire_u32(storage, State.unlocked.rawValue, State.locked.rawValue) {
                        stats.incr(.spinCASWon)
                        return
                    }
                    stats.incr(.spinCASLost)
                }

                if state == State.contended.rawValue {
                    stats.incr(.spinExitedOnContended)
                    break
                }

                let pauses = pauseBase &+ (jitter & mask)
                for _ in 0 ..< pauses {
                    spin_loop_hint()
                }

                spinsRemaining -= 1
            }

            if spinsRemaining == 0 { stats.incr(.spinBudgetExhausted) }
        }

        stats.incr(.kernelPhaseEntries)
        var visibleToSpinners = false
        var firstTry = true

        while true {
            if atomic_exchange_acquire_u32(storage, State.contended.rawValue) == State.unlocked.rawValue {
                stats.incr(firstTry ? .exchangeContendedWonFirstTry : .exchangeContendedWonAfterWait)
                if visibleToSpinners {
                    _ = atomic_fetch_sub_u32(slowPathDepth, 1)
                }
                return
            }
            firstTry = false

            if !visibleToSpinners {
                _ = atomic_fetch_add_u32(slowPathDepth, 1)
                visibleToSpinners = true
            }

            stats.incr(.futexWaitCalls)
            let waitResult = futex_wait(storage, State.contended.rawValue)
            switch waitResult {
            case 0: break
            case 11: stats.incr(.futexWaitEAGAIN)
            case 4: stats.incr(.futexWaitInterrupted)
            default:
                fatalError("Unknown error occurred while attempting to acquire a Mutex: \(waitResult)")
            }
        }
    }

    @inlinable
    public func unlock() {
        guard atomic_exchange_release_u32(storage, State.unlocked.rawValue) == State.contended.rawValue else {
            return
        }
        unlockSlow()
    }

    @usableFromInline
    func unlockSlow() {
        stats.incr(.futexWakeCalls)
        _ = futex_wake(storage, 1)
    }
}
#endif
