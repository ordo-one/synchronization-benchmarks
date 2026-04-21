//===----------------------------------------------------------------------===//
// ParkingLotMutex — Swift port of Amanieu's parking_lot::RawMutex.
//
// Source: github.com/Amanieu/parking_lot (Apache-2.0 / MIT).
// File mirrored: src/raw_mutex.rs.
//
// Algorithm (two-bit state byte, stored here as u32 since CFutexShims has
// no u8 atomics):
//
//   State.locked (bit 0) — lock is held.
//   State.parked (bit 1) — one or more threads are parked in the global
//                          ParkingLot hash table, waiting for release.
//
//   unlocked (0,0)    — free, no parkers.
//   held    (1,0)     — one owner, nobody parked.
//   free+parked (0,1) — not held, but one or more parkers are about to be
//                       unparked or have just raced with a release.
//   held+parked (1,1) — held with at least one parker; unlock must wake
//                       one thread.
//
// Fast path: single compare_exchange 0 → LOCKED.
// Slow path: SpinWait (2^n pauses + sched_yield) while state is held and
// no queue formed; once queue exists or spin budget exhausted, CAS in
// the PARKED bit and ParkingLot.park. On wake, either we were handed the
// lock directly (TOKEN_HANDOFF, fair unlock) or we retry from the top.
//
// Fairness: per-bucket 0-1ms random deadline in ParkingLotCore. When an
// unlock fires after the deadline, it sets HANDOFF and transfers the
// lock to the woken thread without releasing it. Prevents barger-dominates
// long-tails.
//
// Stats instrumentation dispatched via generic `S: StatsSink`. Default
// `NoStats` erases every increment call at compile time. Construct with
// `stats: MutexStats()` for INSTR runs.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class ParkingLotMutex<Value, S: StatsSink>: @unchecked Sendable {
    // State bits. Encoded as u32 (CFutexShims is u32-native); parking_lot
    // upstream uses AtomicU8 — same semantics at this bit width.
    @usableFromInline static var LOCKED: UInt32 { 0b01 }
    @usableFromInline static var PARKED: UInt32 { 0b10 }

    // Unpark token constants, in the parking_lot namespace.
    @usableFromInline static var TOKEN_NORMAL: UInt { 0 }
    @usableFromInline static var TOKEN_HANDOFF: UInt { 1 }

    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let state: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>
    public let stats: S

    public init(_ initialValue: Value, stats: S) {
        self.stats = stats

        // Layout: [state:u32 @0 | padding | value]. State lives on its own
        // word; no false-sharing mitigation beyond that (parking_lot itself
        // provides no padding — users wrap Value in whatever they need).
        let headerBytes = 4
        let valueAlign = Swift.max(MemoryLayout<Value>.alignment, 1)
        let valueOffset = (headerBytes + valueAlign - 1) / valueAlign * valueAlign
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(MemoryLayout<UInt32>.alignment, MemoryLayout<Value>.alignment)
        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        state = buffer.assumingMemoryBound(to: UInt32.self)
        state.initialize(to: 0)
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
        if atomic_cas_acquire_u32(state, 0, Self.LOCKED) {
            stats.incr(.lockFastHit)
            return
        }
        lockSlow()
    }

    @inline(never)
    @usableFromInline
    func lockSlow() {
        stats.incr(.lockSlowEntries)
        var sw = SpinWait()
        var s = atomic_load_relaxed_u32(state)

        while true {
            // Grab lock if free, even if PARKED bit is set. Matches
            // raw_mutex.rs — a just-arriving thread can barge past parked
            // waiters when the holder released; fair unlock is what
            // prevents permanent starvation.
            if s & Self.LOCKED == 0 {
                if atomic_cas_acquire_u32(state, s, s | Self.LOCKED) {
                    return
                }
                s = atomic_load_relaxed_u32(state)
                continue
            }

            // No queue yet → spin with backoff schedule.
            if s & Self.PARKED == 0 && sw.spin() {
                s = atomic_load_relaxed_u32(state)
                continue
            }

            // Set PARKED bit so an unlocker knows to wake.
            if s & Self.PARKED == 0 {
                if !atomic_cas_acquire_u32(state, s, s | Self.PARKED) {
                    s = atomic_load_relaxed_u32(state)
                    continue
                }
            }

            // Park. validate() runs under bucket lock: confirms state is
            // still held-with-parkers — if not, the unlocker already
            // raced past and we should retry instead of blocking.
            stats.incr(.parkAttempts)
            let addr = UInt(bitPattern: UnsafeRawPointer(state))
            let result = ParkingLot.park(
                addr: addr,
                validate: { atomic_load_relaxed_u32(self.state) == Self.LOCKED | Self.PARKED },
                beforeSleep: {},
                parkToken: 0
            )

            switch result {
            case .unparked(let token):
                // Fair handoff — unlocker already stored LOCKED on our
                // behalf; we own the lock, skip retry.
                if token == Self.TOKEN_HANDOFF {
                    stats.incr(.handoffReceived)
                    return
                }
            case .invalid:
                // Race with release: state changed between our enqueue
                // and bucket lock. Fall through, re-read, try again.
                stats.incr(.parkInvalidRace)
            }

            sw.reset()
            s = atomic_load_relaxed_u32(state)
        }
    }

    @inlinable
    public func unlock() {
        if atomic_cas_release_u32(state, Self.LOCKED, 0) { return }
        unlockSlow()
    }

    @inline(never)
    @usableFromInline
    func unlockSlow() {
        let addr = UInt(bitPattern: UnsafeRawPointer(state))
        let s = self.state
        let st = self.stats
        _ = ParkingLot.unparkOne(addr: addr) { result in
            if result.unparkedThreads != 0 {
                st.incr(.unparkFoundWaiter)
            } else {
                st.incr(.unparkEmpty)
            }
            if result.haveMoreThreads { st.incr(.unparkHaveMoreThreads) }
            // Fair unlock: bucket deadline elapsed. Hand the lock off
            // directly to the waking thread; keep LOCKED bit set.
            if result.unparkedThreads != 0 && result.beFair {
                st.incr(.fairUnparkTriggered)
                if !result.haveMoreThreads {
                    // Queue drained — drop PARKED, keep LOCKED.
                    atomic_store_relaxed_u32(s, ParkingLotMutex.LOCKED)
                }
                return ParkingLotMutex.TOKEN_HANDOFF
            }
            // Normal unlock: release LOCKED, keep PARKED iff more waiters.
            if result.haveMoreThreads {
                atomic_store_release_u32(s, ParkingLotMutex.PARKED)
            } else {
                atomic_store_release_u32(s, 0)
            }
            st.incr(.futexWakeCalls)
            return ParkingLotMutex.TOKEN_NORMAL
        }
    }
}

extension ParkingLotMutex where S == NoStats {
    public convenience init(_ initialValue: Value) {
        self.init(initialValue, stats: NoStats())
    }
}

#endif
