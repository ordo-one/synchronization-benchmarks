//===----------------------------------------------------------------------===//
// MCSMutex — MCS queue-based lock with futex park fallback
//
// Based on libck `ck_spinlock_mcs` (BSD-2-Clause, Samy Al Bahra 2010-2015).
// https://github.com/concurrencykit/ck/blob/master/include/spinlock/mcs.h
//
// Node layout (raw, per-waiter stack allocation):
//   offset 0:  UInt32 locked  — futex word (1 = wait, 0 = released)
//   offset 4:  UInt32 padding
//   offset 8:  UInt   next    — raw pointer to successor node as UInt
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class MCSMutex<Value>: @unchecked Sendable {
    @usableFromInline let queueStorage: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    @usableFromInline let queueBuffer: UnsafeMutableRawPointer
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>
    @usableFromInline let valueBuffer: UnsafeMutableRawPointer

    @usableFromInline static var nodeSize: Int { 16 }
    @usableFromInline static var nodeAlign: Int { 16 }

    public let spinTries: Int
    public let pauseBase: UInt32

    public init(_ initialValue: Value, spinTries: Int = 200, pauseBase: UInt32 = 128) {
        #if arch(arm64)
        let cacheLineSize = 128
        #else
        let cacheLineSize = 64
        #endif
        self.spinTries = spinTries
        self.pauseBase = pauseBase

        queueBuffer = .allocate(byteCount: cacheLineSize, alignment: cacheLineSize)
        queueStorage = queueBuffer.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        queueStorage.initialize(to: nil)

        valueBuffer = .allocate(
            byteCount: MemoryLayout<Value>.stride,
            alignment: Swift.max(cacheLineSize, MemoryLayout<Value>.alignment)
        )
        valuePtr = valueBuffer.assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
    }

    deinit {
        valuePtr.deinitialize(count: 1)
        valueBuffer.deallocate()
        queueBuffer.deallocate()
    }

    @inlinable
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        // Stack-allocated node via withUnsafeTemporaryAllocation.
        // Scoped to withLock — safe because unlock completes before return.
        return try withUnsafeTemporaryAllocation(
            byteCount: Self.nodeSize, alignment: Self.nodeAlign
        ) { buffer in
            let node = buffer.baseAddress!
            let lockedPtr = node.assumingMemoryBound(to: UInt32.self)
            let nextSlot = (node + 8).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            lockedPtr.pointee = 1
            nextSlot.pointee = nil

            lockRaw(node, lockedPtr, nextSlot)
            defer { unlockRaw(node, nextSlot) }
            return try body(&valuePtr.pointee)
        }
    }

    @usableFromInline
    func lockRaw(
        _ node: UnsafeMutableRawPointer,
        _ lockedPtr: UnsafeMutablePointer<UInt32>,
        _ nextSlot: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) {
        let previousRaw = atomic_exchange_acquire_ptr(queueStorage, node)
        if previousRaw == nil {
            return  // Queue empty, we own lock
        }

        // Link after predecessor
        let previousNextSlot = (previousRaw! + 8)
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        atomic_store_release_ptr(previousNextSlot, node)

        // Spin on own locked. Acquire load pairs with predecessor's release.
        var spinsRemaining = spinTries
        let mask = pauseBase &- 1
        let jitter = fast_jitter()

        while spinsRemaining > 0 {
            if atomic_load_acquire_u32(lockedPtr) == 0 { return }
            let pauses = pauseBase &+ (jitter & mask)
            for _ in 0..<pauses { spin_loop_hint() }
            spinsRemaining &-= 1
        }

        // Park on futex
        while atomic_load_acquire_u32(lockedPtr) == 1 {
            let err = futex_wait(lockedPtr, 1)
            switch err {
            case 0, 11, 4: break
            default: fatalError("futex_wait: \(err)")
            }
        }
    }

    @usableFromInline
    func unlockRaw(
        _ node: UnsafeMutableRawPointer,
        _ nextSlot: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) {
        var nextRaw = atomic_load_acquire_ptr(nextSlot)
        if nextRaw == nil {
            if atomic_cas_release_ptr(queueStorage, node, nil) {
                return
            }
            while nextRaw == nil {
                spin_loop_hint()
                nextRaw = atomic_load_acquire_ptr(nextSlot)
            }
        }

        let nextLockedPtr = nextRaw!.assumingMemoryBound(to: UInt32.self)
        atomic_store_release_u32(nextLockedPtr, 0)
        _ = futex_wake(nextLockedPtr, 1)
    }
}
#endif
