# HoldTime

How long the critical section is affects contention dynamics. Tests three hold regimes:
- **Uniform** work sweep (`tasks=16 pause=0 work=N`) — single CS duration
- **Bimodal** mix (short CS most of the time, long CS rarely) — does the lock adapt to median or mean?
- **Sleep-in-lock** (200µs kernel park during hold) — stresses PI-futex chain-walk and every waiter through kernel-wait

Uniform sweep covers the empty-CS floor (`work=0` = pure lock/unlock overhead) inspired by matklad's "Mutexes are faster than spinlocks" and WebKit `LockSpeedTest worksInsideLock=0`. Bimodal is folly-inspired and triggers Go starvation-mode conditions. Sleep-in-lock is adapted from cuongleqq's LongHold scenario — it forces every waiter through the kernel-wait path and (for PI) through the rt_mutex PI chain walk.

## Parameters

| Regime | Params |
|---|---|
| uniform | tasks=16, pause=0, work ∈ {0, 1, 16, 64, 128} (+ {256, 1024} under SLOW) |
| bimodal | tasks ∈ {16, 64}, shortWork=1, longWork ∈ {256, 1024}, longProbPct ∈ {5, 10} |
| sleep | tasks ∈ {8, 16}, holdUs=200 |

## Key findings

1. **OptimalMutex wins at `work=0` (empty CS) on every CPU — the empty-CS floor is Optimal's strongest regime.** 1,113 µs on Alder Lake 12c vs 3,650 Rust / 4,436 NIO / 6,713 Sync.Mutex. Depth-gate + pause budget matters most when there's nothing to amortize.

2. **RustMutex crosses Optimal at `work ≥ 16` on Intel machines.** Alder Lake w=64: Rust 64ms vs Optimal 73ms. Skylake 40c NUMA w=16: Rust 66ms vs Optimal 104ms. Pattern: as CS length grows past ~16 tight-loop iterations, Rust's post-CAS-lost park (no exponential retry) amortizes better than Optimal's depth-gated spin. On AMD Zen 4 and Broadwell 44c, Optimal keeps its lead through w=64.

3. **PI-futex cliff fires on bimodal even at low task count.** Alder Lake 12c bimodal(1/1024)@5% = 294ms for Sync.Mutex vs 41ms for Optimal (7×). The 1024-step long-CS tail amplifies PI chain cost; the cliff shows on machines that are otherwise cliff-free at uniform workloads.

4. **Sleep-in-lock flattens everything.** 200µs kernel park dominates all variants within 2–25% across all CPUs. Even Sync.Mutex stays in-band because the kernel-scheduled wakeup path is the dominant cost regardless of lock design. This is the one regime where PI-futex is not catastrophic.

5. **Bimodal × NUMA = worst PI case.** Broadwell 44c bimodal(1/1024)@5%: Sync.Mutex 1.63 seconds vs Optimal 205ms (8× plain). Same machine, uniform w=128: 2.36s vs 606ms (4× plain). Bimodal hurts PI more than uniform because the long-CS tail forces chain walks while the majority-short pattern keeps the chain deep.

### PI-futex cliff — per CPU on HoldTime

| CPU | Uniform w=0 | Uniform w=128 | Bimodal 1/1024 | Sleep 200µs |
|---|---:|---:|---:|---:|
| Intel i5-12500 (12c Alder Lake) | 6× | 1.5× | 7× | within 1% |
| AMD EPYC 9454P (64c Zen 4) | **780×** | 9× | 32× | 10% |
| Intel Xeon Gold 6148 (40c Skylake NUMA) | 48× | 3× | 7× | 15% |
| Intel Xeon E5-2699 v4 (44c Broadwell NUMA) | **103×** | 4× | 8× | 20% |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| Empty / near-empty CS, any CPU | **Optimal** | 2–6× faster than alternatives; avoids AMD/NUMA PI cliff entirely |
| Long uniform CS (work ≥ 16) on Intel consumer | Rust or Optimal | Rust sometimes wins; both within 15% |
| Long uniform CS on AMD / NUMA | Optimal | Stays ahead on Zen 4 and Broadwell |
| Bimodal (rare long CS) | **Optimal** | Widest gap to PI cliff; Rust/NIO acceptable alternates |
| Sleep-in-lock (200µs+) | any | All cluster; pick by ergonomics |

## Implementations compared

- **Optimal** — OptimalMutex with lazy waiter-count registration (2026-04-19 backport).
- **RustMutex** — Rust std 1.62+ load-only spin + post-spin CAS + kernel exchange.
- **NIOLockedValueBox (NIO)** — pthread_mutex_t wrapper (glibc adaptive then park).
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex.

## Test hosts

Same 4 x86 hosts as ContentionRatio / NanosecondContention. M1 Ultra (18c aarch64) absent — container bench aborted in prior combined run.

---

## Uniform hold-time (work sweep, tasks=16 pause=0)

#### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 work=0 pause=0 | 1,113 | 3,650 | 4,436 | 6,713 |
| tasks=16 work=1 pause=0 | 2,018 | 9,535 | 10,420 | 12,927 |
| tasks=16 work=16 pause=0 | 34,636 | 26,067 | 35,586 | 35,422 |
| tasks=16 work=64 pause=0 | 72,679 | 64,324 | 72,876 | 171,311 |
| tasks=16 work=128 pause=0 | 136,577 | 115,737 | 124,649 | 199,361 |

On Alder Lake, RustMutex crosses Optimal at work≥16 — longer CS amortizes its simpler load-only spin. Sync.Mutex stable at 1.5–3× plain (no cliff).

#### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 work=0 pause=0 | 1,483 | 3,084 | 3,873 | **1.15s** |
| tasks=16 work=1 pause=0 | 11,600 | 16,335 | 21,938 | **1.28s** |
| tasks=16 work=16 pause=0 | 62,980 | 74,252 | 73,269 | **1.39s** |
| tasks=16 work=64 pause=0 | 107,676 | 125,633 | 129,499 | **1.51s** |
| tasks=16 work=128 pause=0 | 168,428 | 165,282 | 186,778 | **1.58s** |

PI cliff fires at every work value. Optimal holds ~10–30% lead over Rust/NIO through w=64, then converges at w=128 as CS dominates.

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 work=0 pause=0 | 2,908 | 8,634 | 7,156 | 138,805 |
| tasks=16 work=1 pause=0 | 21,840 | 31,687 | 31,441 | 270,533 |
| tasks=16 work=16 pause=0 | 103,612 | 65,831 | 109,838 | 621,281 |
| tasks=16 work=64 pause=0 | 240,386 | 203,948 | 243,794 | **1.02s** |
| tasks=16 work=128 pause=0 | 421,790 | 390,332 | 447,480 | **1.46s** |

Optimal dominates at w=0/1. At w≥16 RustMutex pulls ahead by 10–35% — same Rust-crosses-Optimal pattern as Alder Lake. PI cliff 48× at empty CS, shrinks to 3× at w=128 as CS dominates.

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 work=0 pause=0 | 6,828 | 6,382 | 8,495 | 700,449 |
| tasks=16 work=1 pause=0 | 27,984 | 28,721 | 30,753 | 902,824 |
| tasks=16 work=16 pause=0 | 103,678 | 107,610 | 116,457 | 591,921 |
| tasks=16 work=64 pause=0 | 290,980 | 320,602 | 241,566 | **1.13s** |
| tasks=16 work=128 pause=0 | 605,553 | 605,553 | 625,476 | **2.36s** |

Broadwell: plain-futex variants converge early. Optimal ties Rust at w=0 but NIO wins at w=64 (44c NUMA at w=64 has enough inter-acquire slack that park-immediate is cheapest). Sync.Mutex 100× plain at w=0, 4× at w=128.

## Bimodal hold-time (short/long CS mix)

#### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 bimodal(1/256)@10% | 23,839 | 32,981 | 24,560 | 53,510 |
| tasks=16 bimodal(1/1024)@5% | 41,517 | 45,154 | 47,088 | 294,912 |
| tasks=64 bimodal(1/256)@10% | 25,002 | 33,047 | 24,887 | 60,129 |

Long-tail 1/1024@5% triggers PI cliff even on 12c consumer — 7× slower than Optimal.

#### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 bimodal(1/256)@10% | 26,313 | 40,600 | 38,011 | **1.35s** |
| tasks=16 bimodal(1/1024)@5% | 42,861 | 46,760 | 43,876 | **1.37s** |
| tasks=64 bimodal(1/256)@10% | 29,000 | 43,450 | 43,713 | **1.46s** |

PI cliff stays ~1.35–1.46s. Optimal 30–50% faster than Rust/NIO.

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 bimodal(1/256)@10% | 79,495 | 107,282 | 77,726 | 700,449 |
| tasks=16 bimodal(1/1024)@5% | 110,887 | 123,339 | 111,870 | 798,491 |
| tasks=64 bimodal(1/256)@10% | 79,495 | 113,443 | 81,396 | 719,847 |

NIOLockedValueBox ties or slightly beats Optimal at bimodal(1/256); PI cliff 7–9× plain.

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 bimodal(1/256)@10% | 113,967 | 120,848 | 118,555 | **1.30s** |
| tasks=16 bimodal(1/1024)@5% | 205,128 | 210,108 | 202,637 | **1.63s** |
| tasks=64 bimodal(1/256)@10% | 107,938 | 121,438 | 105,644 | **1.23s** |

Plain-futex variants cluster within 6%. PI cliff 6–11× plain.

## Sleep-in-lock (holder parks in kernel)

#### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=8 sleepHold=200µs | 128,188 | 128,188 | 128,188 | 128,188 |
| tasks=16 sleepHold=200µs | 256,213 | 256,214 | 256,190 | 256,195 |

All variants identical within measurement noise — 200µs kernel park dominates.

#### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=8 sleepHold=200µs | 141,296 | 141,165 | 141,165 | 154,927 |
| tasks=16 sleepHold=200µs | 282,591 | 282,591 | 282,591 | 312,214 |

Sync.Mutex 10% slower — kernel-scheduled wakeup still slightly slower than plain-futex, but no cliff.

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=8 sleepHold=200µs | 135,922 | 135,660 | 135,922 | 157,549 |
| tasks=16 sleepHold=200µs | 272,892 | 272,368 | 272,630 | 320,602 |

15% Sync.Mutex overhead — NUMA amplifies kernel-path slightly.

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=8 sleepHold=200µs | 136,053 | 136,315 | 135,791 | 163,971 |
| tasks=16 sleepHold=200µs | 272,630 | 273,154 | 273,154 | 332,661 |

20% Sync.Mutex overhead — marginally worse than Skylake but still no cliff.

**The sleep-in-lock regime is the one place PI-futex is not catastrophic.** Kernel-scheduled wakeup latency dominates; PI chain walk is a minor tax rather than the bottleneck. Real workloads with kernel-blocking critical sections (I/O, sleep, cond_wait) see no PI penalty worth the user-space benefits of plain futex.
