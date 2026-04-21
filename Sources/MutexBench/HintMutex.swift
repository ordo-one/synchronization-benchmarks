//===----------------------------------------------------------------------===//
// HintMutex — Disruptor-inspired spin-on-hint mutex
//
// Spinners watch a separate "hint" cache line instead of the lock word.
// The unlocker sets the hint before releasing, so spinner reads never
// interfere with the owner's value writes on the lock cache line.
//
// Layout (3 separate cache lines on x86, or 2 on ARM with 128B lines):
//   Line 1: [lockWord: UInt32] [value: Value]  — owner's hot path
//   Line 2: [hint: UInt32]                      — spinners watch this
//
// Protocol:
//   lock():
//     Fast path: CAS(lockWord, 0→1)
//     Spin:  watch hint (not lockWord). When hint==1, try CAS(lockWord, 0→1).
//            If CAS fails, reset hint expectation and resume watching.
//     Park:  exchange(lockWord, 2) + futex_wait as usual.
//
//   unlock():
//     store(hint, 1)            — wake spinners (no syscall, just cache line write)
//     exchange(lockWord, 0)     — release lock
//     if prev==2: futex_wake(1) — wake parked threads
//     store(hint, 0)            — reset hint for next acquire cycle
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class HintMutex<Value>: @unchecked Sendable {
    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let hint: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public let spinTries: Int
    public let pauseBase: UInt32

    public init(_ initialValue: Value, spinTries: Int = 40, pauseBase: UInt32 = 32) {
        // Layout: [lockWord | padding... | hint | padding... | value]
        // Each on its own cache line.
        #if arch(arm64)
        let cacheLineSize = 128
        #else
        let cacheLineSize = 64
        #endif

        let hintOffset = cacheLineSize  // hint on separate line from lock word
        let valueOffset = cacheLineSize * 2  // value on separate line from both
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(cacheLineSize, MemoryLayout<Value>.alignment)

        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: 0)
        hint = (buffer + hintOffset).assumingMemoryBound(to: UInt32.self)
        hint.initialize(to: 0)
        valuePtr = (buffer + valueOffset).assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
        self.spinTries = spinTries
        self.pauseBase = pauseBase
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
        // Fast path: uncontended
        if atomic_cas_acquire_u32(word, 0, 1) { return }
        lockSlow()
    }

    @inlinable
    func lockSlow() {
        // --- Spin phase: watch hint, not lock word ---
        // Spinners read hint (its own cache line). Owner writes value
        // (lock word's cache line) without interference from spinner reads.
        // When hint==1, the lock was just released — try CAS on lock word.
        var spinsRemaining = spinTries

        repeat {
            // Check hint — is a release being signaled?
            let h = atomic_load_relaxed_u32(hint)
            if h != 0 {
                // Release signaled. Try to acquire the actual lock.
                if atomic_cas_acquire_u32(word, 0, 1) { return }
                // Lost the race. Another spinner or woken thread got it.
                // Fall through to pause and retry.
            }

            // Also check lock word for contended state (early-exit).
            // This is the only lock-word read in the spin loop.
            let state = atomic_load_relaxed_u32(word)
            if state == 0, atomic_cas_acquire_u32(word, 0, 1) { return }
            if state == 2 { break }  // waiters parked, join kernel queue

            spinsRemaining &-= 1
            for _ in 0..<pauseBase { spin_loop_hint() }
        } while spinsRemaining > 0

        // --- Kernel phase ---
        while true {
            if atomic_exchange_acquire_u32(word, 2) == 0 { return }
            let err = futex_wait(word, 2)
            switch err {
            case 0, 11, 4: break
            default: fatalError("Unknown error in futex_wait: \(err)")
            }
        }
    }

    @inlinable
    public func unlock() {
        // Signal spinners BEFORE releasing the lock.
        // Spinners watching hint will see this and prepare to CAS.
        atomic_store_release_u32(hint, 1)

        // Release the lock.
        let prev = atomic_exchange_release_u32(word, 0)

        // Wake parked threads if any.
        if prev == 2 {
            _ = futex_wake(word, 1)
        }

        // Reset hint. Next acquire cycle starts clean.
        // Use release to ensure the lock-word store is visible first.
        atomic_store_release_u32(hint, 0)
    }
}
#endif
