//===----------------------------------------------------------------------===//
// Plain futex mutex — FUTEX_WAIT/FUTEX_WAKE instead of PI-futex.
//
// Same spin phase as stdlib, but plain futex for the kernel path.
// Key difference: unlock releases to 0 in userspace, THEN wakes a waiter.
// This creates a window where spinners can acquire — making spinning
// actually effective under contention (unlike PI-futex direct handoff).
//
// Lock word states (glibc-style 3-state):
//   0 = unlocked
//   1 = locked, no waiters
//   2 = locked, has waiters (at least one thread sleeping in kernel)
//
// This is how glibc PTHREAD_MUTEX_NORMAL works internally.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

/// Plain futex mutex with same spin phase as stdlib Synchronization.Mutex.
/// Uses FUTEX_WAIT/FUTEX_WAKE — no priority inheritance, but spinning works.
///
/// Memory layout matches SynchronizationMutex: lock word and value colocated
/// in same allocation (same cache line) for fair comparison.
public final class PlainFutexMutex<Value>: @unchecked Sendable {
    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public let spinTries: Int

    /// Stop spinning if waiters are already parked (WebKit hasParkedBit pattern).
    /// State 2 = locked with waiters — heavy contention, spinning is wasteful.
    public let earlyExitOnWaiters: Bool

    /// Use sched_yield() instead of pause/wfe per spin iteration (WebKit style).
    public let useYield: Bool

    /// Exponential backoff: double pause count each iteration (1,2,4,8...).
    /// Reduces cache-line traffic geometrically. Rust parking_lot style.
    public let useBackoff: Bool

    /// Maximum pause hints per iteration when useBackoff=true.
    /// Lower = tighter CAS checks at tail, more cache traffic.
    /// Higher = less cache traffic, may miss releases.
    /// Default 8: matches Rust parking_lot cap. 95 total pauses at spin=14.
    public let backoffCap: UInt32

    /// Place lock word and value on separate cache lines (64-byte padding).
    /// Eliminates false sharing between spinners and the lock owner's writes.
    public let separateCacheLine: Bool

    /// Regime-gated backoff cap. When true, the cap used by exp backoff
    /// switches based on observed state each spin iteration:
    ///   state==1 (locked, no waiters parked) → `capHigh` (undersubscribed
    ///       regime — owner likely on CPU, longer backoff gives owner time
    ///       to release)
    ///   state==2 (locked, waiters parked)    → `capLow`  (contended regime —
    ///       tighter checks intended to catch brief release windows)
    /// Requires `useBackoff: true` to take effect; ignored otherwise.
    public let regimeGatedCap: Bool
    public let capHigh: UInt32
    public let capLow: UInt32

    /// Starting value for exponential backoff. Default 1 (classic 1,2,4,8...).
    /// Setting floor > 1 skips the early tight iterations. Diagnostic for the
    /// 64c chiplet gap: cap=6 still misses cross-CCD release windows if the
    /// first few iters are at backoff=1-2 (reading shared line too often,
    /// causing cross-CCD traffic that obscures the release signal). Floor=4
    /// starts at cap-ish backoff, reduces early cache-line contention.
    public let backoffFloor: UInt32

    /// Sticky-parked-regime detection. When > 0 (and regimeGatedCap enabled):
    /// count consecutive state==2 observations. When the count reaches
    /// threshold, bail the spin loop and go straight to futex_wait. Also,
    /// on first state==2 observation with backoff<capLow, jump backoff up
    /// to capLow to skip ramping from lower values.
    ///
    /// Rationale: current regime-gated tightens cap on state==2 but still
    /// spends the full spinTries budget polling the shared word. Once state
    /// is persistently ==2 (waiters already parked, owner running but no
    /// imminent release), each shared-line read costs cross-core coherence
    /// traffic — exactly the cost regime-gated was supposed to avoid.
    /// Sticky threshold exits the spin when the brief-release-window
    /// hypothesis is no longer supported by recent observations.
    ///
    /// Default 0 = disabled (current behavior). Typical values: 2-5.
    public let stickyParkThreshold: UInt32

    // Lock word states
    @usableFromInline static var UNLOCKED: UInt32 { 0 }
    @usableFromInline static var LOCKED: UInt32 { 1 }
    @usableFromInline static var LOCKED_WAITERS: UInt32 { 2 }

    public init(
        _ initialValue: Value,
        spinTries: Int = Int(default_spin_tries()),
        earlyExitOnWaiters: Bool = false,
        useYield: Bool = false,
        useBackoff: Bool = false,
        backoffCap: UInt32 = 8,
        separateCacheLine: Bool = false,
        regimeGatedCap: Bool = false,
        capHigh: UInt32 = 32,
        capLow: UInt32 = 6,
        backoffFloor: UInt32 = 1,
        stickyParkThreshold: UInt32 = 0
    ) {
        let valueOffset: Int
        if separateCacheLine {
            // 64-byte cache line boundary between lock word and value
            valueOffset = Swift.max(64, MemoryLayout<Value>.alignment)
        } else {
            valueOffset = Swift.max(
                MemoryLayout<UInt32>.stride,
                MemoryLayout<Value>.alignment
            )
        }
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(
            separateCacheLine ? 64 : MemoryLayout<UInt32>.alignment,
            MemoryLayout<Value>.alignment
        )

        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: 0)
        valuePtr = (buffer + valueOffset).assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
        self.spinTries = spinTries
        self.earlyExitOnWaiters = earlyExitOnWaiters
        self.useYield = useYield
        self.useBackoff = useBackoff
        self.backoffCap = backoffCap
        self.separateCacheLine = separateCacheLine
        self.regimeGatedCap = regimeGatedCap
        self.capHigh = capHigh
        self.capLow = capLow
        self.backoffFloor = backoffFloor
        self.stickyParkThreshold = stickyParkThreshold
    }

    deinit {
        valuePtr.deinitialize(count: 1)
        buffer.deallocate()
    }

    // MARK: - withLock

    @inlinable
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body(&valuePtr.pointee)
    }

    // MARK: - Lock

    @inlinable
    public func lock() {
        // Fast path: uncontended — CAS 0→1
        if atomic_cas_acquire_u32(word, 0, 1) {
            return
        }

        lockSlow()
    }

    @inlinable
    func lockSlow() {
        // --- Spin phase ---
        // Unlike PI-futex, this spin IS effective: unlock stores 0 in
        // userspace before waking, so spinners can steal the lock in
        // the window between store(0) and the woken waiter's CAS.
        if spinTries > 0 {
            var tries = spinTries
            var backoff: UInt32 = backoffFloor  // doubles each iteration when useBackoff=true; starts at floor to skip tight early iters
            var consecutiveState2: UInt32 = 0   // for sticky-parked-regime detection

            repeat {
                let state = atomic_load_relaxed_u32(word)

                // WebKit early exit: if waiters are parked (state==2),
                // contention is heavy — stop spinning, go park.
                if earlyExitOnWaiters, state == 2 {
                    break
                }

                if state == 0, atomic_cas_acquire_u32(word, 0, 1) {
                    return
                }

                // Sticky-parked-regime detection.
                // If the caller enabled regime-gated cap AND a sticky
                // threshold, track consecutive state==2 observations.
                // Persistent state==2 means parked waiters exist and the
                // owner isn't releasing soon — every shared-line read costs
                // cross-core coherence traffic. Bail and let futex_wait
                // handle it. Also raise backoff to capLow on regime entry
                // so we don't ramp up from lower values in a regime that's
                // about to terminate anyway.
                if regimeGatedCap, stickyParkThreshold > 0 {
                    if state == 2 {
                        consecutiveState2 &+= 1
                        if consecutiveState2 >= stickyParkThreshold {
                            break
                        }
                        if backoff < capLow { backoff = capLow }
                    } else {
                        consecutiveState2 = 0
                    }
                }

                tries &-= 1

                if useYield {
                    thread_yield()
                } else if useBackoff {
                    // Exponential backoff: 1,2,4,8... pause hints per iteration.
                    // Reduces cache-line traffic geometrically.
                    // Regime-gated: flip cap based on observed contention state.
                    let cap: UInt32 = regimeGatedCap
                        ? (state == 2 ? capLow : capHigh)
                        : backoffCap
                    for _ in 0..<backoff { spin_loop_hint() }
                    if backoff < cap { backoff &<<= 1 }
                    else if backoff > cap { backoff = cap }  // shrink on regime→tight
                } else {
                    spin_loop_hint()
                }
            } while tries > 0
        }

        // --- Kernel phase ---
        // Set state to 2 (locked + waiters) and sleep until value changes.
        // On wakeup, try to acquire. If we fail, go back to sleep.
        while true {
            // If state was 1 (locked, no waiters), swap to 2 (locked, waiters).
            // If state was 0 (unlocked), swap to 2 — we just acquired.
            let prev = atomic_exchange_acquire_u32(word, 2)
            if prev == 0 {
                // Was unlocked — we acquired with state=2 (indicating waiters,
                // which is conservative but correct; next unlock will wake).
                return
            }

            // Lock is held (prev was 1 or 2). Sleep until value changes from 2.
            // FUTEX_WAIT is a conditional sleep: only sleeps if *word == 2.
            // If another thread unlocked between our exchange and this call,
            // *word won't be 2 and FUTEX_WAIT returns EAGAIN immediately.
            let err = futex_wait(word, 2)
            switch err {
            case 0:     // Woken by FUTEX_WAKE
                break
            case 11:    // EAGAIN — value changed, retry
                break
            case 4:     // EINTR — signal, retry
                break
            default:
                fatalError("Unknown error in futex_wait: \(err)")
            }
            // Loop back to try acquiring again.
        }
    }

    // MARK: - Unlock

    @inlinable
    public func unlock() {
        // Atomically set to 0. Returns previous value.
        let prev = atomic_exchange_release_u32(word, 0)

        if prev == 2 {
            // Had waiters — wake one.
            unlockSlow()
        }
        // prev == 1: no waiters, done.
    }

    @usableFromInline
    func unlockSlow() {
        // Wake one waiter. The woken thread will CAS/exchange to acquire.
        let err = futex_wake(word, 1)
        if err != 0 {
            // FUTEX_WAKE errors are non-fatal (EFAULT/EINVAL shouldn't happen
            // with a valid address). Ignore.
        }
    }
}
#endif
