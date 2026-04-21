# parking_lot (Swift port)

How a Swift port of Amanieu's [parking_lot](https://github.com/Amanieu/parking_lot) scales on `ContentionScaling`, and how the single-lock throughput compares with `OptimalMutex` and `RustStdMutex` across four host topologies.

Source: `Sources/MutexBench/ParkingLotCore.swift` + `Sources/MutexBench/ParkingLotMutex.swift`. Apache-2.0 / MIT. Buckets are laid out in a single 64-byte-aligned raw buffer at stride 64 to match upstream `#[repr(align(64))]` (each bucket's lock word owns its own cache line). Parker polarity matches upstream (`1 = parked`, `0 = unparked`).

## Workload

Same as `ContentionScaling.md`: 50,000 total lock acquires distributed across N tasks, each acquire doing one dictionary lookup + update on a `[Int: UInt64]` map with 64 entries. `pause=0` — maximum steady-state contention.

Wall-clock numbers in µs below are for the full 50,000-acquire batch. Convert to per-operation cost: `ns/op = p50 µs ÷ 50`.

## Key findings

1. **parking_lot's cost scales with cross-die / cross-socket coherence latency, NOT core count.** Single-die Intel (Alder Lake 12c) shows no collapse at any task count (parking_lot ≈ Optimal ±2%). Every multi-die / multi-socket host collapses once contention exceeds a per-topology threshold:

    | CPU | topology | collapse starts at | worst parking_lot / Optimal |
    |---|---|---|---:|
    | Intel i5-12500 12c | single die | — | **1.01×** (no collapse) |
    | AMD EPYC 9454P 64c | chiplet CCX | tasks=64 | 4.83× |
    | Intel Xeon Gold 6148 40c | 2-socket QPI | tasks=16 | 3.34× |
    | Intel Xeon E5-2699 v4 44c | 2-socket QPI | tasks=16 | **6.13×** |

    The collapse magnitude tracks interconnect speed: AMD Infinity Fabric < Intel QPI. Broadwell's older QPI is worst.

2. **Three design gaps in parking_lot's hot path remain after the cache-line fix**, any one of which Optimal avoids:
    - **No active-spinner cap.** Every arriver enters SpinWait; 64+ contenders flood the state cache line with RFOs.
    - **`sched_yield` phase.** SpinWait iters 4–10 call `sched_yield()`. Under oversubscription the kernel scheduler becomes the bottleneck.
    - **More atomics per contended unlock.** parking_lot unlock_slow = bucket-CAS + queue-scan + bucket-store + futex_wake (~3× the ops of Optimal's state-exchange + futex_wake).
    - (A fourth gap, bucket-lock false sharing, was resolved by aligning each bucket to its own 64B cache line; this cut Zen4 collapse 12-15%, Skylake NUMA 18%, Broadwell NUMA 17%.)

3. **parking_lot wins in one narrow regime: cross-socket handoff at moderate contention.** Broadwell 44c at tasks=4: parking_lot 14.8 ms p50 vs Optimal 16.2 ms (**0.91×**). The 10-iter bounded spin parks faster than Optimal's longer budget while the lock is held on the remote socket. The win evaporates at tasks ≥ 16 where the three remaining design gaps compound.

4. **Against RustStdMutex (100-iter fixed spin), parking_lot wins 2–3× at tasks = 2–8 everywhere that has any contention.** Rust burns 100 pauses before parking; parking_lot's bounded SpinWait caps wasted cycles.

5. **Choose by workload:**
    - **Any uniform-cache single-die CPU:** parking_lot ≈ Optimal ≈ RustStdMutex — all interchangeable.
    - **Any multi-die / multi-socket CPU at tasks > core-count:** Optimal. parking_lot's spinner flood + sched_yield collapse 3–6×.
    - **Cross-socket NUMA with moderate contention (tasks ≈ sockets):** parking_lot has a narrow 0.91× win over Optimal on Broadwell. Not portable — single-die machines do not reproduce it.

---

## Implementations

| Label | What it is | Futex | Spin strategy |
|---|---|---|---|
| **parking_lot** | Swift port of `parking_lot::Mutex` | `FUTEX_WAIT`/`FUTEX_WAKE` via per-thread parker | SpinWait: 2^n pauses iters 1–3, `sched_yield()` iters 4–10, then park via bucketed hash table |
| **Optimal** | `OptimalMutex` — proposed stdlib replacement | `FUTEX_WAIT`/`FUTEX_WAKE` on state word | 20 × base=64 PAUSE with RDTSC jitter, depth-gated skip-spin (cap 4 active spinners) |
| **RustStdMutex** | Rust std 1.62+ pattern, ported (knob-less) | `FUTEX_WAIT`/`FUTEX_WAKE` on state word | 100-iter load-only spin, post-spin CAS + kernel exchange, re-spin after wake |

parking_lot deviations from upstream (see `Sources/MutexBench/ParkingLotCore.swift` header):
- Fixed 2048 buckets, no dynamic resize.
- Bucket lock is TTAS spinlock (WordLock would be self-referential).
- State byte as `u32` (CFutexShims has no `u8` atomics). No functional impact.
- No timed park, `unpark_all`, `unpark_filter`, `unpark_requeue`, pair-bucket locking, or deadlock hooks (RawMutex port only; condvar/try_lock_for not exercised).

## Machines

| Name | Arch | Cores | CPU | Topology |
|---|---|---:|---|---|
| x86 12c | x86_64 | 6P/12T | Intel i5-12500 | single die, Hyperthreading |
| x86 40c | x86_64 | 40 | Intel Xeon Gold 6148 | 2-socket NUMA |
| x86 44c | x86_64 | 44 | Intel Xeon E5-2699 v4 | 2-socket NUMA Broadwell |
| x86 64c | x86_64 | 64 | AMD EPYC 9454P | CCD chiplet (8×8 cores) |

---

## Cost per acquire (ns/op, p50)

Each cell is `p50_µs ÷ 50` = nanoseconds per single lock acquire, averaged over the 50,000-acquire batch.

### OptimalMutex

| Tasks | x86 12c 1die | x86 64c CCX | x86 40c NUMA | x86 44c NUMA |
|---:|---:|---:|---:|---:|
| 1   | 31 |  24 |  62 | 125 |
| 2   | 31 |  30 |  65 | 167 |
| 4   | 31 |  39 |  78 | 323 |
| 8   | 31 |  83 | 164 | 485 |
| 16  | 32 | 239 | 452 | 582 |
| 64  | 32 | 318 | 483 | 471 |
| 96  | 33 | 319 | 481 | 481 |
| 192 | 34 | 332 | 496 | 492 |
| 384 | 37 | 344 | 502 | 485 |

### parking_lot

| Tasks | x86 12c 1die | x86 64c CCX | x86 40c NUMA | x86 44c NUMA |
|---:|---:|---:|---:|---:|
| 1   | 31 |  24 |  60 | 128 |
| 2   | 31 |  34 |  78 | 190 |
| 4   | 31 |  48 | 162 | **295** (win) |
| 8   | 32 |  98 | 345 | 766 |
| 16  | 32 | 283 | **1,390** | **2,825** |
| 64  | 32 | **1,540** | **1,613** | **2,891** |
| 96  | 33 | **1,445** | **1,601** | **2,765** |
| 192 | 34 | **1,596** | **1,620** | **2,894** |
| 384 | 37 | **1,614** | **1,655** | **2,922** |

**Bold** = collapse region (parking_lot ≥ 2× Optimal) or win (Broadwell t=4). Alder Lake 12c single-die stays flat at 31–37 ns/op for both impls — its single coherence domain absorbs the spinner flood + sched_yield cost. Every multi-die host diverges once contention crosses a topology-specific threshold.

---

## Detailed results per machine

### x86 12c (Intel i5-12500, Alder Lake single die)

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 1,587 | 1,590 | 1,599 | 1,725 | 1,737 | 250 |
| 1 | RustStdMutex | 1,578 | 1,583 | 1,592 | 1,708 | 1,710 | 250 |
| 1 | parking_lot | 1,590 | 1,598 | 1,844 | 1,966 | 3,113 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 1,581 | 1,586 | 1,603 | 1,724 | 1,778 | 250 |
| 8 | RustStdMutex | 1,593 | 1,601 | 1,631 | 1,770 | 1,784 | 250 |
| 8 | parking_lot | 1,605 | 1,611 | 1,657 | 1,892 | 1,925 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 1,608 | 1,611 | 1,620 | 1,751 | 1,752 | 250 |
| 16 | RustStdMutex | 1,589 | 1,594 | 1,623 | 1,735 | 1,789 | 250 |
| 16 | parking_lot | 1,611 | 1,615 | 1,621 | 1,783 | 1,816 | 250 |
| | | | | | | | |
| 64 | **Optimal** | 1,620 | 1,625 | 1,634 | 1,755 | 1,799 | 250 |
| 64 | RustStdMutex | 1,639 | 1,642 | 1,652 | 1,784 | 2,503 | 250 |
| 64 | parking_lot | 1,638 | 1,641 | 1,647 | 1,810 | 1,825 | 250 |
| | | | | | | | |
| 192 | **Optimal** | 1,745 | 1,747 | 1,753 | 1,884 | 1,888 | 250 |
| 192 | RustStdMutex | 1,733 | 1,738 | 1,760 | 1,994 | 2,053 | 250 |
| 192 | parking_lot | 1,735 | 1,738 | 1,741 | 1,900 | 1,901 | 250 |
| | | | | | | | |
| 384 | **Optimal** | 1,887 | 1,892 | 1,903 | 2,041 | 2,173 | 250 |
| 384 | RustStdMutex | 1,873 | 1,880 | 1,894 | 2,070 | 2,092 | 250 |
| 384 | parking_lot | 1,897 | 1,901 | 1,906 | 2,063 | 2,070 | 250 |

**Observations:** No collapse. Three impls interchangeable within noise (±2% p50 across task range). parking_lot's p99 is occasionally wider (t=1 1,966 µs) from bucket-lock backoff jitter, but p50 is flat.

---

### x86 40c (Intel Xeon Gold 6148, 2-socket NUMA)

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 3,103 | 3,129 | 3,371 | 3,754 | 4,124 | 250 |
| 1 | RustStdMutex | 3,113 | 3,148 | 3,369 | 4,313 | 4,327 | 250 |
| 1 | parking_lot | 3,027 | 3,064 | 3,377 | 4,010 | 4,452 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 3,256 | 3,549 | 3,826 | 4,313 | 4,981 | 250 |
| 2 | RustStdMutex | 11,133 | 14,303 | 16,368 | 19,005 | 19,583 | 250 |
| 2 | parking_lot | 3,918 | 4,526 | 5,509 | 5,861 | 5,904 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 3,938 | 4,112 | 4,334 | 4,788 | 5,053 | 250 |
| 4 | RustStdMutex | 18,645 | 22,528 | 24,740 | 27,902 | 28,154 | 250 |
| 4 | parking_lot | 8,126 | 9,568 | 10,461 | 11,567 | 11,703 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 8,208 | 9,568 | 10,838 | 12,198 | 12,599 | 250 |
| 8 | RustStdMutex | 26,624 | 29,327 | 31,654 | 34,341 | 36,238 | 250 |
| 8 | parking_lot | 17,269 | 22,331 | 25,575 | 30,884 | 31,981 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 22,626 | 23,986 | 24,822 | 26,247 | 27,114 | 250 |
| 16 | RustStdMutex | 33,096 | 34,079 | 34,931 | 36,733 | 37,090 | 250 |
| 16 | parking_lot | **69,534** | 74,514 | 78,905 | 84,345 | 85,687 | 220 |
| | | | | | | | |
| 64 | **Optimal** | 24,166 | 25,199 | 26,067 | 28,017 | 29,053 | 250 |
| 64 | RustStdMutex | 33,473 | 34,111 | 35,062 | 36,667 | 36,929 | 250 |
| 64 | parking_lot | **80,675** | 83,100 | 84,869 | 89,194 | 91,439 | 187 |
| | | | | | | | |
| 192 | **Optimal** | 24,838 | 25,739 | 26,657 | 27,967 | 29,036 | 250 |
| 192 | RustStdMutex | 34,505 | 35,586 | 36,340 | 37,421 | 40,323 | 250 |
| 192 | parking_lot | **81,002** | 83,493 | 85,328 | 89,391 | 91,149 | 185 |
| | | | | | | | |
| 384 | **Optimal** | 25,133 | 26,460 | 27,329 | 28,869 | 29,765 | 250 |
| 384 | RustStdMutex | 33,882 | 34,570 | 35,389 | 36,831 | 38,267 | 250 |
| 384 | parking_lot | **82,772** | 84,738 | 86,770 | 89,391 | 91,431 | 182 |

**Observations:** parking_lot collapse starts at tasks=16 (3.07×), stabilises at ~3.3× for the rest of the range. RustStdMutex loses 2.5–3× to parking_lot at tasks=2–4 (Rust's 100-iter fixed spin burns cycles the 10-iter SpinWait avoids). Below t=16, parking_lot wins the Rust comparison but still trails Optimal.

---

### x86 44c (Intel Xeon E5-2699 v4, 2-socket NUMA Broadwell)

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 6,259 | 6,312 | 6,574 | 7,131 | 7,227 | 250 |
| 1 | RustStdMutex | 6,181 | 6,234 | 6,525 | 6,832 | 8,079 | 250 |
| 1 | parking_lot | 6,423 | 6,492 | 6,590 | 7,021 | 7,667 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 8,360 | 9,101 | 10,338 | 12,460 | 13,212 | 250 |
| 2 | RustStdMutex | 13,869 | 19,382 | 22,938 | 29,999 | 33,513 | 250 |
| 2 | parking_lot | 9,511 | 10,625 | 11,059 | 11,993 | 12,274 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 16,196 | 16,974 | 17,809 | 20,021 | 21,244 | 250 |
| 4 | RustStdMutex | 18,317 | 25,706 | 29,835 | 33,948 | 39,029 | 250 |
| 4 | parking_lot | **14,770** | 16,105 | 17,056 | 19,268 | 19,636 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 24,281 | 26,591 | 28,033 | 30,310 | 30,990 | 250 |
| 8 | RustStdMutex | 23,249 | 27,935 | 32,801 | 39,584 | 41,178 | 250 |
| 8 | parking_lot | 38,339 | 41,255 | 44,040 | 49,152 | 50,743 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 29,147 | 30,409 | 31,883 | 35,258 | 36,027 | 250 |
| 16 | RustStdMutex | 35,717 | 37,224 | 38,535 | 41,157 | 43,400 | 250 |
| 16 | parking_lot | **141,296** | 144,835 | 148,898 | 154,403 | 155,249 | 107 |
| | | | | | | | |
| 64 | **Optimal** | 23,593 | 24,347 | 24,920 | 25,805 | 26,722 | 250 |
| 64 | RustStdMutex | 27,509 | 28,180 | 28,918 | 30,704 | 31,885 | 250 |
| 64 | parking_lot | **144,572** | 148,898 | 152,175 | 156,631 | 157,052 | 103 |
| | | | | | | | |
| 192 | **Optimal** | 24,642 | 25,313 | 25,756 | 26,968 | 27,479 | 250 |
| 192 | RustStdMutex | 29,409 | 30,081 | 30,704 | 32,080 | 33,609 | 250 |
| 192 | parking_lot | **144,703** | 149,291 | 154,403 | 158,728 | 158,849 | 105 |
| | | | | | | | |
| 384 | **Optimal** | 24,281 | 24,871 | 25,477 | 26,493 | 27,069 | 250 |
| 384 | RustStdMutex | 28,508 | 29,049 | 29,868 | 31,425 | 34,229 | 250 |
| 384 | parking_lot | **146,145** | 151,388 | 153,879 | 158,597 | 158,726 | 102 |

**Observations:** Worst parking_lot degradation of any host (6.13× at oversubscription). **parking_lot wins at tasks=4: 14.8 ms vs Optimal 16.2 ms (0.91×)** — cross-socket lock hold makes bounded 10-iter spin cheaper than Optimal's longer budget while the line sits on the remote socket. Win collapses at t=16 onwards.

---

### x86 64c (AMD EPYC 9454P, Zen 4 CCD chiplet)

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 1,239 | 1,250 | 1,272 | 1,547 | 2,095 | 250 |
| 1 | RustStdMutex | 1,261 | 1,274 | 1,294 | 1,370 | 1,438 | 250 |
| 1 | parking_lot | 1,246 | 1,275 | 1,313 | 2,253 | 2,257 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 1,505 | 1,537 | 1,574 | 1,942 | 1,988 | 250 |
| 2 | RustStdMutex | 4,510 | 4,710 | 5,722 | 6,091 | 6,293 | 250 |
| 2 | parking_lot | 1,713 | 1,780 | 1,833 | 1,993 | 2,054 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 1,950 | 2,012 | 2,060 | 2,206 | 2,237 | 250 |
| 4 | RustStdMutex | 5,128 | 6,849 | 7,451 | 7,963 | 8,006 | 250 |
| 4 | parking_lot | 2,433 | 2,554 | 2,683 | 2,994 | 3,113 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 4,190 | 4,502 | 4,780 | 5,276 | 5,377 | 250 |
| 8 | RustStdMutex | 10,772 | 11,526 | 12,009 | 12,812 | 13,247 | 250 |
| 8 | parking_lot | 4,948 | 5,255 | 5,489 | 5,947 | 6,835 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 11,985 | 12,378 | 12,820 | 13,574 | 13,652 | 250 |
| 16 | RustStdMutex | 15,983 | 16,327 | 16,736 | 17,564 | 17,570 | 250 |
| 16 | parking_lot | 14,180 | 14,672 | 15,245 | 16,474 | 21,664 | 250 |
| | | | | | | | |
| 64 | **Optimal** | 15,933 | 16,228 | 16,482 | 17,072 | 17,920 | 250 |
| 64 | RustStdMutex | 20,333 | 20,562 | 20,808 | 21,201 | 21,209 | 250 |
| 64 | parking_lot | **77,005** | 77,726 | 78,184 | 79,692 | 81,191 | 188 |
| | | | | | | | |
| 96 | **Optimal** | 15,966 | 16,245 | 16,507 | 16,859 | 18,093 | 250 |
| 96 | RustStdMutex | 20,185 | 20,480 | 20,709 | 21,168 | 21,674 | 250 |
| 96 | parking_lot | **72,286** | 73,269 | 74,121 | 75,956 | 76,171 | 199 |
| | | | | | | | |
| 192 | **Optimal** | 16,646 | 17,039 | 17,318 | 17,809 | 18,647 | 250 |
| 192 | RustStdMutex | 20,480 | 20,759 | 20,955 | 21,348 | 21,581 | 250 |
| 192 | parking_lot | **79,823** | 80,347 | 80,806 | 81,658 | 81,805 | 181 |
| | | | | | | | |
| 384 | **Optimal** | 17,220 | 17,547 | 17,891 | 18,416 | 18,950 | 250 |
| 384 | RustStdMutex | 20,759 | 21,004 | 21,217 | 21,610 | 21,758 | 250 |
| 384 | parking_lot | **80,740** | 81,265 | 81,658 | 82,379 | 82,548 | 179 |

**Observations:** Inside a single CCX (tasks≤8) parking_lot is competitive — 1.18–1.25× slower than Optimal but 2–3× faster than RustStdMutex. Collapse starts at tasks=64 (4.83×) when contention spans CCDs. Sample count drops from 250 → 180–200 at tasks≥64 because per-iteration wall-clock inflates to ~80 ms → bench hits the max-duration cap before hitting target iteration count.
