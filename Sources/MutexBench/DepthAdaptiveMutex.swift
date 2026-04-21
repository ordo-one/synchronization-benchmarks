//===----------------------------------------------------------------------===//
// DepthAdaptiveMutex — single-word futex + adjacent waiter counter
//
// Adds waiterCount (UInt32) on same cache line as lockWord. New arrivals
// use it as an advisory depth hint: if state==contended AND parkers >= K,
// skip spin phase and go directly to park.
//
// Counter tracks only threads inside the futex_wait kernel-phase loop.
// Increment before first exchange(2). Decrement on successful acquire.
// Between, count stays = 1 per parked thread.
//
// Layout (single 64-byte cache line):
//   offset 0: lockWord    UInt32  (0/1/2)
//   offset 4: waiterCount UInt32  (parkers-in-loop count)
//   offset 8+: value
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class DepthAdaptiveMutex<Value>: @unchecked Sendable {
    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let waiterCount: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public let spinTries: Int
    public let pauseBase: UInt32
    public let depthThreshold: UInt32
    public let useJitter: Bool
    public let kernelSpinTries: Int
    public let postWakeSpinTries: Int
    public let useStarvation: Bool
    public let starvationThresholdNs: UInt64
    public let stats: MutexStats?

    // STARVING bit (0x4): Go-style fairness mode. Latched by a waiter that
    // just woke after waiting >starvationThresholdNs. When set:
    //   - lock state semantics change: "locked=0 AND starving=1" means the
    //     lock has been handed off to a specific waiter (not truly free)
    //   - spin-phase arrivals must park (no barging)
    //   - unlock does direct handoff: sets STARVING, wakes, waiter claims
    //     via exchange→locked
    // Cleared by the acquiring waiter if its wait was brief OR if it was
    // the last parker in the queue (queue caught up).
    // Encoded as bit 0x4 orthogonal to 0/1/2 held-state encoding.
    @usableFromInline static var STARVING: UInt32 { 4 }

    public init(
        _ initialValue: Value,
        spinTries: Int = 40,
        pauseBase: UInt32 = 128,
        depthThreshold: UInt32 = 2,
        useJitter: Bool = true,
        kernelSpinTries: Int = 0,
        postWakeSpinTries: Int = 0,
        useStarvation: Bool = false,
        starvationThresholdNs: UInt64 = 1_000_000,  // 1ms, matches Go. Empirical: 1ms collapses W/P most on arnold at zero throughput cost.
        instrument: Bool = false
    ) {
        self.kernelSpinTries = kernelSpinTries
        self.postWakeSpinTries = postWakeSpinTries
        self.useStarvation = useStarvation
        self.starvationThresholdNs = starvationThresholdNs
        self.stats = instrument ? MutexStats() : nil
        // Layout: [word: UInt32 | counter: UInt32 | padding | value]
        let valueOffset = Swift.max(8, MemoryLayout<Value>.alignment)
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(
            MemoryLayout<UInt32>.alignment,
            MemoryLayout<Value>.alignment
        )
        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: 0)
        waiterCount = (buffer + 4).assumingMemoryBound(to: UInt32.self)
        waiterCount.initialize(to: 0)
        valuePtr = (buffer + valueOffset).assumingMemoryBound(to: Value.self)
        valuePtr.initialize(to: initialValue)
        self.spinTries = spinTries
        self.pauseBase = pauseBase
        self.depthThreshold = depthThreshold
        self.useJitter = useJitter
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
        if atomic_cas_acquire_u32(word, 0, 1) {
            if let s = stats { s.incr(.lockFastHit) }
            return
        }
        lockSlow()
    }

    @inlinable
    func lockSlow() {
        if let s = stats { s.incr(.lockSlowEntries) }
        // Go-style starvation mode: if enabled, record entry time so we can
        // latch STARVING bit after threshold elapses. Reading the clock here
        // is cheap (vdso-backed clock_gettime) and only done on slow path.
        let enterTime: UInt64 = useStarvation ? mutex_clock_ns() : 0

        // Advisory depth check: skip spin if queue deep OR lock in
        // starvation mode (new arrivals must queue, cannot barge).
        let initialState = atomic_load_acquire_u32(word)
        let parkers = atomic_load_acquire_u32(waiterCount)
        let skipSpin = ((initialState & 0x3) == 2 && parkers >= depthThreshold)
            || ((initialState & Self.STARVING) != 0)
        if skipSpin, let s = stats { s.incr(.gateSkipsHit) }

        if !skipSpin {
            let jitter = useJitter ? fast_jitter() : 0
            let mask: UInt32 = useJitter ? (pauseBase &- 1) : 0
            var spinsRemaining = spinTries

            while spinsRemaining > 0 {
                let state = atomic_load_relaxed_u32(word)
                // Fast path only when STARVING clear (normal mode).
                if (state & Self.STARVING) == 0 && (state & 0x3) == 0 {
                    if let s = stats {
                        s.incr(.spinLoadsUnlocked)
                        s.incr(.spinCASFired)
                    }
                    if atomic_cas_acquire_u32(word, 0, 1) {
                        if let s = stats { s.incr(.spinCASWon) }
                        return
                    }
                    if let s = stats { s.incr(.spinCASLost) }
                }
                // STARVING observed → must park. Contended state → park.
                if (state & Self.STARVING) != 0 || (state & 0x3) == 2 {
                    if let s = stats { s.incr(.spinExitedOnContended) }
                    break
                }
                let pauses = pauseBase &+ (jitter & mask)
                for _ in 0..<pauses { spin_loop_hint() }
                spinsRemaining &-= 1
            }
            if spinsRemaining == 0, let s = stats { s.incr(.spinBudgetExhausted) }
        }

        // Kernel phase — exchange-based claim (episodic starvation mode).
        // Single atomic per iteration (matches original Optimal speed).
        // STARVING is CLOBBERED on each successful claim — i.e. starvation
        // mode is EPISODIC: one long-waiter gets one handoff, then STARVING
        // clears. Subsequent waiters re-latch if their own wait crosses
        // threshold. Avoids "sticky STARVING" that regressed p99 on sustained
        // mode (each acquire during the starving window pays gate+kernel cost).
        if let s = stats { s.incr(.kernelPhaseEntries) }
        _ = atomic_fetch_add_u32(waiterCount, 1)
        var firstTry = true
        while true {
            // exchange(word, 2) claims if prev word had locked bit clear:
            //   prev == 0 → normal unlock just happened, we win
            //   prev == 4 (STARVING only) → handoff in progress, we claim it
            // In both cases word is now 2 (contended). STARVING clobbered.
            let prevX = atomic_exchange_acquire_u32(word, 2)
            if (prevX & 0x3) == 0 {
                if let s = stats {
                    s.incr(firstTry ? .exchangeContendedWonFirstTry : .exchangeContendedWonAfterWait)
                }
                _ = atomic_fetch_sub_u32(waiterCount, 1)
                return
            }
            firstTry = false

            // Park. futex_wait expected=2 matches our exchange above.
            if let s = stats { s.incr(.futexWaitCalls) }
            let err = futex_wait(word, 2)
            switch err {
            case 0: break
            case 11: if let s = stats { s.incr(.futexWaitEAGAIN) }
            case 4: if let s = stats { s.incr(.futexWaitInterrupted) }
            default: fatalError("futex_wait: \(err)")
            }

            // Post-wake: check our elapsed wait. If crossed threshold and
            // STARVING not yet set, latch it. New arrivals will see STARVING
            // and park (don't barge during this handoff window).
            if useStarvation {
                let w = atomic_load_relaxed_u32(word)
                if (w & Self.STARVING) == 0 {
                    let elapsed = mutex_clock_ns() &- enterTime
                    if elapsed > starvationThresholdNs {
                        _ = atomic_fetch_or_u32(word, Self.STARVING)
                    }
                }
            }
        }
    }

    @inlinable
    public func unlock() {
        if useStarvation {
            // Single-atomic unlock: clear locked bits (0x3), preserve
            // STARVING (0x4). Works for all 4 valid pre-states:
            //   1 (locked, no waiter)      → 0, no wake
            //   2 (locked + waiter)        → 0, wake
            //   5 (locked + STARVING)      → 4, no wake (no waiter to wake)
            //   6 (locked + waiter + STRV) → 4, wake
            // One LOCK AND on x86. No CAS loop, no load — eliminates the
            // NUMA regression from the earlier CAS-loop-in-unlock version.
            let prev = atomic_fetch_and_u32(word, ~UInt32(0x3))
            if (prev & 0x2) != 0 {
                if let s = stats { s.incr(.futexWakeCalls) }
                _ = futex_wake(word, 1)
            }
            return
        }
        guard atomic_exchange_release_u32(word, 0) == 2 else { return }
        if let s = stats { s.incr(.futexWakeCalls) }
        _ = futex_wake(word, 1)
    }
}
#endif
