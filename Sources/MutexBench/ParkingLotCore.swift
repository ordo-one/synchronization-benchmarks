//===----------------------------------------------------------------------===//
// ParkingLotCore — Swift port of Amanieu's parking_lot_core crate.
//
// Source: github.com/Amanieu/parking_lot (Apache-2.0 / MIT).
// Files mirrored: core/src/parking_lot.rs, core/src/spinwait.rs,
//                 core/src/thread_parker/linux.rs.
//
// The parking_lot design puts a single global hash-table of "buckets" behind
// all mutex/condvar/rwlock waiters. Each bucket carries a small word-lock and
// an intrusive FIFO queue of ThreadData entries keyed by the waiting
// mutex's address. `park()` hashes the address, locks the bucket, enqueues
// the current thread, then futex-waits on a per-thread parker word. `unpark()`
// hashes, locks, splices one match out, wakes its parker. Fair handoff is
// picked by a per-bucket 0-1ms random timeout.
//
// Scope: minimum subset needed to implement RawMutex correctly. This is
// NOT a drop-in replacement for parking_lot_core.
//
// API surface OMITTED (present upstream in parking_lot.rs):
//   - Timed park. `park()` takes no `timeout: Option<Instant>`; upstream
//     parking_lot.rs `parking_lot::park()` at line 471 accepts one and passes
//     it to `thread_parker.park_until(timeout)`.
//   - Timeout cleanup path. Upstream's `timed_out` callback (parking_lot.rs
//     line ~516) splices the thread back out of the bucket queue and clears
//     PARKED if it was the last waiter. Without timeouts this path is
//     unreachable, but any future timed-park addition MUST re-acquire the
//     bucket lock to re-walk the queue for the caller — unlocked cleanup
//     races unpark.
//   - `ParkResult.TimedOut`. Only `.unparked` / `.invalid` are returned.
//   - `park_token`. Upstream ThreadData stores the park-side token so that
//     `unpark_filter` / `unpark_requeue` can inspect it under the bucket
//     lock. Our `ThreadData` accepts a `parkToken` argument for source
//     compatibility but drops it on the floor.
//   - `unpark_all`, `unpark_filter`, `unpark_requeue` (parking_lot.rs
//     line ~813 and siblings). Only `unpark_one` is implemented.
//   - Pair-bucket locking. `unpark_requeue` needs to lock two buckets
//     ordered by address to avoid deadlock; absent here.
//   - Deadlock-detection hooks (`deadlock::on_unpark` / `on_park`).
//   - Requeue-safe key checking. The upstream bucket walker re-reads
//     ThreadData.key under the bucket lock because `unpark_requeue` mutates
//     it; our unpark_one is the only writer so the single-read is fine
//     today, but it's not robust to adding requeue APIs later.
//
// Implementation deviations (vs what IS implemented):
//   - Hash table is fixed at 2048 buckets (no dynamic resize). Load factor
//     ≈ 6 at 384-task ContentionScaling; bucket-lock traversal stays cheap.
//   - Bucket mutex is a TTAS spinlock with `spin_loop_hint`. Upstream
//     parking_lot_core uses its own WordLock (spin-then-park). Using WordLock
//     here would make ParkingLotCore self-referential; TTAS is a bench-
//     fidelity deviation only on meta-infra (not the algorithm under test).
//   - Buckets are cache-line aligned via a raw backing buffer: one single
//     `posix_memalign`-equivalent 64-byte-aligned allocation sized
//     `64 * bucketCount`, with each Bucket laid out at stride 64. Matches
//     upstream parking_lot.rs line 90 `#[repr(align(64))]` semantics —
//     adjacent buckets never share a cache line, bucket lockWord is at
//     offset 0 of its own line. (Swift `class` instances are separately
//     heap-allocated but the allocator doesn't guarantee 64-byte alignment
//     or inter-instance spacing, so the class-based earlier version could
//     suffer false sharing; this version cannot.)
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims
import Glibc

// MARK: - Per-thread parker

@usableFromInline
final class ThreadData {
    // Futex word controlling park/unpark handshake. Matches upstream
    // thread_parker/linux.rs polarity:
    //   1 = parked (thread is blocking in FUTEX_WAIT)
    //   0 = unparked (thread should exit park loop)
    // `prepareParker()` stores 1 before enqueue; `parkUntilWoken()` loops
    // while word != 0, issuing `FUTEX_WAIT(futex, 1)` which sleeps only
    // while the word still reads 1; `wake()` stores 0 then FUTEX_WAKE.
    let futex: UnsafeMutablePointer<UInt32>

    // Intrusive queue fields — ONLY mutated while the owning bucket's lock
    // is held. `next` is an unowned reference: the queued ThreadData
    // belongs to the parked thread (thread-local), which is blocked and
    // therefore alive while enqueued.
    var next: Unmanaged<ThreadData>?

    // Key = parking address (the mutex's state-word pointer bit-casted to
    // UInt). Used by unpark_one to skip over entries parked on other
    // addresses that happen to hash into the same bucket.
    var key: UInt = 0

    // Token passed park ↔ unpark. TOKEN_NORMAL (0) = "lock is released,
    // try to reacquire". TOKEN_HANDOFF (1) = "lock was handed off to you
    // already locked".
    var unparkToken: UInt = 0

    init() {
        let p = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        p.initialize(to: 0)
        self.futex = p
    }

    deinit {
        futex.deinitialize(count: 1)
        futex.deallocate()
    }

    func prepareParker() {
        // Set parked flag = 1 BEFORE enqueue + before the bucket unlock
        // that makes us visible to an unparker.
        atomic_store_relaxed_u32(futex, 1)
    }

    func parkUntilWoken() {
        while atomic_load_acquire_u32(futex) != 0 {
            // futex_wait(addr, 1) sleeps iff *addr == 1. If word already
            // flipped to 0 (unpark raced us), returns EAGAIN (11) and
            // the outer load exits the loop. EINTR (4) on signal is also
            // safe — loop rechecks.
            _ = futex_wait(futex, 1)
        }
    }

    func wake() {
        atomic_store_release_u32(futex, 0)
        _ = futex_wake(futex, 1)
    }
}

// MARK: - Thread-local ThreadData storage

// `pthread_key_t` + destructor: a ThreadData is allocated on first park(),
// attached to the OS thread, and released when the thread exits.
enum ParkingLotThread {
    static let keyStorage: pthread_key_t = {
        var k: pthread_key_t = 0
        _ = pthread_key_create(&k) { raw in
            guard let raw else { return }
            Unmanaged<ThreadData>.fromOpaque(raw).release()
        }
        return k
    }()

    static func current() -> ThreadData {
        let k = keyStorage
        if let raw = pthread_getspecific(k) {
            return Unmanaged<ThreadData>.fromOpaque(raw).takeUnretainedValue()
        }
        let td = ThreadData()
        let raw = Unmanaged.passRetained(td).toOpaque()
        _ = pthread_setspecific(k, raw)
        return td
    }
}

// MARK: - Bucket

// Value-struct so the fields are inline in the aligned raw buffer. Field
// order matters: `lockWord` MUST be at offset 0 because the bucket cache-
// line lock-pointer is derived by just re-binding the cell's raw pointer
// as `UnsafeMutablePointer<UInt32>`. Swift preserves declaration order
// for stored properties within a module, so this is stable.
@usableFromInline
struct Bucket {
    // TTAS spinlock — CAS 0→1 to acquire, store 0 to release.
    var lockWord: UInt32 = 0
    // Fair-unlock xorshift seed. Packed next to lockWord to fit both hot
    // state words in the first 8 bytes of the cache line.
    var fairSeed: UInt32

    // Intrusive FIFO queue. Enqueue at tail; scan head→tail in unpark_one.
    var head: Unmanaged<ThreadData>? = nil
    var tail: Unmanaged<ThreadData>? = nil

    // Fair-unlock deadline (CLOCK_MONOTONIC ns). Same idea as parking_lot:
    // if unpark_one runs after deadline, return be_fair=true so the
    // unlocker hands the lock directly to the woken thread (TOKEN_HANDOFF).
    // Deadline = now + rand(0, 1ms).
    var fairDeadline: UInt64 = 0

    init(seed: UInt32) {
        self.fairSeed = seed == 0 ? 1 : seed
        self.fairDeadline = mutex_clock_ns() &+ UInt64(Bucket.nextFairInterval(&self.fairSeed))
    }

    static func nextFairInterval(_ seed: inout UInt32) -> UInt32 {
        // xorshift32 — returns 0..1_000_000 (ns), matches parking_lot
        // FairTimeout random interval of 0-1ms.
        seed ^= seed &<< 13
        seed ^= seed &>> 17
        seed ^= seed &<< 5
        return seed % 1_000_000
    }
}

// Bucket spinlock operations — take the bucket's lockWord pointer directly
// (derived from the cell's raw base at offset 0). Avoids `&ptr.pointee.lockWord`
// exclusivity noise + keeps atomics on a stable address.
@inline(__always)
func bucketAcquire(_ lp: UnsafeMutablePointer<UInt32>) {
    if atomic_cas_acquire_u32(lp, 0, 1) { return }
    bucketAcquireSlow(lp)
}

@inline(never)
func bucketAcquireSlow(_ lp: UnsafeMutablePointer<UInt32>) {
    var backoff: UInt32 = 1
    while true {
        // TTAS: re-check load before re-CASing to reduce RFO traffic.
        while atomic_load_relaxed_u32(lp) != 0 {
            for _ in 0..<backoff { spin_loop_hint() }
            if backoff < 64 { backoff &*= 2 } else { thread_yield() }
        }
        if atomic_cas_acquire_u32(lp, 0, 1) { return }
    }
}

@inline(__always)
func bucketRelease(_ lp: UnsafeMutablePointer<UInt32>) {
    atomic_store_release_u32(lp, 0)
}

// MARK: - ParkingLot hash table + API

public enum ParkResult {
    case unparked(UInt)  // unpark token
    case invalid         // validate() returned false
}

public struct UnparkResult {
    public var unparkedThreads: Int
    public var haveMoreThreads: Bool
    public var beFair: Bool
}

public enum ParkingLot {
    // 2048 buckets — covers up to ~600 threads at parking_lot's 3× load
    // factor. ContentionScaling peaks at 384. Fixed-size; no resize.
    static let bucketCount: Int = 2048
    static let hashBits: UInt = 11  // log2(2048)

    // Cache-line stride per bucket. x86_64 CPUs use 64-byte lines — matches
    // upstream #[repr(align(64))]. Apple Silicon / ARM Cortex-A use 128-byte
    // lines; a 64B stride would leave two adjacent buckets on the same line,
    // reintroducing the false sharing the alignment fix was meant to cure.
    #if arch(arm64)
    static let bucketStride: Int = 128
    #else
    static let bucketStride: Int = 64
    #endif

    // Single aligned raw allocation — 64-byte alignment at the base + a
    // 64-byte stride guarantees every bucket's lockWord owns its own line.
    nonisolated(unsafe) static let bucketsBase: UnsafeMutableRawPointer = {
        precondition(MemoryLayout<Bucket>.stride <= bucketStride,
                     "Bucket larger than cache line; widen bucketStride")
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bucketStride * bucketCount,
            alignment: bucketStride
        )
        var seed: UInt32 = 0x9E37_79B9
        for i in 0..<bucketCount {
            seed ^= seed &<< 13
            seed ^= seed &>> 17
            seed ^= seed &<< 5
            let bp = (raw + i * bucketStride).assumingMemoryBound(to: Bucket.self)
            bp.initialize(to: Bucket(seed: seed &+ UInt32(i &+ 1)))
        }
        return raw
    }()

    @inline(__always)
    static func bucketCellBase(_ i: Int) -> UnsafeMutableRawPointer {
        bucketsBase + i * bucketStride
    }

    @inline(__always)
    static func bucketPointer(_ i: Int) -> UnsafeMutablePointer<Bucket> {
        bucketCellBase(i).assumingMemoryBound(to: Bucket.self)
    }

    // lockWord is at offset 0 of each cell (first field of Bucket struct).
    @inline(__always)
    static func bucketLockPointer(_ i: Int) -> UnsafeMutablePointer<UInt32> {
        bucketCellBase(i).assumingMemoryBound(to: UInt32.self)
    }

    // Fibonacci hash — multiply by 2^64/φ, take top `hashBits` bits.
    static func hash(_ addr: UInt) -> Int {
        let h = addr &* 0x9E37_79B9_7F4A_7C15
        return Int(h &>> (64 - hashBits))
    }

    /// Park the current thread on `addr`. `validate` is run under the bucket
    /// lock after enqueue; if it returns false, abort without blocking.
    /// `beforeSleep` runs after the bucket is unlocked, before the futex
    /// wait — parking_lot uses this for deadlock detection hooks. Returns
    /// `.unparked(token)` on wake, `.invalid` if validate rejected.
    public static func park(
        addr: UInt,
        validate: () -> Bool,
        beforeSleep: () -> Void,
        parkToken: UInt
    ) -> ParkResult {
        let idx = hash(addr)
        let b = bucketPointer(idx)
        let lp = bucketLockPointer(idx)

        bucketAcquire(lp)
        if !validate() {
            bucketRelease(lp)
            return .invalid
        }

        let td = ParkingLotThread.current()
        td.key = addr
        td.next = nil
        td.unparkToken = 0
        td.prepareParker()

        let entry = Unmanaged.passUnretained(td)
        if let t = b.pointee.tail {
            t.takeUnretainedValue().next = entry
        } else {
            b.pointee.head = entry
        }
        b.pointee.tail = entry

        bucketRelease(lp)
        beforeSleep()

        td.parkUntilWoken()
        return .unparked(td.unparkToken)
    }

    /// Wake (at most) one thread parked on `addr`. `callback` runs under the
    /// bucket lock with the unpark result — it inspects `haveMoreThreads`
    /// and `beFair` to decide whether to store the lock's next state as
    /// PARKED or released, and returns the token the wakee should see.
    @discardableResult
    public static func unparkOne(
        addr: UInt,
        callback: (UnparkResult) -> UInt
    ) -> UnparkResult {
        let idx = hash(addr)
        let b = bucketPointer(idx)
        let lp = bucketLockPointer(idx)

        bucketAcquire(lp)

        // Walk queue: splice first entry matching `addr`.
        var prev: Unmanaged<ThreadData>? = nil
        var cur = b.pointee.head
        var found: Unmanaged<ThreadData>? = nil
        while let c = cur {
            let cd = c.takeUnretainedValue()
            let nxt = cd.next
            if cd.key == addr {
                if let p = prev {
                    p.takeUnretainedValue().next = nxt
                } else {
                    b.pointee.head = nxt
                }
                if let t = b.pointee.tail, t.toOpaque() == c.toOpaque() {
                    b.pointee.tail = prev
                }
                cd.next = nil
                found = c
                break
            }
            prev = c
            cur = nxt
        }

        // Check whether any further entries still park on this address.
        var more = false
        var scan = b.pointee.head
        while let s = scan {
            let sd = s.takeUnretainedValue()
            if sd.key == addr { more = true; break }
            scan = sd.next
        }

        // Fair handoff decision: if found a waiter AND bucket deadline
        // elapsed, flag be_fair and roll a fresh deadline.
        let now = mutex_clock_ns()
        var fair = false
        if found != nil && now >= b.pointee.fairDeadline {
            fair = true
            b.pointee.fairDeadline = now &+ UInt64(Bucket.nextFairInterval(&b.pointee.fairSeed))
        }

        let result = UnparkResult(
            unparkedThreads: found == nil ? 0 : 1,
            haveMoreThreads: more,
            beFair: fair
        )
        let token = callback(result)

        bucketRelease(lp)

        if let f = found {
            let fd = f.takeUnretainedValue()
            fd.unparkToken = token
            fd.wake()
        }

        return result
    }
}

// MARK: - SpinWait

// Exponential backoff matching parking_lot_core/spinwait.rs exactly.
// Observed 2026-04-20: at oversubscription (t≥ core-count) the sched_yield
// phase (iters 4-10) dominates cross-die coherence traffic — 2.75× collapse
// on M1 Ultra, 7.25× on Broadwell 2-socket. Single-die Alder Lake immune.
// Iter 1..=3 → 2^iter CPU pauses. Iter 4..=10 → sched_yield. Iter >10 →
// `spin()` returns false, caller parks.
@usableFromInline
struct SpinWait {
    @usableFromInline var counter: UInt32 = 0

    @inlinable init() {}

    @inlinable
    mutating func reset() { counter = 0 }

    @inlinable
    mutating func spin() -> Bool {
        if counter >= 10 { return false }
        counter &+= 1
        if counter <= 3 {
            let iters = UInt32(1) &<< counter
            for _ in 0..<iters { spin_loop_hint() }
        } else {
            thread_yield()
        }
        return true
    }
}

#endif
