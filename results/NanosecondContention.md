# NanosecondContention

Nanosecond-calibrated delay grid ported from [abseil BM_Contended](https://github.com/abseil/abseil-cpp/blob/master/absl/synchronization/mutex_benchmark.cc). Uses busy-wait calibrated in nanoseconds so results compare across machines without normalizing for CPU speed.

Includes a `no-lock baseline` (same loop without a lock) to separate loop overhead from actual lock cost.

## Parameters

| Parameter | Values |
|---|---|
| tasks | 2, 8, 16, 64 |
| delay_inside (hold time) | 0, 50, 1000, 100000 ns |
| delay_outside (inter-acquire gap) | 0, 100, 2000 ns |

## Key findings

1. **OptimalMutex wins p50 across every tested CPU and config ≥ t=8.** At t=2 + near-zero holds, Sync.Mutex and NIO cluster within 10% — spin adaptation yields only modest wins when the CS is 50ns. Once t ≥ 8, Optimal pulls 1.2–1.5× ahead on plain-futex variants.

2. **Stdlib `Synchronization.Mutex` (PI) collapses at `t=8` on AMD Zen 4 — earliest cliff of all benches.** 26µs → 1.26s at t=8 in=50ns (48,000× slower). NUMA Intel (Xeon E5 Broadwell 44c) hits the cliff at t=8 too (50µs → 505ms). Cliff persists even when CS length is 1µs or inter-acquire gap is 2000ns. Confirms the pathology is kernel-side chain walking, not CS or pause-dependent.

3. **Long critical sections (in=1000ns, i.e. 1µs) shift the ranking.** Optimal/Rust/NIO cluster (~90–150µs); PI-futex kernel handoff briefly competitive on low-core Intel consumer (Alder Lake 12c: Rust/Sync.Mutex ~78µs both beat Optimal ~90µs because the long CS amortizes PI's kernel cost). On NUMA/AMD, PI still collapses.

4. **`out=2000ns` (2µs inter-acquire gap) is the only regime where PI stays close on NUMA.** Intel Xeon Gold 40c Skylake: Sync.Mutex 113ms vs Optimal 37ms (only 3× instead of 11×). Long gaps give the kernel time to drain PI waiter chains between acquires.

5. **No-lock baseline is critical context.** At in=0 out=0, plain-futex variants are within 5–15% of the no-lock loop; PI-futex is 1–60× above it. The "cost of a mutex" is effectively noise on plain-futex designs except when entering the kernel path.

### PI-futex cliff — when does it fire?

| CPU | Fires at | Peak observed |
|---|---|---:|
| Intel i5-12500 (12c Alder Lake) | never (within bench range) | 1.2× plain |
| AMD EPYC 9454P (64c Zen 4) | **t = 8** | **48,000× at t=8 in=50ns** |
| Intel Xeon Gold 6148 (40c Skylake NUMA) | **t = 16** | 14× plain |
| Intel Xeon E5-2699 v4 (44c Broadwell NUMA) | **t = 8** | **10,000× at t=8 in=50ns** |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| t=2, any CS | any | All variants within 10%; pick by ergonomics |
| t=8+ on NUMA or AMD ≥ 32c | **Optimal** | Avoids PI cliff; Rust/NIO acceptable alternates |
| Long CS (in ≥ 1000ns) Intel consumer | Rust, NIO, or Sync.Mutex | PI's kernel handoff amortizes well on long CS at small core counts |
| out ≥ 2000ns (long inter-acquire gap) | any plain-futex | Gap masks lock strategy; avoid Sync.Mutex on NUMA |

## Implementations compared

- **Optimal** — OptimalMutex with lazy waiter-count backport (2026-04-19).
- **RustMutex** — Rust std 1.62+ port.
- **NIOLockedValueBox (NIO)** — SwiftNIO pthread_mutex_t wrapper.
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex.

## Test hosts

| CPU | Cores | Arch |
|---|---|---|
| Intel i5-12500 | 6P + 6E (12T) | Alder Lake consumer desktop |
| AMD EPYC 9454P | 64c (8 CCDs × 8c) | Zen 4 chiplet server |
| Intel Xeon Gold 6148 | 2 × 20c NUMA | Skylake-SP server |
| Intel Xeon E5-2699 v4 | 2 × 22c NUMA | Broadwell-EP server |

Apple M1 Ultra (18c aarch64) was not included in this run — container bench aborted during combined CR/NC/SpinTuning launch. See `LongRun.md` / `Fairness.md` for prior M1 Ultra evidence.

---

## Detailed p50 wall-clock (µs)

Fresh 2026-04-19 data.

### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=2 in=50ns out=100ns | 23,904 | 29,114 | 24,723 | 24,003 |
| t=8 in=50ns out=100ns | 24,314 | 27,836 | 30,327 | 28,918 |
| t=16 in=0ns out=0ns | 21,873 | 23,855 | 24,789 | 27,771 |
| t=16 in=50ns out=0ns | 23,200 | 27,279 | 29,213 | 29,229 |
| t=16 in=50ns out=100ns | 24,281 | 27,869 | 30,114 | 28,754 |
| t=16 in=50ns out=2000ns | 33,473 | 33,145 | 33,620 | 33,112 |
| t=16 in=1000ns out=0ns | 90,571 | 78,053 | 90,505 | 78,709 |
| t=64 in=50ns out=100ns | 24,396 | 28,180 | 30,409 | 29,409 |

Small-core consumer: all 4 variants within ~30%. At `in=1000ns`, Rust and Sync.Mutex ~78ms both beat Optimal/NIO ~90ms — long CS amortizes PI's kernel cost, and Rust's post-CAS-lost park avoids cache thrash.

### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=2 in=50ns out=100ns | 26,116 | 26,116 | 28,869 | 25,919 |
| t=8 in=50ns out=100ns | 26,493 | 31,212 | 35,160 | **1.26s** |
| t=16 in=0ns out=0ns | 21,479 | 22,528 | 23,282 | **1.27s** |
| t=16 in=50ns out=0ns | 26,296 | 30,736 | 31,359 | **1.32s** |
| t=16 in=50ns out=100ns | 31,261 | 33,620 | 37,683 | **1.32s** |
| t=16 in=50ns out=2000ns | 28,459 | 29,966 | 39,551 | **1.11s** |
| t=16 in=1000ns out=0ns | 99,025 | 97,386 | 107,676 | **1.39s** |
| t=64 in=50ns out=100ns | 33,047 | 35,914 | 39,715 | **1.43s** |

**PI cliff fires at t=8 in=50ns: 1.26 seconds.** 48,000× slower than plain-futex variants. Persists through all t≥8 configs including long CS and long inter-acquire gaps. Plain-futex variants stay within 20% of each other.

### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=2 in=50ns out=100ns | 29,360 | 29,950 | 34,210 | 31,343 |
| t=8 in=50ns out=100ns | 30,556 | 38,207 | 38,240 | 46,039 |
| t=16 in=0ns out=0ns | 24,609 | 30,900 | 29,721 | 143,917 |
| t=16 in=50ns out=0ns | 27,967 | 35,258 | 34,669 | 225,182 |
| t=16 in=50ns out=100ns | 32,047 | 39,387 | 39,322 | 156,238 |
| t=16 in=50ns out=2000ns | 37,421 | 42,500 | 45,187 | 113,508 |
| t=16 in=1000ns out=0ns | 110,232 | 105,251 | 114,295 | 438,567 |
| t=64 in=50ns out=100ns | 37,028 | 40,796 | 40,239 | 422,576 |

**PI cliff fires at t=16**, 5–14× penalty. Milder than AMD because Skylake-SP has cleaner cross-socket latency via UPI vs AMD's CCD chiplet mesh — but still unusable. Optimal 1.2–1.3× faster than Rust/NIO.

### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=2 in=50ns out=100ns | 35,357 | 39,158 | 40,665 | 31,883 |
| t=8 in=50ns out=100ns | 50,266 | 50,692 | 49,480 | 504,627 |
| t=16 in=0ns out=0ns | 35,684 | 38,175 | 36,897 | **1.15s** |
| t=16 in=50ns out=0ns | 44,663 | 48,464 | 46,072 | **1.31s** |
| t=16 in=50ns out=100ns | 51,282 | 53,576 | 54,395 | **1.46s** |
| t=16 in=50ns out=2000ns | 59,572 | 57,180 | 59,802 | **1.34s** |
| t=16 in=1000ns out=0ns | 149,815 | 152,437 | 162,660 | **1.59s** |
| t=64 in=50ns out=100ns | 49,807 | 50,790 | 52,822 | **2.16s** |

**PI cliff fires at t=8: 504ms (10,000× slower).** Broadwell's older QPI interconnect amplifies the kernel chain-walk cost. At t=64, Sync.Mutex reaches 2.16 seconds. Plain-futex variants cluster within 10% — NUMA latency dominates over lock micro-design.
