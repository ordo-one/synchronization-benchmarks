//===----------------------------------------------------------------------===//
// Faithful copy of Swift stdlib Synchronization.Mutex Linux implementation.
// Source: stdlib/public/Synchronization/Mutex/LinuxImpl.swift (release/6.2)
//
// Uses PI-futex (FUTEX_LOCK_PI_PRIVATE) with fixed spin count.
// C atomics + futex shims replace stdlib-internal Atomic<UInt32> and
// @_extern LLVM intrinsics.
//
// Modifications from stdlib:
//   - Atomic<UInt32>      → colocated UInt32 in same allocation as Value
//   - _Cell<Value>        → UnsafeMutablePointer<Value> into same buffer
//   - @_extern intrinsics → C inline spin_loop_hint()
//   - _fastPath()         → plain if (branch prediction hint only)
//   - @_staticExclusiveOnly, @_alwaysEmitIntoClient → removed
//   - spinTries is a configurable init parameter
//   - Generic over Value, matching stdlib Mutex<Value> API
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

/// Drop-in copy of `Synchronization.Mutex<Value>` Linux implementation.
/// Uses PI-futex + fixed spin loop, matching stdlib release/6.2 behavior.
///
/// Memory layout matches stdlib: lock word and value are in the same
/// allocation (same cache line), so contention behavior is identical.
///
/// The lock word stores:
///   0                      → unlocked
///   TID                    → locked by thread (uncontended)
///   TID | FUTEX_WAITERS    → locked by thread (contended, kernel knows)
public final class SynchronizationMutex<Value>: @unchecked Sendable {
    // Single allocation: [UInt32 lock_word][padding][Value]
    // Colocated on same cache line, matching stdlib Mutex<Value> layout.
    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    /// Number of spin iterations before falling to kernel.
    /// Stdlib: 1000 on x86, 100 on arm64. Configurable here for benchmarking.
    public let spinTries: Int

    public init(_ initialValue: Value, spinTries: Int = Int(default_spin_tries())) {
        // Layout: [UInt32][padding to Value alignment][Value]
        let valueOffset = Swift.max(
            MemoryLayout<UInt32>.stride,
            MemoryLayout<Value>.alignment
        )
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(
            MemoryLayout<UInt32>.alignment,
            MemoryLayout<Value>.alignment
        )

        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: 0)
        valuePtr = (buffer + valueOffset).assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
        self.spinTries = spinTries
    }

    deinit {
        valuePtr.deinitialize(count: 1)
        buffer.deallocate()
    }

    // MARK: - withLock (primary API, matches stdlib Mutex<Value>)

    @inlinable
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body(&valuePtr.pointee)
    }

    // MARK: - Lock

    @inlinable
    public func lock() {
        let selfId = mutex_gettid()

        if atomic_cas_acquire_u32(word, 0, selfId) {
            return
        }

        lockSlow(selfId)
    }

    /// Stdlib: _lockSlow(_ selfId: UInt32)
    /// Spin phase followed by FUTEX_LOCK_PI kernel block.
    @usableFromInline
    func lockSlow(_ selfId: UInt32) {
        // --- Spin phase ---
        // Note: with PI-futex, spinning is only effective before any thread
        // parks in the kernel. Once FUTEX_WAITERS is set, FUTEX_UNLOCK_PI
        // does atomic direct handoff (TID_old → TID_new) — lock word never
        // passes through 0, so spinning can never succeed.
        if spinTries > 0 {
            var tries = spinTries

            repeat {
                let state = atomic_load_relaxed_u32(word)

                if state == 0, atomic_cas_acquire_u32(word, 0, selfId) {
                    return
                }

                tries &-= 1
                spin_loop_hint()
            } while tries > 0
        }

        // --- Kernel phase ---
        while true {
            switch futex_lock_pi(word) {
            case 0:
                return
            case 4, 11: // EINTR, EAGAIN
                continue
            case 35: // EDEADLK
                fatalError("Recursive call to lock SynchronizationMutex")
            default:
                fatalError("Unknown error in futex_lock_pi")
            }
        }
    }

    // MARK: - Try Lock

    @inlinable
    public func tryLock() -> Bool {
        let selfId = mutex_gettid()

        if atomic_cas_acquire_u32(word, 0, selfId) {
            return true
        }

        return tryLockSlow()
    }

    @usableFromInline
    func tryLockSlow() -> Bool {
        switch futex_trylock_pi(word) {
        case 0:
            return true
        case 35: // EDEADLK
            fatalError("tryLock on already-acquired SynchronizationMutex")
        default:
            return false
        }
    }

    // MARK: - Unlock

    @inlinable
    public func unlock() {
        let selfId = mutex_gettid()

        if atomic_cas_release_u32(word, selfId, 0) {
            return
        }

        unlockSlow()
    }

    @usableFromInline
    func unlockSlow() {
        while true {
            switch futex_unlock_pi(word) {
            case 0:
                return
            case 4: // EINTR
                continue
            case 1: // EPERM
                fatalError("Unlock SynchronizationMutex from non-owning thread")
            default:
                fatalError("Unknown error in futex_unlock_pi")
            }
        }
    }
}
#endif
