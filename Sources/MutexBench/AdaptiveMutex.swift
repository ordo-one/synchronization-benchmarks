//===----------------------------------------------------------------------===//
// pthread_mutex_t with PTHREAD_MUTEX_ADAPTIVE_NP — glibc's built-in
// adaptive spinning (100 spins, exponential backoff + jitter).
//
// Identical to NIOLock/pthread_mutex except for the mutex type attribute.
// On musl/Bionic, falls back to PTHREAD_MUTEX_NORMAL (no spin).
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public final class AdaptiveMutex<Value>: @unchecked Sendable {
    @usableFromInline let mutex: UnsafeMutablePointer<pthread_mutex_t>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public init(_ initialValue: Value) {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        adaptive_mutex_init(mutex)

        valuePtr = .allocate(capacity: 1)
        valuePtr.initialize(to: initialValue)
    }

    deinit {
        adaptive_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
        valuePtr.deinitialize(count: 1)
        valuePtr.deallocate()
    }

    @inlinable
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        adaptive_mutex_lock(mutex)
        defer { adaptive_mutex_unlock(mutex) }
        return try body(&valuePtr.pointee)
    }
}
#endif
