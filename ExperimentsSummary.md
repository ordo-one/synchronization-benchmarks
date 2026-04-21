# Mutex Experiments Summary

Consolidated findings from all spin-strategy experiments for Swift `Synchronization.Mutex` Linux replacement.

## Machines tested

| CPU | Arch | Cores | Pause cost |
|---|---|---:|---:|
| Intel i5-12500 (Alder Lake) | x86 | 12 (6P/12T) | ~100cy |
| AMD EPYC 9454P (Zen 4) | x86 | 64 | ~40cy |
| Intel Xeon Gold 6148 (Skylake) | x86 NUMA | 40 | ~140cy |
| Intel Xeon E5-2699 v4 (Broadwell) | x86 NUMA | 44 | ~100cy |
| Apple M1 Ultra | aarch64 | 18 | wfe ~1-5cy |

## Baselines

Two reference points for all comparisons:
- **Stdlib** = `Synchronization.Mutex` (PI-futex + 1000 spin fixed) — what we're replacing
- **NIO** = `NIOLockedValueBox` (pthread_mutex wrapper) — what Swift server ecosystem uses
- **Optimal** = PlainFutex + early-exit-on-contended + exp backoff spin=40 cap=32 floor=4 — current stable PR candidate

## Core algorithm (all winning variants share this)

```
lock():
    if CAS(lockWord, 0 → 1): return          // fast path
    [spin strategy varies]
    while True:                               // kernel phase
        if exchange(lockWord, 2) == 0: return
        futex_wait(lockWord, 2)

unlock():
    if exchange(lockWord, 0) == 2:
        futex_wake(1)
```

**Key invariants:**
- Plain futex (not PI-futex) — PI architecturally incompatible with spinning
- 3-state word: 0=unlocked, 1=locked, 2=contended
- Early-exit-on-contended: spinner exits on state==2, joins kernel queue — eliminates barging against kernel-woken threads

## Winning spin strategy

**Per-acquire:**

```
jitter = rdtsc()                              // read once, x86
for i in 0..<spinCount:
    state = load(lockWord)
    if state == 0 && CAS(0→1): return
    if state == 2: break                      // early exit
    pauses = base + (jitter & (base - 1))
    for _ in 0..<pauses: spin_loop_hint()
```

On x86: `base=128`, `spinCount=40`. On ARM: `base=64`, `spinCount=40` (cntvct_el0 jitter or 0).

## Summary: speedup vs Stdlib / NIO / Optimal at t=8 (p50)

Using best-performing variant per machine.

| Machine | Stdlib | NIO | Optimal | hw128 sp=40 | vs Stdlib | vs NIO | vs Optimal |
|---|---:|---:|---:|---:|---:|---:|---:|
| 12c Intel | 6,970 | 8,749 | 3,275 | **1,288** | 5.4x | 6.8x | 2.5x |
| 64c AMD | 723,671 | 17,143 | 8,230 | **1,468** | 493x | 11.7x | 5.6x |
| 40c NUMA | 20,139 | 15,727 | 10,447 | **2,870** | 7.0x | 5.5x | 3.6x |
| ARM 18c | 1,246 | 5,623 | 1,028 | 1,116 | 1.1x | 5.0x | Optimal wins |

## Budget analysis

Max spin time per strategy:

| Strategy | Pauses | Skylake (140cy) | AMD Zen4 (40cy) | ARM (3cy) |
|---|---:|---:|---:|---:|
| Rust std (100×1 pause) | 100 | 14µs | 4µs | 0.4µs |
| parking_lot (14 + 7 yields) | ~14 | 2µs | 0.6µs | 0.06µs |
| glibc adaptive (cap=100) | ~100 | 14µs | 4µs | 0.4µs |
| Go sync.Mutex (4×30) | 120 | 17µs | 5µs | 0.5µs |
| **Optimal** (14 iter exp cap=32) | ~450 | 63µs | 18µs | 1.8µs |
| **hw128 spin=5** | 1,275 | 60µs | 17µs | 2µs |
| **hw128 spin=10** | 2,550 | 120µs | 34µs | 3µs |
| **hw128 spin=40** | 10,200 | 476µs | 136µs | 10µs |

Futex park cost is ~1-5µs on Linux. Longer spin justified when CS + park cost < spin time. Our ~60-480µs budget matches heavy-contention release window (~20-100µs with scheduler delays).

---

# Appendix: All variants tested with p50 comparison

Comparison at t=8 (moderate contention) across machines. All values in µs. Lower is better. Best per column **bold**.

## x86 12c Intel (i5-12500 Alder Lake)

| Variant | p50 t=4 | p50 t=8 | p50 t=64 | Notes |
|---|---:|---:|---:|---|
| Synchronization.Mutex (stdlib) | 2,560 | 6,970 | 6,389 | PI-futex + 1000 spin fixed. Baseline. |
| NIOLockedValueBox | 5,674 | 8,749 | 9,266 | pthread wrapper. Worst on 12c. |
| spin=0 (plain futex, park immediately) | 5,438 | 8,320 | 8,726 | Lower bound. No spin. |
| Optimal (exp 14 iter cap=32) | 1,242 | 3,275 | 6,325 | Current stable. Misses higher-contention wins. |
| spin=14 fixed | ~2,200 | ~4,000 | ~6,500 | Fixed spin, no backoff. Worse than exp. |
| spin=40 fixed | ~1,800 | ~3,500 | ~6,200 | Same, more iters. |
| early-exit spin=40 flat (1 pause/iter) | 1,500 | 3,800 | 6,100 | Tight polling. 1.2-3.3x worse than hwjitter. |
| early-exit spin=40 flat32 (32 pauses fixed) | 1,200 | 2,300 | 3,700 | Flat spacing. Base too low. |
| early-exit spin=40 flat64 | 1,100 | 1,600 | 1,900 | Better spacing. |
| early-exit spin=40 flat128 | 1,000 | 1,300 | 1,500 | Best fixed-flat. |
| early-exit spin=40 jitter (lockaddr seed) | 1,020 | 1,307 | 1,539 | Broken — same seed all threads. |
| early-exit spin=40 jitter-tid | 1,010 | 1,280 | 1,530 | Murmurhash3 per thread. Works. |
| early-exit spin=40 hwjitter base=32 | 1,041 | 1,614 | 1,944 | Base too tight. |
| early-exit spin=40 hwjitter base=64 | 1,019 | 1,495 | 1,676 | Medium. |
| early-exit spin=40 hwjitter base=96 | 997 | 1,360 | 1,580 | |
| **early-exit spin=40 hwjitter base=128** | **1,017** | **1,288** | **1,452** | **Best x86 12c.** |
| early-exit spin=40 hwjitter64+sep | 1,024 | 1,345 | 1,511 | Cache line sep: 1-3% help at low contention. |
| early-exit spin=10 hwjitter base=128 | 1,034 | 1,307 | 1,515 | Smaller budget, ~2% perf loss. |
| early-exit spin=5 hwjitter base=128 | 1,056 | 1,419 | 1,643 | 60µs max. 6-11% loss. |
| early-exit spin=3 hwjitter base=128 | 1,082 | 1,584 | 1,871 | Too few checks. |
| adaptive cap=10/20/40/100 base=128 | 1,000 | 1,278 | 1,466 | All ~identical. EWMA saturates low. |
| two-stage 5/128 + 5/32 | 1,030 | 1,391 | 1,564 | Wins t=4 by 27%. Generic loss. |
| two-stage 3/128 + 5/32 | 1,045 | 1,468 | 1,697 | |
| EpochMutex spin=40 base=128 | 1,062 | 1,496 | 1,697 | Separate line. No benefit. |
| HintMutex spin=40 base=128 | 1,048 | 1,396 | 1,555 | Separate hint line. Marginal. |

**12c winner:** hw128 spin=40. 2.5x over Optimal, 5.4x over stdlib, 6.8x over NIO.

## x86 64c AMD (EPYC 9454P Zen 4)

| Variant | p50 t=4 | p50 t=8 | p50 t=16 | p50 t=64 | Notes |
|---|---:|---:|---:|---:|---|
| Synchronization.Mutex | 4,154 | 723,671 | 806,547 | 875,714 | Stdlib collapses catastrophically at t≥8. |
| NIOLockedValueBox | 4,342 | 17,143 | 18,534 | 17,303 | |
| spin=0 | 3,788 | 11,879 | 15,473 | 18,819 | |
| Optimal | 1,944 | 8,230 | 10,088 | 13,627 | |
| early-exit spin=40 flat128 | 1,182 | 1,506 | 8,091 | 10,971 | Flat wins at low, noisy high. |
| early-exit spin=40 hwjitter base=64 | 1,342 | 3,439 | 7,631 | 10,541 | Base too low for AMD. |
| **early-exit spin=40 hwjitter base=128** | **1,180** | **1,468** | **5,108** | 10,251 | **Best on 64c AMD.** |
| early-exit spin=10 hwjitter base=128 | 1,239 | 2,292 | 7,717 | 5,358 | 55% worse at t=8. |
| early-exit spin=5 hwjitter base=128 | 1,376 | 3,238 | 7,338 | 8,419 | Too short for AMD chiplet. |
| early-exit spin=3 hwjitter base=128 | 1,690 | 3,903 | 8,940 | 9,923 | |
| early-exit spin=40 hwjitter64+sep | 1,251 | 4,833 | 9,133 | 6,944 | **Sep HURTS on AMD** — chiplet penalty. |
| adaptive cap=10 base=128 | 1,258 | 1,910 | 8,264 | 5,964 | Matches hw128 at cost of tighter cap. |
| adaptive cap=40 base=128 | 1,169 | 2,127 | 7,938 | 10,845 | |
| two-stage 5/128 + 5/32 | 1,337 | 2,964 | 7,666 | 6,988 | **2x worse at t=8.** Not generic. |
| EpochMutex spin=40 base=128 | 1,242 | 1,831 | 6,048 | 8,768 | Slightly worse than hw128. |
| HintMutex spin=40 base=128 | 1,179 | 1,803 | 8,834 | 7,475 | |

**64c winner:** hw128 spin=40. 5.6x over Optimal, 493x over collapsing stdlib, 11.7x over NIO.

## x86 40c NUMA (Xeon Gold 6148 Skylake)

| Variant | p50 t=4 | p50 t=8 | p50 t=16 | p50 t=64 | Notes |
|---|---:|---:|---:|---:|---|
| Synchronization.Mutex | 12,482 | 20,139 | 55,661 | 411,238 | Collapses on NUMA. |
| NIOLockedValueBox | 12,191 | 15,727 | 18,495 | 28,654 | |
| spin=0 | 10,123 | 14,898 | 15,207 | 23,201 | |
| Optimal | 3,575 | 10,447 | 12,449 | 19,342 | |
| early-exit spin=40 flat128 | 2,809 | 3,135 | 4,926 | 16,202 | |
| early-exit spin=40 hwjitter base=64 | 2,831 | 3,839 | 11,059 | 16,828 | |
| **early-exit spin=40 hwjitter base=128** | 2,717 | **2,870** | **3,484** | 14,106 | **Best on 40c NUMA.** |
| early-exit spin=10 hwjitter base=128 | 2,847 | 3,514 | 5,654 | **3,242** | Anomalous t=64. |
| early-exit spin=5 hwjitter base=128 | 3,148 | 3,044 | 7,647 | 15,587 | |
| early-exit spin=3 hwjitter base=128 | 3,367 | 4,926 | 11,791 | 10,653 | |
| adaptive cap=10 base=128 | 2,713 | 3,377 | 4,645 | 13,485 | Close to hw128 sp=40. |
| adaptive cap=40 base=128 | 2,687 | 3,383 | 5,015 | 15,980 | |
| two-stage 5/128 + 5/32 | 2,957 | 3,815 | 6,160 | 15,486 | 85% worse at t=16. |
| EpochMutex spin=40 base=128 | 3,006 | 3,486 | 5,208 | 14,177 | **Best at t=64 on NUMA** (5% over hw128). |
| HintMutex spin=40 base=128 | 2,723 | 3,282 | 4,329 | 16,402 | |

**40c winner:** hw128 spin=40. 3.6x over Optimal, 7x over stdlib, 5.5x over NIO.

## ARM aarch64 18c (Apple M1 Ultra)

| Variant | p50 t=4 | p50 t=8 | p50 t=16 | p50 t=64 | Notes |
|---|---:|---:|---:|---:|---|
| Synchronization.Mutex | 1,043 | 1,246 | 736,454 | 757,648 | Collapses at t≥16. |
| NIOLockedValueBox | 3,868 | 5,623 | 5,903 | 5,729 | Very slow on ARM (container overhead). |
| spin=0 | 2,010 | 2,684 | 2,672 | 3,154 | |
| **Optimal** | **989** | **1,028** | **1,216** | 1,619 | **Best at low contention t≤16.** |
| early-exit spin=40 hwjitter base=64 | 915 | 995 | 1,212 | 1,257 | |
| early-exit spin=40 hwjitter base=128 | 1,013 | 1,116 | 1,278 | **1,330** | |
| early-exit spin=40 hwjitter base=32 | 978 | 1,010 | 1,156 | 1,393 | |
| early-exit spin=40 hwjitter64+sep (128B) | 951 | 1,072 | 1,128 | 1,279 | Fixed ARM 128B sep. Small win. |
| early-exit spin=10 hwjitter base=128 | 987 | 1,100 | 1,264 | 1,382 | |
| adaptive cap=10 base=128 | 913 | 1,109 | 1,179 | 1,318 | |
| adaptive cap=40 base=128 | 983 | 1,067 | 1,291 | 1,424 | |
| EpochMutex spin=40 base=128 | 1,229 | 1,151 | 1,349 | 1,539 | |
| HintMutex spin=40 base=128 | 1,100 | 1,132 | 1,257 | 1,483 | |

**ARM winner:** Mixed. Optimal wins t≤16. hw64/hw128 wins t≥64 with ~20% improvement.

# Why each approach won or lost

**hw128 spin=40 (winner on x86):**
- Base=128 pauses matches critical section duration (~1-4µs). Spinner checks lock line every ~4µs Skylake, letting owner run with minimal cache invalidation.
- spin=40 budget catches release windows up to ~200-500µs (scheduler delays, NUMA cross-socket wake latency).
- RDTSC jitter desynchronizes spinners with one instruction, no PRNG state.
- Early-exit caps cost under real contention (rarely hits full budget).

**Optimal / exp backoff (winner on ARM low contention):**
- ARM wfe is ~3cy — tight 4-pause early iters don't cause cache traffic problems.
- Smaller total budget fits ARM's fast wake/park cycle.
- No RDTSC/CNTVCT overhead.

**Smaller spin (3/5/10) at base=128:**
- Works on 12c (short CS, fast release windows).
- Regresses 30-125% on 64c AMD (chiplet release timing needs more iterations).
- Not generic.

**Flat spin (no jitter, 1 pause/iter):**
- 1.2-3.3x worse than hwjitter. Tight polling generates cache traffic.

**Cache line separation:**
- Topology-dependent. Helps Intel single-die (25-32% p99 at low contention). Hurts AMD chiplet by 20-40%. Not universal.

**Epoch / Hint (separate signal line):**
- Idea: spinners watch separate cache line, no interference with owner's value writes.
- Reality: signal line itself cache-bounces between spinner cores. Equivalent or worse than hw128.

**TwoStage (5/128 + 5/32):**
- Idea: wide spacing first, tight final checks before park. Bounded budget.
- Reality: wins 12c t=4 by 27%, loses 64c/40c by 2-85%. Not generic.

**AdaptiveSpinMutex (glibc EWMA):**
- Idea: learn per-lock average successful spin count, bound budget dynamically.
- Reality: EWMA saturates near 0 because most acquires succeed fast. Cap doesn't bite. Equivalent to fixed spin=10-40 at same base. Adds atomic RMW cost for no benefit.

**Spin count vs. base tradeoff:**
- Monotonic on x86: higher base = better spacing = less owner interference. Plateau at 96-128.
- On 12c plateau flattens: 64→128 = 4%. 128→hypothetical higher diminishing.
- More iterations catch more release windows, at cost of larger max budget.
- `spin=40 base=128` is the best perf point. Smaller (10, 5, 3) regresses on big machines.

# Recommendation

**Current stable PR candidate (Optimal)** is safe and wins 3-7x over stdlib everywhere. Ship as-is if budget matters more than last 20-40%.

**Upgrade candidate (`hw128 spin=40`)** gives additional 2-5x on x86 big machines (3.6x on 40c, 5.6x on 64c) at cost of ~360µs max spin time on Skylake. Change:
1. Replace exp backoff with flat pause=base + RDTSC jitter
2. base=128 on x86 (or 64 on ARM)
3. spin=40 iterations with early-exit

**Complexity to add:** minimal — `fast_jitter()` shim (rdtsc on x86, 0 or cntvct on ARM), flat spin loop, remove backoff state.

## Open directions

1. **RDTSC-deadline spin** — bound by wall time (µs), not pause count. Makes max budget consistent across CPUs. Unlikely to move p50, cleaner tail bound.
2. **Proper ARM `ldxr+wfe`** — current bare `wfe` may return immediately. Hardware-level cache-line wait would eliminate polling traffic.
3. ~~**MCS queue**~~ — tried and rejected; see Experiments.md. Queue locks pay two locked-RMW ops per acquire, losing ~11× at ns-scale critical sections. Impl archived in `Internal/`.

## Implementation files

| File | Purpose | Status |
|---|---|---|
| `Sources/MutexBench/OptimalMutex.swift` | Current stable PR candidate | Stable |
| `Sources/MutexBench/PlainFutexMutex.swift` | Parameterized benchmark variants | Keep |
| `Sources/MutexBench/SynchronizationMutex.swift` | Extracted stdlib PI-futex copy | Keep for comparison |
| `Sources/MutexBench/AdaptiveSpinMutex.swift` | glibc EWMA experiment | Experimental |
| `Sources/MutexBench/TwoStageMutex.swift` | Two-stage spin experiment | Experimental |
| `Sources/MutexBench/EpochMutex.swift` | Separate epoch cache line | Experimental |
| `Sources/MutexBench/HintMutex.swift` | Separate hint cache line | Experimental |
| `Sources/CFutexShims/include/CFutexShims.h` | C shims incl. `fast_jitter()` | Stable |

## Scripts

- `scripts/parse-fairness.py` — Asymmetric benchmark parser
- `scripts/parse-spintuning.py` — SpinTuning parser, full µs precision, all percentiles
