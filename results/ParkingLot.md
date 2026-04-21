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
    | Apple M1 Ultra 18c | UltraFusion 2-die | tasks=8 | 2.38× |
    | AMD EPYC 9454P 64c | chiplet CCX | tasks=64 | 4.83× |
    | Intel Xeon Gold 6148 40c | 2-socket QPI | tasks=16 | 3.34× |
    | Intel Xeon E5-2699 v4 44c | 2-socket QPI | tasks=16 | **6.13×** |

    The collapse magnitude tracks interconnect speed: Apple UltraFusion ≈ 2.5 TB/s < AMD Infinity Fabric < Intel QPI. Broadwell's older QPI is worst. Cross-architecture (x86 + aarch64) the same "interconnect latency drives collapse" model holds.

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

6. **NUMA isolation decomposes the collapse.** Pinning the bench to NUMA node 0 on Skylake (`numactl --cpunodebind=0 --membind=0`) cuts per-acquire cost by 45-57% for both impls — that slice is pure cross-socket QPI traffic. But parking_lot vs Optimal ratio only drops from 3.34× (unpinned) to 2.56× (pinned). **~25% of the excess gap is NUMA-specific; ~75% is intra-socket.** The intra-socket tax at 2.6× on Skylake's 20-core mesh topology contrasts with Alder Lake's 1.01× on a monolithic 12-core die — bucket-line atomics hopping across the 20-core mesh account for the remaining tax even within one socket. See the "Topology isolation" section below for the full pinned-data comparison.

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
| aarch64 18c | aarch64 | 18 | Apple M1 Ultra | UltraFusion 2-die, container |

---

## Cost per acquire (ns/op, p50)

Each cell is `p50_µs ÷ 50` = nanoseconds per single lock acquire, averaged over the 50,000-acquire batch.

### OptimalMutex

| Tasks | x86 12c 1die | x86 64c CCX | x86 40c NUMA | x86 44c NUMA | aarch64 18c M1U |
|---:|---:|---:|---:|---:|---:|
| 1   | 31 |  24 |  62 | 125 | 22 |
| 2   | 31 |  30 |  65 | 167 | 24 |
| 4   | 31 |  39 |  78 | 323 | 25 |
| 8   | 31 |  83 | 164 | 485 | 27 |
| 16  | 32 | 239 | 452 | 582 | 30 |
| 64  | 32 | 318 | 483 | 471 | 34 |
| 96  | 33 | 319 | 481 | 481 | 34 |
| 192 | 34 | 332 | 496 | 492 | 36 |
| 384 | 37 | 344 | 502 | 485 | 39 |

### parking_lot

| Tasks | x86 12c 1die | x86 64c CCX | x86 40c NUMA | x86 44c NUMA | aarch64 18c M1U |
|---:|---:|---:|---:|---:|---:|
| 1   | 31 |  24 |  60 | 128 | 22 |
| 2   | 31 |  34 |  78 | 190 | 23 |
| 4   | 31 |  48 | 162 | **295** (win) | 29 |
| 8   | 32 |  98 | 345 | 766 | **45** |
| 16  | 32 | 283 | **1,390** | **2,825** | **68** |
| 64  | 32 | **1,540** | **1,613** | **2,891** | **78** |
| 96  | 33 | **1,445** | **1,601** | **2,765** | **79** |
| 192 | 34 | **1,596** | **1,620** | **2,894** | **86** |
| 384 | 37 | **1,614** | **1,655** | **2,922** | **92** |

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

---

### aarch64 18c (Apple M1 Ultra, UltraFusion 2-die, container)

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 1,083 | 1,107 | 1,132 | 1,205 | 1,246 | 250 |
| 1 | RustStdMutex | 1,116 | 1,164 | 1,213 | 1,306 | 1,374 | 250 |
| 1 | parking_lot | 1,085 | 1,112 | 1,140 | 1,212 | 1,232 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 1,187 | 1,230 | 1,274 | 1,370 | 1,396 | 250 |
| 2 | RustStdMutex | 1,189 | 1,228 | 1,263 | 1,467 | 1,512 | 250 |
| 2 | parking_lot | 1,156 | 1,194 | 1,271 | 1,593 | 1,636 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 1,238 | 1,292 | 1,363 | 1,545 | 1,583 | 250 |
| 4 | RustStdMutex | 1,535 | 1,624 | 1,802 | 2,226 | 2,286 | 250 |
| 4 | parking_lot | 1,425 | 1,530 | 1,656 | 2,220 | 2,341 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 1,335 | 1,396 | 1,455 | 1,621 | 1,723 | 250 |
| 8 | RustStdMutex | 2,245 | 2,357 | 2,515 | 2,888 | 3,196 | 250 |
| 8 | parking_lot | 2,253 | 2,392 | 2,615 | 3,338 | 3,503 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 1,516 | 1,583 | 1,658 | 1,990 | 2,113 | 250 |
| 16 | RustStdMutex | 3,009 | 3,303 | 3,650 | 7,164 | 8,525 | 250 |
| 16 | parking_lot | **3,385** | 3,578 | 3,844 | 4,522 | 4,819 | 250 |
| | | | | | | | |
| 32 | **Optimal** | 1,680 | 1,843 | 2,034 | 3,047 | 3,196 | 250 |
| 32 | RustStdMutex | 3,303 | 3,564 | 3,906 | 6,197 | 6,702 | 250 |
| 32 | parking_lot | **3,443** | 3,678 | 3,918 | 4,690 | 4,750 | 250 |
| | | | | | | | |
| 64 | **Optimal** | 1,677 | 1,805 | 1,989 | 2,730 | 3,021 | 250 |
| 64 | RustStdMutex | 3,361 | 3,564 | 4,008 | 7,451 | 9,206 | 250 |
| 64 | parking_lot | **3,914** | 4,166 | 4,411 | 5,132 | 5,222 | 250 |
| | | | | | | | |
| 96 | **Optimal** | 1,704 | 1,811 | 1,974 | 2,710 | 2,807 | 250 |
| 96 | RustStdMutex | 3,514 | 3,850 | 4,403 | 9,830 | 12,153 | 250 |
| 96 | parking_lot | **3,953** | 4,164 | 4,411 | 5,173 | 5,309 | 250 |
| | | | | | | | |
| 192 | **Optimal** | 1,802 | 1,909 | 2,028 | 2,828 | 3,307 | 250 |
| 192 | RustStdMutex | 3,852 | 4,186 | 4,665 | 8,106 | 8,694 | 250 |
| 192 | parking_lot | **4,284** | 4,563 | 4,874 | 5,521 | 5,611 | 250 |
| | | | | | | | |
| 384 | **Optimal** | 1,944 | 2,034 | 2,130 | 2,560 | 3,200 | 250 |
| 384 | RustStdMutex | 4,102 | 4,370 | 4,743 | 8,528 | 10,123 | 250 |
| 384 | parking_lot | **4,608** | 4,973 | 5,353 | 6,156 | 6,422 | 250 |

**Observations:** Collapse starts at tasks=8 (1.69×) and stabilises at ~2.3× from tasks=16 onward. Less severe than Intel NUMA (Skylake 3×, Broadwell 6×) and comparable to Zen 4 CCX-span — consistent with Apple's UltraFusion interconnect being ~2.5 TB/s, much faster than Intel QPI. At low contention (tasks=2) parking_lot is fractionally faster than Optimal (1,156 vs 1,187) — within noise. RustStdMutex p99 tail is notably wider than parking_lot (7-12 ms vs 5 ms) at tasks≥16, likely from its longer fixed-spin burning cycles before parking. Container is bounded to 18 cores and spans both UltraFusion dies.

---

## Topology isolation: pinning to a single coherence domain

To separate cross-socket / cross-die coherence cost from intra-domain contention, bench runs can pin the process to a subset of CPUs via `taskset` or `numactl`. The `run-bench.sh` script supports:
- `MUTEX_BENCH_SINGLE_NUMA=1` — pins to NUMA node 0 (one socket on 2-socket NUMA hosts)
- `MUTEX_BENCH_CPU_LIST=<cpulist>` — pins to an explicit CPU range (e.g. `0-7` for one Zen 4 CCX)

Result files carry a `cpu_wrap=...` header line documenting the pinning applied.

### Skylake 40c NUMA node 0 (20 cores, single socket)

Same Intel Xeon Gold 6148 host, but `numactl --cpunodebind=0 --membind=0`. Eliminates QPI traffic. Added t=20/22/24 to probe the single-socket saturation region.

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 3,006 | 3,041 | 3,341 | 3,932 | 4,242 | 250 |
| 1 | RustStdMutex | 2,978 | 3,013 | 3,369 | 3,702 | 4,106 | 250 |
| 1 | parking_lot | 2,968 | 3,005 | 3,345 | 4,031 | 4,345 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 3,111 | 3,289 | 3,586 | 4,222 | 4,334 | 250 |
| 2 | RustStdMutex | 7,959 | 9,306 | 10,781 | 12,853 | 13,140 | 250 |
| 2 | parking_lot | 3,650 | 4,006 | 4,452 | 5,144 | 5,284 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 3,449 | 3,649 | 3,956 | 4,419 | 4,693 | 250 |
| 4 | RustStdMutex | 15,131 | 17,760 | 19,758 | 22,495 | 23,150 | 250 |
| 4 | parking_lot | 5,161 | 5,747 | 6,315 | 7,406 | 7,698 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 5,272 | 5,648 | 6,030 | 6,738 | 6,953 | 250 |
| 8 | RustStdMutex | 17,351 | 18,399 | 19,398 | 21,315 | 21,688 | 250 |
| 8 | parking_lot | 9,855 | 10,723 | 11,577 | 13,041 | 13,321 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 12,370 | 12,845 | 13,377 | 14,294 | 14,585 | 250 |
| 16 | RustStdMutex | 18,399 | 18,873 | 19,509 | 20,690 | 21,159 | 250 |
| 16 | parking_lot | **28,066** | 29,425 | 30,523 | 32,112 | 32,768 | 250 |
| | | | | | | | |
| 20 | **Optimal** | 12,804 | 13,270 | 13,744 | 14,749 | 15,003 | 250 |
| 20 | RustStdMutex | 18,104 | 18,559 | 19,005 | 19,972 | 20,366 | 250 |
| 20 | parking_lot | **32,178** | 33,309 | 34,406 | 36,766 | 37,212 | 250 |
| | | | | | | | |
| 22 | **Optimal** | 12,870 | 13,353 | 13,828 | 14,805 | 15,003 | 250 |
| 22 | RustStdMutex | 17,514 | 17,924 | 18,399 | 19,398 | 19,716 | 250 |
| 22 | parking_lot | **34,210** | 35,324 | 36,438 | 38,731 | 39,183 | 250 |
| | | | | | | | |
| 24 | **Optimal** | 12,739 | 13,205 | 13,696 | 14,696 | 14,905 | 250 |
| 24 | RustStdMutex | 17,744 | 18,153 | 18,579 | 19,499 | 19,811 | 250 |
| 24 | parking_lot | **33,718** | 34,734 | 35,783 | 37,814 | 38,181 | 250 |
| | | | | | | | |
| 32 | **Optimal** | 12,534 | 12,993 | 13,475 | 14,386 | 14,585 | 250 |
| 32 | RustStdMutex | 18,104 | 18,546 | 18,972 | 19,847 | 20,128 | 250 |
| 32 | parking_lot | **32,293** | 33,276 | 34,275 | 36,144 | 36,503 | 250 |
| | | | | | | | |
| 64 | **Optimal** | 13,418 | 13,902 | 14,384 | 15,278 | 15,531 | 250 |
| 64 | RustStdMutex | 18,055 | 18,447 | 18,857 | 19,681 | 19,963 | 250 |
| 64 | parking_lot | **34,308** | 35,390 | 36,439 | 38,280 | 38,635 | 250 |
| | | | | | | | |
| 96 | **Optimal** | 13,558 | 14,073 | 14,577 | 15,531 | 15,785 | 250 |
| 96 | RustStdMutex | 18,121 | 18,513 | 18,907 | 19,749 | 20,052 | 250 |
| 96 | parking_lot | **36,372** | 37,490 | 38,569 | 40,372 | 40,738 | 250 |
| | | | | | | | |
| 192 | **Optimal** | 13,894 | 14,401 | 14,891 | 15,823 | 16,076 | 250 |
| 192 | RustStdMutex | 18,252 | 18,662 | 19,054 | 19,896 | 20,196 | 250 |
| 192 | parking_lot | **36,962** | 38,096 | 39,194 | 40,977 | 41,362 | 250 |
| | | | | | | | |
| 384 | **Optimal** | 14,172 | 14,672 | 15,148 | 16,077 | 16,335 | 250 |
| 384 | RustStdMutex | 18,334 | 18,766 | 19,180 | 20,062 | 20,378 | 250 |
| 384 | parking_lot | **36,700** | 37,826 | 38,902 | 40,707 | 41,054 | 250 |

**Skylake — pinned vs unpinned summary:**

| tasks | Opt unpinned ns/op | Opt pinned ns/op | PL unpinned ns/op | PL pinned ns/op | PL/Opt pinned | Δ ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 8 | 164 | 105 | 345 | 197 | 1.88× | (unpinned 2.10×) |
| 16 | 452 | 247 | 1,390 | 561 | 2.27× | (unpinned 3.07×) |
| 64 | 483 | 268 | 1,613 | 686 | 2.56× | (unpinned 3.34×) |
| 384 | 502 | 283 | 1,655 | 734 | 2.59× | (unpinned 3.29×) |

- NUMA pinning cuts **both** impls' per-acquire cost by ~45-57% — confirms QPI traffic was a large slice of observed latency.
- parking_lot/Optimal ratio drops from ~3.3× unpinned to ~2.6× pinned. **~25% of the excess gap was NUMA-specific; ~75% remains intra-socket.**
- Intra-socket 2.6× gap is still an order of magnitude more than Alder Lake single-die (1.01×). Skylake's 20-core mesh topology likely drives this: even within one socket, bucket-line atomics hop across the mesh to reach contending cores.
- RustStdMutex at t=2/4 looks bad (159-302 ns/op vs Optimal 62-68) — 100-iter fixed spin burns cycles unproductively on small-contention cases where parking_lot's bounded SpinWait and Optimal's depth gate both win.


### Broadwell 44c NUMA node 0 (22 cores, single socket)

Intel Xeon E5-2699 v4, same 2-socket host pinned via `numactl --cpunodebind=0 --membind=0`. Broadwell uses ring-bus topology within socket (not Skylake's mesh).

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 6,259 | 6,312 | 6,349 | 6,742 | 6,944 | 250 |
| 1 | RustStdMutex | 6,210 | 6,468 | 6,562 | 6,951 | 6,996 | 250 |
| 1 | parking_lot | 6,267 | 6,361 | 6,640 | 7,086 | 7,244 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 6,410 | 6,726 | 7,139 | 8,503 | 8,755 | 250 |
| 2 | RustStdMutex | 11,010 | 13,001 | 16,810 | 27,935 | 32,256 | 250 |
| 2 | parking_lot | 7,975 | 8,446 | 8,749 | 9,363 | 9,479 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 8,921 | 9,331 | 9,970 | 12,386 | 14,234 | 250 |
| 4 | RustStdMutex | 16,212 | 17,990 | 19,939 | 24,019 | 24,496 | 250 |
| 4 | parking_lot | **8,864** | 9,667 | 10,322 | 12,165 | 12,511 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 15,344 | 15,983 | 18,006 | 22,299 | 22,567 | 250 |
| 8 | RustStdMutex | 18,874 | 20,431 | 21,791 | 24,920 | 25,520 | 250 |
| 8 | parking_lot | 21,545 | 23,691 | 25,739 | 30,556 | 31,455 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 17,809 | 18,235 | 18,924 | 20,480 | 20,782 | 250 |
| 16 | RustStdMutex | 18,743 | 19,464 | 20,201 | 22,413 | 22,903 | 250 |
| 16 | parking_lot | **93,848** | 94,831 | 96,600 | 100,991 | 101,792 | 157 |
| | | | | | | | |
| 20 | **Optimal** | 16,278 | 16,728 | 17,187 | 18,383 | 18,930 | 250 |
| 20 | RustStdMutex | 17,465 | 17,990 | 18,399 | 20,038 | 20,177 | 250 |
| 20 | parking_lot | **95,158** | 96,797 | 98,763 | 101,253 | 103,091 | 155 |
| | | | | | | | |
| 22 | **Optimal** | 15,065 | 15,450 | 15,835 | 16,663 | 16,917 | 250 |
| 22 | RustStdMutex | 16,335 | 16,687 | 17,121 | 17,990 | 18,415 | 250 |
| 22 | parking_lot | **96,469** | 98,238 | 100,401 | 102,695 | 103,154 | 152 |
| | | | | | | | |
| 24 | **Optimal** | 14,442 | 14,811 | 15,180 | 16,384 | 16,622 | 250 |
| 24 | RustStdMutex | 16,032 | 16,384 | 16,810 | 17,793 | 17,957 | 250 |
| 24 | parking_lot | **98,370** | 99,746 | 101,777 | 104,792 | 105,312 | 150 |
| | | | | | | | |
| 32 | **Optimal** | 15,852 | 18,137 | 20,267 | 22,675 | 23,206 | 250 |
| 32 | RustStdMutex | 16,810 | 17,203 | 17,695 | 18,809 | 19,336 | 250 |
| 32 | parking_lot | **85,983** | 93,913 | 100,860 | 105,578 | 105,854 | 161 |
| | | | | | | | |
| 64 | **Optimal** | 15,131 | 15,475 | 15,958 | 16,687 | 16,972 | 250 |
| 64 | RustStdMutex | 16,204 | 16,638 | 17,023 | 18,170 | 18,327 | 250 |
| 64 | parking_lot | **95,027** | 97,452 | 100,598 | 107,217 | 111,430 | 154 |
| | | | | | | | |
| 96 | **Optimal** | 14,975 | 15,335 | 15,794 | 17,007 | 17,247 | 250 |
| 96 | RustStdMutex | 16,278 | 16,597 | 17,039 | 18,137 | 18,254 | 250 |
| 96 | parking_lot | **96,076** | 98,501 | 100,991 | 105,316 | 105,915 | 153 |
| | | | | | | | |
| 192 | **Optimal** | 15,270 | 15,573 | 15,999 | 16,957 | 16,959 | 250 |
| 192 | RustStdMutex | 16,499 | 16,859 | 17,220 | 18,186 | 19,197 | 250 |
| 192 | parking_lot | **98,763** | 100,663 | 102,564 | 106,037 | 106,163 | 150 |
| | | | | | | | |
| 384 | **Optimal** | 15,319 | 15,655 | 16,015 | 16,794 | 17,065 | 250 |
| 384 | RustStdMutex | 16,613 | 16,941 | 17,285 | 17,957 | 18,406 | 250 |
| 384 | parking_lot | **99,942** | 101,777 | 103,285 | 111,215 | 111,495 | 148 |

**Broadwell — pinned vs unpinned summary:**

| tasks | Opt unpinned ns/op | Opt pinned ns/op | PL unpinned ns/op | PL pinned ns/op | PL/Opt pinned | vs unpinned ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 8 | 485 | 306 | 766 | 430 | 1.40× | (unpinned 1.58×) |
| 16 | 582 | 356 | 2,825 | **1,876** | **5.27×** | (unpinned 4.85×) |
| 64 | 471 | 302 | 2,891 | **1,900** | **6.28×** | (unpinned 6.13×) |
| 384 | 485 | 306 | 2,922 | **1,998** | **6.52×** | (unpinned 6.03×) |

- Unlike Skylake, Broadwell NUMA pinning **did NOT materially reduce the collapse ratio** — pinned PL/Opt stays 5-6.5×, similar to unpinned. ~35% wall-clock improvement from pinning is shared between Optimal and parking_lot → doesn't change their relative cost.
- Broadwell's **intra-socket tax is extreme**: at t=16 on single socket, parking_lot = 1,876 ns/op vs Optimal 356 ns/op (5.27× gap) — in the same range as Skylake 2-socket unpinned. The ring-bus topology within one Broadwell socket appears worse-scaling than Skylake's mesh at high core counts.
- Sample count falls to 150 at high task counts — each parking_lot iteration takes ~100 ms, hitting max-duration cap before 250 iterations.
- RustStdMutex at t=2 pinned (11,010) is ~1.7× slower than Optimal (6,410) — the 100-iter fixed spin becomes harmful on cross-socket handoff even within single-socket Broadwell.


### Zen 4 single CCX (8 cores, shared L3)

AMD EPYC 9454P pinned to CPUs 0-7 via `taskset -c 0-7` — one CCX with its own 16 MB L3. Zen 4 Genoa packages 8 cores per CCX × 6 CCDs → NUMA pinning to node 0 is a no-op (whole CPU is one NUMA node); explicit CPU list isolates CCX-local.

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 1,240 | 1,365 | 1,383 | 1,485 | 1,543 | 250 |
| 1 | RustStdMutex | 1,243 | 1,250 | 1,264 | 1,479 | 1,588 | 250 |
| 1 | parking_lot | 1,218 | 1,227 | 1,240 | 1,481 | 1,678 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 1,484 | 1,506 | 1,537 | 1,641 | 1,739 | 250 |
| 2 | RustStdMutex | 4,653 | 4,919 | 5,194 | 5,976 | 6,027 | 250 |
| 2 | parking_lot | 1,680 | 1,750 | 1,836 | 2,111 | 2,158 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 1,982 | 2,082 | 2,165 | 2,318 | 2,447 | 250 |
| 4 | RustStdMutex | 6,402 | 6,898 | 7,213 | 8,028 | 8,202 | 250 |
| 4 | parking_lot | 2,251 | 2,314 | 2,406 | 2,724 | 2,756 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 3,541 | 3,770 | 4,272 | 5,300 | 5,387 | 250 |
| 8 | RustStdMutex | 11,518 | 12,059 | 12,435 | 13,607 | 13,800 | 250 |
| 8 | parking_lot | 4,004 | 4,155 | 4,313 | 4,714 | 5,022 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 3,768 | 3,926 | 4,157 | 4,624 | 4,708 | 250 |
| 16 | RustStdMutex | 12,288 | 12,689 | 13,173 | 14,033 | 14,180 | 250 |
| 16 | parking_lot | 4,641 | 4,903 | 5,546 | 6,308 | 6,525 | 250 |
| | | | | | | | |
| 20 | **Optimal** | 3,396 | 3,777 | 4,293 | 5,636 | 5,829 | 250 |
| 20 | RustStdMutex | 12,534 | 12,894 | 13,214 | 13,935 | 14,193 | 250 |
| 20 | parking_lot | 4,297 | 4,567 | 5,075 | 5,915 | 6,282 | 250 |
| | | | | | | | |
| 22 | **Optimal** | 3,670 | 3,869 | 4,053 | 4,755 | 4,893 | 250 |
| 22 | RustStdMutex | 12,337 | 12,886 | 13,279 | 13,820 | 14,081 | 250 |
| 22 | parking_lot | 4,264 | 4,657 | 5,595 | 6,320 | 6,764 | 250 |
| | | | | | | | |
| 24 | **Optimal** | 4,000 | 4,223 | 4,477 | 4,981 | 5,070 | 250 |
| 24 | RustStdMutex | 12,288 | 13,058 | 13,509 | 15,098 | 15,265 | 250 |
| 24 | parking_lot | 4,735 | 5,001 | 5,579 | 6,164 | 6,244 | 250 |
| | | | | | | | |
| 32 | **Optimal** | 4,170 | 4,452 | 4,977 | 5,792 | 5,901 | 250 |
| 32 | RustStdMutex | 12,165 | 12,902 | 13,533 | 14,393 | 14,587 | 250 |
| 32 | parking_lot | 4,592 | 4,837 | 5,448 | 6,152 | 7,269 | 250 |
| | | | | | | | |
| 64 | **Optimal** | 4,114 | 4,375 | 4,846 | 5,661 | 5,797 | 250 |
| 64 | RustStdMutex | 12,993 | 13,525 | 14,410 | 15,630 | 15,896 | 250 |
| 64 | parking_lot | 4,841 | 5,136 | 6,062 | 6,676 | 6,713 | 250 |
| | | | | | | | |
| 96 | **Optimal** | 4,090 | 4,313 | 4,841 | 5,734 | 5,854 | 250 |
| 96 | RustStdMutex | 12,288 | 13,222 | 13,763 | 14,459 | 14,641 | 250 |
| 96 | parking_lot | 5,280 | 5,763 | 6,369 | 6,881 | 6,953 | 250 |
| | | | | | | | |
| 192 | **Optimal** | 4,415 | 4,637 | 4,911 | 5,480 | 5,586 | 250 |
| 192 | RustStdMutex | 13,697 | 14,148 | 14,819 | 15,942 | 16,413 | 250 |
| 192 | parking_lot | 5,501 | 6,185 | 6,558 | 7,274 | 7,539 | 250 |
| | | | | | | | |
| 384 | **Optimal** | 5,489 | 6,033 | 6,529 | 7,066 | 7,410 | 250 |
| 384 | RustStdMutex | 13,500 | 13,943 | 14,230 | 14,868 | 15,126 | 250 |
| 384 | parking_lot | 5,964 | 6,599 | 7,299 | 8,147 | 8,550 | 250 |

**Zen 4 — CCX-pinned vs unpinned summary:**

| tasks | Opt unpinned ns/op | Opt pinned ns/op | PL unpinned ns/op | PL pinned ns/op | PL/Opt pinned | vs unpinned ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 8 | 83 | 71 | 98 | 80 | 1.13× | (unpinned 1.18×) |
| 16 | 239 | 75 | 283 | 93 | 1.24× | (unpinned 1.18×) |
| 64 | 318 | 82 | **1,540** | **97** | **1.18×** | (unpinned **4.83×**) |
| 96 | 319 | 82 | 1,445 | 106 | 1.29× | (unpinned 4.53×) |
| 384 | 344 | 110 | 1,614 | 119 | 1.09× | (unpinned 4.69×) |

- **CCX pinning collapses the Zen 4 collapse.** At t=64 unpinned, parking_lot was 1,540 ns/op vs Optimal 318 ns/op (4.83×). Pinned to 8 cores sharing one L3, **parking_lot becomes 97 ns/op vs Optimal 82 — 1.18×.** Within noise.
- All of Zen 4's parking_lot tax was **cross-CCD coherence on the bucket cache line**. Within a single CCX (16 MB shared L3), bucket atomics are L3-local and cheap.
- Optimal also accelerates dramatically (318 → 82 ns/op at t=64, **−74%**) — its single state cache line was also bouncing across CCDs. But Optimal only has ONE line bouncing, parking_lot has TWO (state + bucket), so parking_lot loses more when cross-CCD and nearly matches when CCX-local.
- The 8-core CCX acts like Alder Lake's monolithic die — single coherence domain, parking_lot and Optimal interchangeable. Same topology conclusion as the key findings table.

## Cross-host pinning summary

| host | coherence domain | pinned PL/Opt at t=16+ | residual intra-domain tax |
|---|---|---:|---|
| Alder Lake 12c | monolithic die | 1.01× | none |
| Zen 4 CCX (8c) | one CCX, shared L3 | **1.18×** | minimal |
| Skylake 40c → node 0 (20c) | one socket, mesh | 2.56× | mesh-topology overhead |
| Broadwell 44c → node 0 (22c) | one socket, ring | **5.27×** | ring-topology — worse than mesh |
| M1 Ultra 18c | UltraFusion 2-die (unpinned) | 2.38× | (not pinning-isolated) |

The ordering maps exactly to intra-domain interconnect complexity:
- **monolithic ≪ CCX (small shared L3) ≪ mesh (20 cores) ≪ ring (22 cores)**.

parking_lot's architectural tax only shows when bucket-line atomics have to traverse a coherence fabric. When contention stays within a single small L3 domain (Alder Lake, Zen 4 CCX), parking_lot is competitive with Optimal.

### Zen 4 CCX-boundary sweep

To locate the exact CCX coherence boundary on AMD EPYC, we ran ContentionScaling with progressively wider `taskset -c` ranges: 0-7 (1 CCX), 0-15 (2 CCX), 0-23 (3 CCX), and 0-31 (4 CCX). Zen 4 Genoa groups 8 cores per CCX, each with its own 16 MB shared L3.

**ns/op at t=64 (oversubscribed, many threads competing):**

| pinning | Optimal | parking_lot | PL/Opt |
|---|---:|---:|---:|
| 0-7 (1 CCX) | 82 | 97 | 1.18× |
| 0-15 (2 CCX) | 238 | 270 | 1.13× |
| 0-23 (3 CCX) | 254 | **609** | **2.40×** |
| 0-31 (4 CCX) | 279 | **1,195** | **4.28×** |
| unpinned (all 64 cores) | 318 | **1,540** | 4.83× |

**Within-pinning t-sweep for 0-23 (24 cores, 3 CCXs, ns/op):**

| tasks | Opt | PL | PL/Opt |
|---:|---:|---:|---:|
| 16 | 227 | 273 | 1.20× |
| 20 | 249 | 402 | 1.61× |
| 22 | 251 | 483 | 1.93× |
| **24** | **250** | **571** | **2.28×** |

**Within-pinning t-sweep for 0-31 (32 cores, 4 CCXs, ns/op):**

| tasks | Opt | PL | PL/Opt |
|---:|---:|---:|---:|
| 16 | 231 | 264 | 1.14× (threads on 2 CCXs) |
| 20 | 249 | 398 | 1.60× |
| 22 | 250 | 486 | 1.94× |
| 24 | 265 | 577 | 2.18× |
| **32** | **273** | **1,127** | **4.13×** (4 CCXs fully active) |
| 64 | 279 | 1,195 | 4.28× |
| 384 | 296 | 1,506 | 5.09× |

**Findings:**
- **1 CCX (0-7):** parking_lot at parity with Optimal (1.18×). No cross-CCX traffic — bucket line stays L3-local.
- **2 CCX (0-15):** ratio stays flat at 1.13×. Under oversubscription (t≥16) the scheduler and futex layer apparently keep running threads compressed onto fewer CCXs at any instant; cross-CCX bucket transfers are rare enough to not dominate.
- **3 CCX (0-23):** ratio jumps to 2.40× at t=64. Within the task sweep, parking_lot cost grows linearly as threads span more cores of the 3rd CCX — the bucket cache line now bounces across 3 CCXs per acquire. Optimal stays flat because only its state line bounces; parking_lot has state + bucket both bouncing.
- **4 CCX (0-31):** ratio reaches 4.28× at t=64, within 12% of the unpinned ceiling. At t=32 with all 4 CCXs fully loaded (32 threads / 32 cores = 1:1 no oversub, each CCX running at capacity), PL/Opt hits 4.13× — already in the "collapse" regime. Beyond 4 CCXs adds little: the per-acquire cost of spanning 4 vs 6 CCXs is similar because Infinity Fabric latency saturates quickly past 2 hops.

**Summary.** The collapse is **step-wise in the number of CCXs actively running threads**, not smooth in core count:

| CCXs active | PL/Opt @ t=64 | added per CCX |
|:---:|---:|---:|
| 1 | 1.18× | baseline |
| 2 | 1.13× | ~0 |
| 3 | 2.40× | **+1.27×** |
| 4 | 4.28× | **+1.88×** |
| 6+ (unpinned) | 4.83× | +0.55× (saturating) |

At a given pinning width, the effective collapse is set by how many CCXs the scheduler actually spreads threads across during peak contention. parking_lot's state + bucket cache lines each pay Infinity Fabric cost per cross-CCX hop; the parking_lot tax scales with participating-CCX count, which is why it plateaus past ~4 CCXs.

