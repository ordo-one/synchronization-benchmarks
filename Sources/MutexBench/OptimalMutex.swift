//===----------------------------------------------------------------------===//
// OptimalMutex — plain-futex mutex tuned for cooperative-concurrency
// workloads (Swift Task cooperative pool, short critical sections,
// no RT priorities).
//
// Hardcoded winning configuration from 3-machine empirical validation
// (x86 12c Intel i5-12500, x86 40c Intel Xeon Gold 6148, x86 64c AMD EPYC
// 9454P chiplet). No flags, no knobs — this is the algorithm that dominated
// the mutex-bench contention profile. See Experiments.md §12 and
// SpinSurvey.md for cross-ecosystem context and benchmark evidence.
//
// -----------------------------------------------------------------------------
// SCOPE OF APPLICABILITY — READ BEFORE SUBSTITUTING FOR STDLIB Mutex
// -----------------------------------------------------------------------------
//
// This is NOT a drop-in replacement for Swift's `Synchronization.Mutex` in
// the general case. It is optimized for the Swift-cooperative-concurrency
// contention profile measured in this repo. Specifically:
//
//   - No priority inheritance. The plain-futex kernel path (FUTEX_WAIT/
//     FUTEX_WAKE) does not provide PI semantics. Mixed-priority callers
//     or native threads at distinct RT priorities could suffer inversion
//     regressions that the stdlib's PI-futex prevents. Swift's cooperative
//     Task pool does not use RT priorities, so inversion is a non-issue
//     for that workload class, but any caller relying on PI (e.g., audio
//     threads on a glibc userspace-RT setup) would regress.
//
//   - Barging, not queued fairness. Under extreme long-hold + many-waiter
//     contention, tail latency and acquisition fairness may degrade
//     relative to PI-futex kernel-side handoff. Measured effect on
//     LongRun/Asymmetric benchmarks was acceptable for the cooperative-
//     pool profile; other profiles may differ.
//
//   - No Darwin/Windows path. Linux only. Darwin uses os_unfair_lock
//     which has its own design tradeoffs; the regression motivating this
//     work is Linux-specific.
//
// A stdlib-wide replacement would need to preserve PI semantics for RT
// workloads (possibly via a runtime-detected fall-back to PI-futex when
// RT priorities are detected) or accept the tradeoff explicitly in the
// API surface. This file does neither — it ships the fast path only.
//
// -----------------------------------------------------------------------------
// ALGORITHM AT A GLANCE
// -----------------------------------------------------------------------------
//
//   Plain futex (FUTEX_WAIT/FUTEX_WAKE), glibc-style 3-state lock word:
//     0 = unlocked
//     1 = locked, no waiters parked
//     2 = locked, waiters parked (at least one thread sleeping in kernel)
//
//   lock():
//     Fast path:   CAS(0 → 1). Uncontended acquires require one atomic op.
//     Slow path:   14 spin iterations with regime-gated exponential backoff.
//                  If still locked after spin, exchange(2) and futex_wait.
//
//   unlock():
//     exchange(0); if prev was 2, FUTEX_WAKE(1).
//     Uncontended unlocks require zero syscalls.
//
// -----------------------------------------------------------------------------
// WHY EACH DESIGN CHOICE
// -----------------------------------------------------------------------------
//
// 1. PLAIN FUTEX, NOT PI-FUTEX
//
//    Swift's current `Synchronization.Mutex` on Linux uses FUTEX_LOCK_PI
//    for priority inheritance. PI-futex is architecturally incompatible
//    with userspace spinning because it does atomic direct handoff: under
//    contention the lock word transitions TID_old|WAITERS → TID_new|WAITERS
//    and NEVER reaches 0. A spin loop checking `state == 0` can never
//    succeed once any thread parks.
//
//    Plain futex unlocks by storing 0 in userspace BEFORE the wake syscall,
//    which creates a real window for spinners to acquire. Spinning becomes
//    effective.
//
//    The cost of this choice: loss of priority inheritance. For Swift's
//    cooperative Task pool (all Tasks at the same implicit priority from
//    the runtime's perspective), PI has no effect either way, so this is
//    a clean win. For callers outside that model — mixed-priority native
//    threads, glibc userspace RT threads, audio callbacks — this can
//    regress on inversion-sensitive workloads. See the "Scope of
//    Applicability" section at file top.
//
//    See SPIN-SURVEY.md for the kernel invariant citations and
//    EXPERIMENTS.md §3-4 for the 10-43× cost measurements (PI-futex syscall
//    is ~10× more expensive than plain on 12c, ~43× on 64c).
//
// 2. 3-STATE LOCK WORD (0/1/2), NOT 2-STATE
//
//    The 3-state encoding (glibc-style, used by Rust std and every major
//    plain-futex mutex) lets the unlock fast path skip FUTEX_WAKE when
//    prev==1 (no waiters). That cuts one syscall off every uncontended
//    unlock — the common case. 2-state would wake unconditionally.
//
//    The tradeoff: we must always use exchange(2) in the kernel phase,
//    which marks the lock contended even if we'd have acquired with
//    exchange(1). This causes one spurious FUTEX_WAKE on the next unlock
//    after a post-spin acquire, but that's rare and cheap.
//
// 3. FAST PATH IS CAS(0→1), NOT CAS(0→2) OR SWAP
//
//    Uncontended acquires mark the lock "no waiters" so the uncontended
//    unlock can skip FUTEX_WAKE entirely. Contended acquires fall through
//    to the slow path which uses exchange(2) when necessary.
//
// 4. SPIN BUDGET = 14 ITERATIONS
//
//    Cross-machine data (EXPERIMENTS.md §6) shows a broad plateau of
//    near-optimal behavior between 10 and 60 spins (WebKit found this in
//    2016). We pick 14 because:
//      - Low enough to avoid wasting cycles under oversubscription (12c
//        tasks≥16, 40c tasks≥64). Longer budgets burn CPU the lock owner
//        needs to run.
//      - High enough to catch release windows under low-to-moderate
//        contention on all three tested machines.
//      - The asymmetry is intentional: it's cheaper to under-spin and park
//        than to over-spin and starve the owner.
//
//    Compare: Swift stdlib today = 1000 (x86) / 100 (arm64) fixed. Other
//    ecosystems: WebKit = 40, glibc ADAPTIVE_NP = 100, Go = 120, Rust std
//    futex = 100. We're at the low end of the empirical plateau.
//
// 5. EXPONENTIAL BACKOFF (DOUBLING) BETWEEN ITERATIONS
//
//    Without backoff, each spin iteration issues one load of the shared
//    lock word. With N spinners, that's O(N²) coherence traffic per
//    critical section — each load pulls the line into the spinner's
//    cache, invalidating every other copy.
//
//    Doubling backoff (1, 2, 4, 8, 16, ...) cuts shared-line observations
//    by a logarithmic factor in total spin time. Rust parking_lot and
//    glibc ADAPTIVE_NP both do this. EXPERIMENTS.md §8 showed that fixed
//    spin (no backoff) regresses below NIO on 12-core (1.3× slower at
//    tasks=16 — oversubscription effect).
//
// 6. REGIME-GATED CAP: capHigh=32 WHEN state==1, capLow=6 WHEN state==2
//
//    THIS IS THE CORE CONTRIBUTION relative to every other surveyed
//    implementation. The cap is recomputed each iteration from the
//    observed lock state. A single acquire cycle passes through two
//    distinct phases with opposite optimal backoff:
//
//      Phase A (state == 1): owner holds the lock; no thread has given up
//        and parked. All waiters are spinning. Optimal: LONG backoff.
//          - Owner is probably running on its own core; long backoff gives
//            it CPU time to finish its critical section.
//          - Tight CAS-readiness checks pull the lock line into Exclusive
//            state on spinners' cores, which fights the owner's cache
//            access to lock+value (colocated in the same allocation).
//          - Preserves all-spinning stability — no thread is incentivized
//            to park early due to spurious cache invalidations.
//        capHigh = 32 is the value from EXPERIMENTS.md §8. On 12c Intel it
//        wins by 2× over cap=8 at tasks=16 (2,300 vs 4,973 µs).
//
//      Phase B (state == 2): at least one thread has parked. The system
//        has already paid the park syscall cost. Optimal: SHORT backoff.
//          - We're racing the kernel wake path. When owner releases, there
//            is a narrow window before FUTEX_WAKE hands off to the parked
//            waiter; tight polling catches that window.
//          - Cache-traffic cost is now asymptotically free — the system
//            is already committed to "contended" state, incremental
//            invalidations can't push it into a worse one.
//          - On chipleted systems (EPYC) cross-CCD release windows are
//            especially brief; tight checks match hardware release-
//            visibility cadence.
//        capLow = 6 is the value from 3-machine tuning. Tight enough to
//        catch cross-CCD release windows, slack enough to avoid over-
//        polling on single-die systems.
//
//    Why this is strictly better than any fixed cap:
//    Any fixed cap picks which phase to hurt. cap=32 wastes cycles in
//    Phase B; cap=8 starves the owner in Phase A. Prior implementations
//    (glibc ADAPTIVE_NP, Go, parking_lot) all use one cap for the entire
//    acquire cycle — they can't express the phase distinction. 3-machine
//    data confirms regime-gated beats any nproc-calibrated formula (256/
//    nproc failed on 40c by 37%), precisely because the formula averages
//    across phases with a hardware-size prior rather than reading the
//    phase directly.
//
//    Why a single bit is enough: Phase detection needs only "are there
//    parkers or not" which is exactly FUTEX_WAITERS. Free from the
//    existing lock word encoding — zero runtime overhead beyond the
//    comparison we already do to try-acquire.
//
// 7. BACKOFF FLOOR = 4, NOT 1
//
//    Classic exponential backoff starts at 1 and ramps 1→2→4→... For the
//    first 2-3 iterations, backoff is short enough that shared-line loads
//    happen nearly back-to-back, generating the maximum cache traffic for
//    the minimum information gain (lock state hasn't had time to change).
//
//    Starting at 4 skips those wasteful early iterations and begins
//    polling at a cadence roughly matching capLow. Documented as a 14-24%
//    win on 40c at tasks=8-16 where sustained state==2 with tight early
//    polling is most costly (project_findings_40c.md).
//
//    Invariant: backoffFloor (4) <= capLow (6) <= capHigh (32). The floor
//    never exceeds capLow, so it's always valid starting backoff in any
//    regime.
//
// 8. SHRINK BACKOFF ON REGIME TRANSITION (state 1→2)
//
//    Naive growth-only backoff: if backoff has ramped up to 16 during
//    Phase A and a thread parks (cap drops from 32 to 6), backoff stays
//    at 16 until natural clamping catches up. That's 10 pauses wasted
//    per iteration in the exact regime that wants tight checks.
//
//    `else if backoff > cap { backoff = cap }` clamps immediately on
//    regime entry so the tight-poll budget activates the iteration
//    after the transition, not several iterations later.
//
// 9. NO CACHE-LINE SEPARATION
//
//    EXPERIMENTS.md §10 found that placing lock word and value on
//    separate 64-byte cache lines helps 17-22% on 12c single-die Intel
//    but is neutral-to-negative on 64c AMD EPYC (Infinity Fabric
//    penalty — cross-CCD coherency cost exceeds the false-sharing saved).
//    Topology-dependent — not suitable for a single default.
//
//    Intel single-die users who can measure can use the parameterized
//    `PlainFutexMutex(..., separateCacheLine: true, ...)` to opt in.
//    Shipping default uses colocated layout, which is how Swift stdlib
//    Mutex<Value> and Rust std futex Mutex are structured.
//
// 10. NO STICKY-PARKED-REGIME THRESHOLD
//
//    An extension tested in experiments: count consecutive state==2
//    observations; bail to futex_wait when a threshold is reached
//    (rationale: persistent state==2 means spin is wasting cycles on a
//    regime that won't transition back). Win on 40c tasks=64 (~15%),
//    marginal on 64c, slight-negative on 12c. Complexity (local counter,
//    threshold tuning) outweighs the gain at typical contention.
//
//    Stays in `PlainFutexMutex` as an optional flag for research; the
//    ship variant (this file) omits it. See project_two_phase_spin_theory
//    for the B→B.2 theoretical framing if it's ever reconsidered.
//
// 11. BARGING, NOT QUEUED FAIRNESS
//
//    New arrivals compete with parked waiters for the lock on release
//    (via the spin phase + post-wake retry loop). This is the WebKit /
//    Go-normal-mode / Rust-std default. Tradeoff: higher throughput,
//    but theoretical starvation risk at extreme contention with long
//    critical sections.
//
//    Mitigations not adopted:
//      - Go's starvation mode (>1ms wait disables spin): adds per-lock
//        state, measurable overhead. Our LongRun/Asymmetric benchmarks
//        did not reveal starvation severe enough to motivate this.
//      - WebKit's fair-unlock flip (~1% of unlocks): also adds state.
//    If fairness is later shown to matter, sticky threshold (see #10)
//    is the cheapest fairness assist — it reduces the spin advantage
//    barging arrivals enjoy over parked waiters.
//
// 12. KERNEL PHASE USES exchange(2), NOT CAS(1→2)
//
//    After spin exhausts, exchange(2) unconditionally marks the lock
//    contended. If the previous value was 0 (owner released during our
//    last spin iteration), we've just acquired the lock — return. Else
//    the lock is still held, and `word` now correctly indicates waiters
//    so the next unlock will wake us. One atomic op covers "try
//    acquire + mark contended" with no CAS-loop.
//
//    Rust std uses the same pattern (`futex.swap(CONTENDED, Acquire)`).
//
// 13. FUTEX_WAIT RETRY ON EAGAIN/EINTR
//
//    EAGAIN means the futex word changed between our exchange(2) and
//    the FUTEX_WAIT syscall (another thread unlocked in the tiny window).
//    EINTR is a signal interruption. Both are expected, non-fatal;
//    retry the outer exchange-or-park loop.
//
// -----------------------------------------------------------------------------
// INVARIANTS
// -----------------------------------------------------------------------------
//
//   - `word` is valid for the lifetime of the OptimalMutex instance.
//   - `word` and `valuePtr` live in the same heap allocation. `word` is
//     at offset 0; `valuePtr` is at `max(sizeof(UInt32), alignof(Value))`.
//     Cache-line colocation of the two fields depends on allocator
//     alignment: Linux glibc malloc returns 16-byte-aligned pointers, so
//     for Value sizes up to ~52-56 bytes both fields typically fall in
//     the same 64-byte line, but this is NOT guaranteed by the
//     allocation code — only by the allocator's ambient behavior. If
//     strict cache-line colocation is required, either over-align the
//     allocation (current code doesn't) or use PlainFutexMutex with
//     separateCacheLine=false and a value type small enough to be safe.
//   - Lock word states are mutually exclusive: at any instant,
//     *word ∈ {0, 1, 2}.
//   - Every lock() call is paired with exactly one unlock() call, in
//     LIFO order per thread. Enforced by `withLock { }` scoping.
//
// -----------------------------------------------------------------------------
// CROSS-MACHINE BENCHMARK SUMMARY (see Experiments.md §12 for full tables)
// -----------------------------------------------------------------------------
//
//   Optimal vs NIOLockedValueBox (pthread_mutex wrapper), p50 µs:
//     x86 12c (i5-12500)        t=16: 2,779  vs 9,208  → 3.3× faster
//     x86 40c (Xeon Gold 6148)  t=16: 12,509 vs 30,409 → 2.4× faster
//     x86 64c (EPYC 9454P)      t=16: 10,502 vs 22,004 → 2.1× faster
//
//   Optimal vs Swift stdlib Synchronization.Mutex (PI-futex + 1000 spin):
//     x86 12c (i5-12500)        t=16: 1.5-2× slower stdlib
//     x86 40c (Xeon Gold 6148)  t=16: 8-15× slower stdlib
//     x86 64c (EPYC 9454P)      t=16: 60-80× slower stdlib (~815 ms vs ~10 ms)
//
//   Never regresses below NIOLock on any machine at any task count.
//===----------------------------------------------------------------------===//

#if os(Linux)
import CFutexShims

public final class OptimalMutex<Value>: @unchecked Sendable {
    // 3-state lock word. Raw values must stay 0/1/2 - the C atomic helpers operate directly on the underlying UInt32.
    @usableFromInline
    enum State: UInt32 {
        case unlocked
        case locked      // held, no waiters parked in the kernel
        case contended   // held, at least one waiter parked in the kernel
    }

    @usableFromInline let buffer: UnsafeMutableRawPointer
    @usableFromInline let word: UnsafeMutablePointer<UInt32>
    @usableFromInline let valuePtr: UnsafeMutablePointer<Value>

    public init(_ initialValue: Value) {
        // Single-allocation layout: [word: UInt32 | padding | value: Value].
        // Matches stdlib Mutex<Value> colocation style. Design choice #9 —
        // no separateCacheLine by default (topology-dependent).
        //
        // Allocation alignment here is `max(alignof(UInt32), alignof(Value))`,
        // which is typically 4-16 bytes. This does NOT guarantee the buffer
        // starts on a 64-byte boundary — relying on allocator ambient
        // behavior (glibc malloc: 16-byte aligned) for cache-line behavior.
        // See "Invariants" in the file header for the honest guarantee.
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
        word.initialize(to: State.unlocked.rawValue)
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
        // Fast path: uncontended acquire - single CAS(unlocked -> locked).
        // Returns immediately in the common case, no branching.
        // Design choice #3 - mark "no waiters" so uncontended unlock can
        // skip FUTEX_WAKE entirely.
        if atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) { return }
        lockSlow()
    }

    @inlinable
    func lockSlow() {
        // ---------------------------------------------------------------
        // SPIN PHASE — 14 iterations with regime-gated exponential backoff.
        // Design choices #4, #5, #6, #7, #8 above.
        // ---------------------------------------------------------------
        //
        // Per-iteration:
        //   1. Load state (relaxed — we re-verify with CAS if we try to acquire).
        //   2. If state==0: try CAS(0→1). Success returns. CAS only fires when
        //      it can succeed — no wasted exclusive-state traffic during spin.
        //   3. Decrement remaining budget.
        //   4. Compute regime-gated cap from the state we just observed:
        //        capHigh=32 when state==1 (Phase A — owner running)
        //        capLow=6  when state==2 (Phase B — waiters parked)
        //      state==0 observed but CAS failed (race): treat as Phase A
        //      because a release just happened; long backoff lets the winner
        //      finish and release again.
        //   5. Pause for `backoff` iterations.
        //   6. Grow backoff toward cap (double) OR shrink to cap if regime
        //      just transitioned 1→2 (design choice #8).

        // Total spin-loop iterations we are willing to run before giving up and asking the kernel to park us.
        var spinsRemaining: Int = 14           // #4 - spin budget

        // Number of `spin_loop_hint()` CPU pauses we will issue on the current iteration before re-checking the lock word.
        // Grows exponentially (4 -> 8 -> 16 -> 32) up to the per-iteration `maxPauseCount`. The initial value of 4 is a
        // floor (#7) chosen over 1 to skip the first few iterations where the lock state has not yet had time to change.
        var pauseCount: UInt32 = 4             // #7 - floor, skip tight early iters

        repeat {
            let state = atomic_load_relaxed_u32(word)

            // In-spin acquire attempt. Only try CAS when load shows
            // unlocked - prevents exclusive-state cache traffic from
            // spinners that can't possibly succeed.
            if state == State.unlocked.rawValue,
               atomic_cas_acquire_u32(word, State.unlocked.rawValue, State.locked.rawValue) {
                return
            }

            spinsRemaining &-= 1

            // Regime-gated cap (#6). state == contended -> tight poll; else long backoff gives the owner CPU time to finish.
            let maxPauseCount: UInt32 = (state == State.contended.rawValue) ? 6 : 32

            // Pause for the current budget. `spin_loop_hint` emits `pause` (x86_64) or `yield`/`wfe` (arm64).
            for _ in 0 ..< pauseCount { spin_loop_hint() }

            if pauseCount < maxPauseCount {
                // Exponential doubling to back off.
                pauseCount &<<= 1
            } else if pauseCount > maxPauseCount {
                // #8 - cap just dropped (state flipped unlocked/locked -> contended); force `pauseCount` back down so the
                // short-pause budget takes effect on the very next iteration.
                pauseCount = maxPauseCount
            }
        } while spinsRemaining > 0

        // ---------------------------------------------------------------
        // KERNEL PHASE — exchange(2), futex_wait, retry. Design choice #12.
        // ---------------------------------------------------------------
        //
        // exchange(2) unconditionally marks the lock "has waiters". If prev
        // value was 0, owner released between our last spin iteration and
        // this exchange — we just acquired. Else lock is held by someone
        // and we futex_wait until *word changes from 2.
        //
        // FUTEX_WAIT is atomic w.r.t. the comparison: if *word != 2 at the
        // kernel-side check (e.g. another thread just unlocked), it returns
        // EAGAIN and we retry.
        while true {
            // If the previous value was `unlocked` the owner released between our last spin and this exchange - we just
            // acquired. Lock word is now `contended` even though we may be the sole holder (conservative but correct;
            // the next unlock will emit one spurious FUTEX_WAKE).
            if atomic_exchange_acquire_u32(word, State.contended.rawValue) == State.unlocked.rawValue {
                return
            }

            // Lock still held. Sleep while *word == contended.
            let err = futex_wait(word, State.contended.rawValue)
            switch err {
            case 0,       // woken by FUTEX_WAKE from unlocker
                 11,      // EAGAIN - *word changed before kernel sleep, retry
                 4:       // EINTR - interrupted by signal, retry
                break
            default:
                fatalError("Unknown error in futex_wait: \(err)")
            }
        }
    }

    @inlinable
    public func unlock() {
        // If the previous value was `contended`, a waiter is parked in the kernel and we must wake one via FUTEX_WAKE.
        // Design choice #2 - the fast path skips the syscall when prev was `locked` (no waiters).
        guard atomic_exchange_release_u32(word, State.unlocked.rawValue) == State.contended.rawValue else {
            // Unlocked, syscall-free (the common case).
            return
        }
        _ = futex_wake(word, 1)
    }
}
#endif
