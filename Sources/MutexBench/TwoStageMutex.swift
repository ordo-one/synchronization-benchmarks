//===----------------------------------------------------------------------===//
// TwoStageMutex — two-stage spin before park
//
// Stage 1: wide spacing (base=128) with RDTSC jitter. Catches owner releases
//          without interfering with their cache line access.
// Stage 2: tight spacing (base=32) with RDTSC jitter. Catches late releases
//          cheaply before paying the futex park cost.
//
// Total budget bounded: stage1Spins * 128 + stage2Spins * 32 pauses.
// Default: 5 + 5 = ~800 pauses = ~10-30µs depending on CPU.
//
// Protocol unchanged from OptimalMutex (early-exit-on-contended, 3-state futex).
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class TwoStageMutex<Value>: @unchecked Sendable {
    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public let stage1Spins: Int
    public let stage1Base: UInt32
    public let stage2Spins: Int
    public let stage2Base: UInt32

    public init(
        _ initialValue: Value,
        stage1Spins: Int = 5,
        stage1Base: UInt32 = 128,
        stage2Spins: Int = 5,
        stage2Base: UInt32 = 32
    ) {
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
        self.stage1Spins = stage1Spins
        self.stage1Base = stage1Base
        self.stage2Spins = stage2Spins
        self.stage2Base = stage2Base
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

        // Stage 1: wide spacing
        let mask1 = stage1Base &- 1
        var tries1 = stage1Spins
        while tries1 > 0 {
            let state = atomic_load_relaxed_u32(word)
            if state == 0, atomic_cas_acquire_u32(word, 0, 1) { return }
            if state == 2 { break }
            let pauses = stage1Base &+ (jitter & mask1)
            for _ in 0..<pauses { spin_loop_hint() }
            tries1 &-= 1
        }

        // Stage 2: tight spacing — catch late releases cheap before park
        let mask2 = stage2Base &- 1
        var tries2 = stage2Spins
        while tries2 > 0 {
            let state = atomic_load_relaxed_u32(word)
            if state == 0, atomic_cas_acquire_u32(word, 0, 1) { return }
            if state == 2 { break }
            let pauses = stage2Base &+ (jitter & mask2)
            for _ in 0..<pauses { spin_loop_hint() }
            tries2 &-= 1
        }

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
        guard atomic_exchange_release_u32(word, 0) == 2 else { return }
        _ = futex_wake(word, 1)
    }
}
#endif
