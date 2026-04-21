//===----------------------------------------------------------------------===//
// RustMutex — Rust std::sync::Mutex futex implementation + tuning knobs.
//
// Reference: library/std/src/sys/sync/mutex/futex.rs (rustc upstream).
//
// Defaults match Rust exactly: 100 iter × 1 PAUSE, no retries, no bound.
// Parameters (all default to upstream-Rust behavior):
//
//   spinTries        — main spin loop iterations (Rust: 100)
//   pausesPerIter    — PAUSE instructions per spin iter (Rust: 1)
//   outerRetries     — additional full spin sessions after CAS fail before
//                      parking (Rust: 0 — park immediately)
//   retrierLimit     — 0: unbounded (any number of threads can retry).
//                      >0: only up to N threads can be in retry phase at
//                      once (uses activeRetriers counter). Excess threads
//                      either park (spinIfLimited=false) or continue
//                      load-only spinning (spinIfLimited=true).
//   spinIfLimited    — when retrierLimit is reached, excess threads stay
//                      in load-only spin instead of parking. Trades sys
//                      CPU (syscalls) for user CPU (wasted spin).
//   depthThreshold   — 0: off. >0: depth-adaptive gate (from OptimalMutex).
//                      On spin entry, if word==contended AND parkers>=K,
//                      skip spin and kernel-phase retries entirely; park
//                      immediately.
//   skipSpuriousWake — false (Rust): unlock always does FUTEX_WAKE(1) when
//                      prev==contended. true: check parkers counter first,
//                      skip wake when no threads are sleeping. Handles the
//                      case where word==2 is stale (kernel-phase winner
//                      stamped 2 and grabbed lock, but no one's waiting).
//   demoteOnEmpty    — false (Rust): word stays at 2 after kernel-phase
//                      win, forcing all subsequent arrivers down the slow
//                      path until unlock resets to 0. true: last parker out
//                      CAS(2→1), restoring fast-path CAS(0→1) viability on
//                      the next unlock and skipping spurious wakes.
//
// The parkers counter is tracked when any of depthThreshold>0,
// skipSpuriousWake, or demoteOnEmpty is enabled. Base Rust variant
// (all off) is unperturbed.
//
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class RustMutex<Value>: @unchecked Sendable {
    @usableFromInline
    enum State: UInt32 {
        case unlocked
        case locked
        case contended
    }

    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let activeRetriers: UnsafeMutablePointer<UInt32>
    @usableFromInline let parkers: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public let spinTries: Int
    public let pausesPerIter: UInt32
    public let outerRetries: Int
    public let retrierLimit: UInt32
    public let spinIfLimited: Bool
    public let depthThreshold: UInt32
    public let skipSpuriousWake: Bool
    public let demoteOnEmpty: Bool
    public let stats: MutexStats?

    @usableFromInline
    var tracksParkers: Bool {
        depthThreshold > 0 || skipSpuriousWake || demoteOnEmpty
    }

    public init(
        _ initialValue: Value,
        spinTries: Int = 100,
        pausesPerIter: UInt32 = 1,
        outerRetries: Int = 0,
        retrierLimit: UInt32 = 0,
        spinIfLimited: Bool = false,
        depthThreshold: UInt32 = 0,
        skipSpuriousWake: Bool = false,
        demoteOnEmpty: Bool = false,
        instrument: Bool = false
    ) {
        self.spinTries = spinTries
        self.pausesPerIter = pausesPerIter
        self.outerRetries = outerRetries
        self.retrierLimit = retrierLimit
        self.spinIfLimited = spinIfLimited
        self.depthThreshold = depthThreshold
        self.skipSpuriousWake = skipSpuriousWake
        self.demoteOnEmpty = demoteOnEmpty
        self.stats = instrument ? MutexStats() : nil

        // Layout: [word:u32 @0 | activeRetriers:u32 @4 | parkers:u32 @8 | padding | value]
        // Header is 12 bytes; all three counters on the same cache line so the
        // depth gate reads word+parkers with one fetch.
        let headerBytes = 12
        let valueAlign = Swift.max(MemoryLayout<Value>.alignment, 1)
        let valueOffset = (headerBytes + valueAlign - 1) / valueAlign * valueAlign
        let totalSize = valueOffset + MemoryLayout<Value>.stride
        let alignment = Swift.max(
            MemoryLayout<UInt32>.alignment,
            MemoryLayout<Value>.alignment
        )
        buffer = .allocate(byteCount: totalSize, alignment: alignment)
        word = buffer.assumingMemoryBound(to: UInt32.self)
        word.initialize(to: State.unlocked.rawValue)
        activeRetriers = (buffer + 4).assumingMemoryBound(to: UInt32.self)
        activeRetriers.initialize(to: 0)
        parkers = (buffer + 8).assumingMemoryBound(to: UInt32.self)
        parkers.initialize(to: 0)
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
        if atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) {
            if let s = stats { s.incr(.lockFastHit) }
            return
        }
        lockContended()
    }

    @inlinable
    func lockContended() {
        if let s = stats { s.incr(.lockSlowEntries) }
        // Depth-adaptive gate (OptimalMutex #8). When enabled, skip spin +
        // retries if the queue is already deep — go straight to park.
        let skipSpin = depthThreshold > 0
            && atomic_load_acquire_u32(word) == State.contended.rawValue
            && atomic_load_acquire_u32(parkers) >= depthThreshold

        var state: UInt32 = State.unlocked.rawValue
        if skipSpin {
            if let s = stats { s.incr(.gateSkipsHit) }
            // Fall through to kernel phase. state=unlocked so first loop
            // iteration does `exchange(contended)` — if owner released in
            // the gap we win; otherwise park.
        } else {
            state = spin()
            if state == State.unlocked.rawValue {
                if let s = stats {
                    s.incr(.spinLoadsUnlocked)
                    s.incr(.postSpinCASFired)
                }
                if atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) {
                    if let s = stats { s.incr(.postSpinCASWon) }
                    return
                }
                if let s = stats { s.incr(.postSpinCASLost) }
                state = atomic_load_relaxed_u32(word)
            } else if state == State.contended.rawValue {
                if let s = stats { s.incr(.spinExitedOnContended) }
            } else {
                if let s = stats { s.incr(.spinBudgetExhausted) }
            }
        }

        // Outer retry loop with optional bounded retrier pool.
        var retries = skipSpin ? 0 : outerRetries
        while retries > 0 && state != State.contended.rawValue {
            if retrierLimit > 0 {
                // Bounded: try to grab a retry slot.
                let prev = atomic_fetch_add_u32(activeRetriers, 1)
                if prev >= retrierLimit {
                    // No slot available.
                    _ = atomic_fetch_sub_u32(activeRetriers, 1)
                    if !spinIfLimited {
                        break // fall through to kernel phase (park)
                    }
                    // Keep spinning load-only; don't attempt CAS.
                    state = spin()
                    retries -= 1
                    continue
                }
                // Got a slot — do a spin + CAS attempt.
                state = spin()
                if state == State.unlocked.rawValue {
                    if atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) {
                        _ = atomic_fetch_sub_u32(activeRetriers, 1)
                        return
                    }
                    state = atomic_load_relaxed_u32(word)
                }
                _ = atomic_fetch_sub_u32(activeRetriers, 1)
            } else {
                // Unbounded — original outerRetries behavior.
                state = spin()
                if state == State.unlocked.rawValue {
                    if atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) {
                        return
                    }
                    state = atomic_load_relaxed_u32(word)
                }
            }
            retries -= 1
        }

        // Kernel phase: swap to CONTENDED (acquire attempt 2) or park.
        if let s = stats { s.incr(.kernelPhaseEntries) }
        let tracks = tracksParkers
        if tracks { _ = atomic_fetch_add_u32(parkers, 1) }
        var firstTry = true
        while true {
            if state != State.contended.rawValue
                && atomic_exchange_acquire_u32(word, State.contended.rawValue) == State.unlocked.rawValue {
                if let s = stats {
                    s.incr(firstTry ? .exchangeContendedWonFirstTry : .exchangeContendedWonAfterWait)
                }
                if tracks {
                    let prev = atomic_fetch_sub_u32(parkers, 1)
                    // Demote word 2→1 if we're the last parker out. Lets
                    // next unlock skip FUTEX_WAKE and re-enables fast-path
                    // CAS(0→1) for the next uncontended arriver.
                    if demoteOnEmpty && prev == 1 {
                        if atomic_cas_acquire_u32(word, State.contended.rawValue, State.locked.rawValue) {
                            if let s = stats { s.incr(.demoteWonEmpty) }
                        } else {
                            if let s = stats { s.incr(.demoteLostRace) }
                        }
                    }
                }
                return
            }
            firstTry = false

            if let s = stats { s.incr(.futexWaitCalls) }
            let err = futex_wait(word, State.contended.rawValue)
            switch err {
            case 0: break
            case 11: if let s = stats { s.incr(.futexWaitEAGAIN) }
            case 4: if let s = stats { s.incr(.futexWaitInterrupted) }
            default: fatalError("Unknown error in futex_wait: \(err)")
            }

            state = spin()
        }
    }

    @inlinable
    func spin() -> UInt32 {
        var remaining = spinTries
        while true {
            let state = atomic_load_relaxed_u32(word)
            if state != State.locked.rawValue || remaining == 0 {
                return state
            }
            for _ in 0..<pausesPerIter { spin_loop_hint() }
            remaining -= 1
        }
    }

    @inlinable
    public func unlock() {
        guard atomic_exchange_release_u32(word, State.unlocked.rawValue) == State.contended.rawValue else {
            return
        }
        // Skip wake syscall if no parkers actually sleeping. Word==contended
        // can be stale (e.g. kernel-phase winner stamped word=2, grabbed
        // lock, then everyone drained before unlock).
        if skipSpuriousWake && atomic_load_relaxed_u32(parkers) == 0 {
            if let s = stats { s.incr(.futexWakeSuppressed) }
            return
        }
        if let s = stats { s.incr(.futexWakeCalls) }
        _ = futex_wake(word, 1)
    }
}
#endif
