//===----------------------------------------------------------------------===//
// EpochMutex — release-epoch spin mutex
//
// Three separate cache lines:
//   Line 1: [lockWord: UInt32] [value: Value]  — owner's hot path
//   Line 2: [epoch: UInt32]                     — monotonic release counter
//
// Spinners watch the epoch line (no interference with owner's value writes).
// When epoch changes, each spinner gets ONE CAS attempt on lockWord, then
// goes back to watching epoch. No thundering herd — spinners that arrived
// at different times see different epoch snapshots and stagger their attempts.
//
// Protocol:
//   lock():
//     Fast path: CAS(lockWord, 0→1)
//     Spin:  snapshot epoch. Pause. If epoch changed, try ONE CAS on lockWord.
//            If CAS fails, snapshot new epoch, resume waiting.
//            If lockWord shows contended (2), break to kernel phase.
//     Park:  exchange(lockWord, 2) + futex_wait.
//
//   unlock():
//     exchange(lockWord, 0)         — release lock
//     atomic_add(epoch, 1)          — signal spinners (separate cache line)
//     if prev==2: futex_wake(1)     — wake parked threads
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class EpochMutex<Value>: @unchecked Sendable {
    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let epoch: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public let spinTries: Int
    public let pauseBase: UInt32

    public init(_ initialValue: Value, spinTries: Int = 40, pauseBase: UInt32 = 16) {
        #if arch(arm64)
        let cacheLineSize = 128
        #else
        let cacheLineSize = 64
        #endif

        let epochOffset = cacheLineSize
        let valueOffset = Swift.max(
            MemoryLayout<UInt32>.stride,
            MemoryLayout<Value>.alignment
        )
        // lockWord + value colocated (line 1), epoch on line 2
        let totalSize = epochOffset + MemoryLayout<UInt32>.stride
        let allocSize = Swift.max(totalSize, valueOffset + MemoryLayout<Value>.stride)
        let alignment = Swift.max(cacheLineSize, MemoryLayout<Value>.alignment)

        buffer = .allocate(byteCount: allocSize + cacheLineSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: 0)
        valuePtr = (buffer + valueOffset).assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
        epoch = (buffer + epochOffset).assumingMemoryBound(to: UInt32.self)
        epoch.initialize(to: 0)
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
        if atomic_cas_acquire_u32(word, 0, 1) { return }
        lockSlow()
    }

    @inlinable
    func lockSlow() {
        // Snapshot current epoch. When it changes, a release happened.
        var lastEpoch = atomic_load_relaxed_u32(epoch)
        var spinsRemaining = spinTries

        repeat {
            // Pause between checks — reduces cache traffic on epoch line
            for _ in 0..<pauseBase { spin_loop_hint() }

            // Check if a release happened (epoch changed)
            let currentEpoch = atomic_load_relaxed_u32(epoch)
            if currentEpoch != lastEpoch {
                // A release occurred. One CAS attempt on lockWord.
                if atomic_cas_acquire_u32(word, 0, 1) { return }
                // Lost race. Update snapshot, keep watching.
                lastEpoch = currentEpoch
            }

            // Early exit: if waiters parked, join kernel queue.
            // This is the only lockWord read in the spin loop.
            let state = atomic_load_relaxed_u32(word)
            if state == 2 { break }

            spinsRemaining &-= 1
        } while spinsRemaining > 0

        // Kernel phase
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
        let prev = atomic_exchange_release_u32(word, 0)
        // Bump epoch AFTER releasing lock — spinners see the change
        // and find lockWord==0 when they CAS.
        atomic_store_release_u32(epoch, atomic_load_relaxed_u32(epoch) &+ 1)
        if prev == 2 {
            _ = futex_wake(word, 1)
        }
    }
}
#endif
