//===----------------------------------------------------------------------===//
// AdaptiveSpinMutex — glibc-style EWMA learned spin budget
//
// Per-lock state tracks average successful spin count via exponential weighted
// moving average. Budget for next acquire = min(cap, 2 * learned + 10).
// Low-contention locks learn small budgets. High-contention locks grow.
//
// glibc formula:
//   max_cnt = min(max_adaptive_count, mutex->__spins * 2 + 10)
//   after acquire: mutex->__spins += (cnt - mutex->__spins) / 8
//
// Layout:
//   Line 1: [lockWord: UInt32 | padding | value: Value]
//   Line 2: [learnedSpins: UInt32]  — updated on acquire path
//
// Keeping learnedSpins on separate cache line avoids false sharing with
// owner's value writes during spin phase.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class AdaptiveSpinMutex<Value>: @unchecked Sendable {
    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let learnedSpins: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public let maxCap: UInt32
    public let pauseBase: UInt32

    public init(_ initialValue: Value, maxCap: UInt32 = 100, pauseBase: UInt32 = 128) {
        #if arch(arm64)
        let cacheLineSize = 128
        #else
        let cacheLineSize = 64
        #endif

        let valueOffset = Swift.max(
            MemoryLayout<UInt32>.stride,
            MemoryLayout<Value>.alignment
        )
        let learnedOffset = cacheLineSize
        let totalSize = cacheLineSize + MemoryLayout<UInt32>.stride
        let allocSize = Swift.max(totalSize, valueOffset + MemoryLayout<Value>.stride)
        let alignment = Swift.max(cacheLineSize, MemoryLayout<Value>.alignment)

        buffer = .allocate(byteCount: allocSize + cacheLineSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: 0)
        valuePtr = (buffer + valueOffset).assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
        learnedSpins = (buffer + learnedOffset).assumingMemoryBound(to: UInt32.self)
        learnedSpins.initialize(to: 0)
        self.maxCap = maxCap
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
        let jitter = fast_jitter()
        let mask = pauseBase &- 1

        // Read learned budget (relaxed — single-writer-ish, eventual consistency OK)
        let learned = atomic_load_relaxed_u32(learnedSpins)
        let budget = Swift.min(maxCap, learned &* 2 &+ 10)

        var count: UInt32 = 0
        while count < budget {
            let state = atomic_load_relaxed_u32(word)
            if state == 0, atomic_cas_acquire_u32(word, 0, 1) {
                // Acquired — update EWMA: learned += (count - learned) / 8
                // Signed delta via wrap-safe math
                let delta: Int32 = Int32(bitPattern: count) &- Int32(bitPattern: learned)
                let newLearned = UInt32(bitPattern: Int32(bitPattern: learned) &+ (delta >> 3))
                atomic_store_release_u32(learnedSpins, newLearned)
                return
            }
            if state == 2 { break }

            let pauses = pauseBase &+ (jitter & mask)
            for _ in 0..<pauses { spin_loop_hint() }
            count &+= 1
        }

        // Kernel phase — budget exhausted or early exit
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
        guard atomic_exchange_release_u32(word, 0) == 2 else { return }
        _ = futex_wake(word, 1)
    }
}
#endif
