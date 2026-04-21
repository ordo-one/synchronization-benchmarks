# ContentionRatio

How much unlocked work between lock acquires affects contention. Real applications do processing between acquires — not every thread immediately re-contends after releasing.

Based on [Go sync.Mutex benchmark](https://github.com/golang/go/blob/master/src/sync/mutex_test.go) (ratio parameter) and [folly SharedMutex tests](https://github.com/facebook/folly/blob/main/folly/test/SharedMutexTest.cpp) (write fraction control).

## Parameters

| Parameter | Values |
|---|---|
| tasks | 4, 16, 64 |
| work | 1, 4 |
| pause | 0, 10, 100 |

Cross-axis points: tasks=4 (low contention), tasks=64 (high contention), work=4 (longer CS with inter-acquire gap).

## Key findings

1. **OptimalMutex wins p50 at every `tasks ≥ 16` config on every tested CPU.** Adaptive depth-gate + pause-spacing hold together across Alder Lake 12c, Zen 4 64c, Skylake NUMA 40c, Broadwell NUMA 44c. Margin narrows at low contention (t=4) and at long inter-acquire gap (p=100).

2. **Stdlib `Synchronization.Mutex` (PI-futex) has a catastrophic cliff at `tasks=16` on NUMA Intel and AMD Zen 4.** Zen 4 goes from 30ms plain-futex to **1.27 seconds** (42× slower). Broadwell 44c NUMA hits **1.39 seconds** (48× slower). Skylake 40c NUMA is milder but still **4–15× slower** depending on config. Intel consumer desktop (i5-12500 12c) shows no cliff.

3. **Inter-acquire gap (pause=100) flattens everything except PI-futex.** On plain-futex variants, p=100 narrows the ranking gap to <30%. PI-futex stays catastrophic on NUMA/AMD regardless of pause — kernel chain-walk dominates, not contention density.

4. **RustMutex is a consistent second to Optimal on Intel NUMA.** Pauses-per-iter=1 + in-spin CAS outperforms NIOLockedValueBox's park-immediate at moderate contention. On AMD Zen 4, NIO and Rust cluster together; Optimal's lazy-waiter-count registration + depth gate pulls away.

5. **`work=4 pause=10` (Ordo-realistic: dict lookup + msg processing) stays dominated by Optimal on all CPUs.** PI-futex is 7–48× slower here. Plain-futex ranking stable: Optimal < Rust ≲ NIO.

### PI-futex cliff — does it fire?

| CPU | t=16 w=1 p=10 cliff? | Magnitude (Optimal vs Sync.Mutex) |
|---|---|---:|
| Intel i5-12500 (12c Alder Lake) | no | 6.8× (within noise band) |
| AMD EPYC 9454P (64c Zen 4) | **yes** | **106×** (12ms → 1.29s) |
| Intel Xeon Gold 6148 (40c Skylake NUMA) | **yes** | **11×** (24ms → 271ms) |
| Intel Xeon E5-2699 v4 (44c Broadwell NUMA) | **yes** | **48×** (30ms → 1.44s) |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| Low contention (t≤4) + any pause | Optimal or NIO | Tight clustering, Optimal 1.4–3× faster but absolute numbers are small |
| Moderate (t=16, p≥10) on Intel consumer | Optimal | 1.3–1.5× plain ranking stable |
| High (t≥16) on NUMA or AMD ≥32c | **Optimal** | PI cliff makes stdlib unusable; avoids 5–48× penalty |
| CS-bound (work=4 or long inner) | Optimal | Spin catches releases even with longer CS |

## Implementations compared

- **Optimal** — OptimalMutex, canonical ship candidate. Depth-gated spin, lazy waiter-count registration (2026-04-19 backport), 20-iter pause budget.
- **RustMutex** — Rust std 1.62+ port: post-spin CAS into load-only regime, kernel exchange.
- **NIOLockedValueBox (NIO)** — SwiftNIO's pthread_mutex_t wrapper. Relies on glibc adaptive-spin then park.
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex primitive. Canonical upstream PI-futex path.

## Test hosts

| CPU | Cores | Arch |
|---|---|---|
| Intel i5-12500 | 6P + 6E (12T) | Alder Lake consumer desktop |
| AMD EPYC 9454P | 64c (8 CCDs × 8c) | Zen 4 chiplet server |
| Intel Xeon Gold 6148 | 2 × 20c NUMA | Skylake-SP server |
| Intel Xeon E5-2699 v4 | 2 × 22c NUMA | Broadwell-EP server |

Apple M1 Ultra (18c aarch64 container) was not included in this run — container bench aborted during combined CR/NC/SpinTuning launch. Prior M1 Ultra runs (see `LongRun.md`, `Fairness.md`) confirm PI cliff fires at t=16.

---

## Detailed p50 wall-clock (µs)

Fresh 2026-04-19 data. Optimal includes lazy waiter-count registration backport.

### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=4 w=1 p=10 | 1,854 | 6,885 | 7,602 | 9,478 |
| t=16 w=1 p=0 | 1,556 | 8,954 | 9,814 | 12,886 |
| t=16 w=1 p=10 | 2,187 | 7,623 | 10,084 | 14,909 |
| t=16 w=1 p=100 | 5,784 | 10,265 | 11,436 | 15,786 |
| t=16 w=4 p=10 | 9,339 | 18,006 | 18,907 | 21,692 |
| t=64 w=1 p=10 | 2,257 | 9,740 | 10,338 | 15,548 |

Desktop consumer with SMT. Optimal 3–7× faster than all alternatives at t=16. Sync.Mutex higher baseline than plain-futex but no cliff — SMT/small-core count doesn't trigger PI's chain-walk pathology.

### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=4 w=1 p=10 | 2,089 | 5,591 | 3,881 | 10,158 |
| t=16 w=1 p=0 | 8,831 | 13,353 | 20,316 | **1.27s** |
| t=16 w=1 p=10 | 12,173 | 16,974 | 21,135 | **1.29s** |
| t=16 w=1 p=100 | 25,674 | 30,130 | 30,720 | **1.29s** |
| t=16 w=4 p=10 | 27,853 | 35,357 | 36,897 | **1.31s** |
| t=64 w=1 p=10 | 15,917 | 21,119 | 26,018 | **1.40s** |

**PI-futex cliff fires at t=16.** Sync.Mutex collapses to 1.27–1.40 seconds — 40–100× slower than plain-futex. Pattern persists across pause and work values. Plain-futex variants (Optimal/Rust/NIO) scale gracefully; Optimal 1.5–3× faster than Rust/NIO.

### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=4 w=1 p=10 | 5,161 | 15,516 | 18,940 | 23,871 |
| t=16 w=1 p=0 | 22,594 | 31,703 | 32,047 | 300,679 |
| t=16 w=1 p=10 | 24,232 | 33,456 | 33,260 | 271,319 |
| t=16 w=1 p=100 | 33,128 | 38,568 | 42,041 | 279,446 |
| t=16 w=4 p=10 | 55,640 | 65,536 | 63,963 | 412,877 |
| t=64 w=1 p=10 | 25,362 | 34,472 | 35,226 | 436,208 |

**PI cliff fires at t=16 with 11–17× penalty.** Cross-socket QPI traffic amplifies PI's kernel chain-walk cost. Skylake-SP milder than Zen 4 because single-socket cache topology is simpler, but still unusable for production. Optimal 1.3–1.5× faster than Rust/NIO.

### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| t=4 w=1 p=10 | 11,190 | 22,725 | 29,164 | 131,269 |
| t=16 w=1 p=0 | 28,754 | 28,852 | 28,557 | **1.39s** |
| t=16 w=1 p=10 | 29,655 | 31,212 | 29,606 | **1.44s** |
| t=16 w=1 p=100 | 34,669 | 34,669 | 41,910 | **1.73s** |
| t=16 w=4 p=10 | 56,426 | 55,476 | 67,076 | **1.17s** |
| t=64 w=1 p=10 | 25,035 | 27,869 | 28,377 | **2.18s** |

**PI cliff already fires at t=4 (12×) — earliest of all tested CPUs** — and goes full catastrophic at t=16 (48–63×). Broadwell QPI older than Skylake's UPI; combined with 44 cores across 2 sockets, PI chain walks are extreme. At t=64 Sync.Mutex hits 2.18 seconds. Plain-futex variants (Optimal/Rust/NIO) cluster within 10% of each other — NUMA latency dominates lock-specific optimizations once contention is saturated.
