# SkewedProducer

Non-uniform lock access: one "hot" thread holds the lock almost continuously; cold threads tap in occasionally with `coldgap` µs between touches. Realistic for workloads with a single producer + many consumers, or a hot metric counter with cold monitoring taps.

Runs inside Asymmetric bench. Filter: `./run-remote.sh --target Asymmetric --filter '.*skewed.*'`.

## Parameters

| Config | Skew shape |
|---|---|
| tasks=16 coldgap=2µs | ~80-20 (cold threads contend every 2µs) |
| tasks=16 coldgap=10µs | ~95-5 |
| tasks=64 coldgap=10µs | ~97-3 at scale |

Duration: 300ms per iteration. `coldgap` = µs between cold threads' attempts.

Measures two separate histograms per iteration:
- **hot-wait** — latency experienced by the hot producer (rare contention)
- **cold-wait** — latency for cold threads (the fairness signal)

Cold-wait tail is the metric: how long do cold threads wait when the hot thread hogs the lock?

## Key findings

1. **AMD Zen 4 PI cliff FLIPS on skewed.** Every other bench tested this session shows Sync.Mutex catastrophic on AMD at t ≥ 8 (1000-48,000× slower than plain-futex). On skewed, Sync.Mutex **wins** cold-wait p99 (1.3µs vs Optimal 9.1µs). The hot-thread monopoly keeps PI chain short, so chain-walk pathology doesn't fire. First AMD workload this session where PI is the right pick.

2. **Broadwell 44c NUMA is the exception — PI cliff fires worse.** tasks=16 coldgap=2µs Sync.Mutex cold-wait p50 = 148µs (plain: 580ns). tasks=64 coldgap=10µs Sync.Mutex cold-wait p50 = **1.97ms**, p99 = **2.41ms**. Older QPI + skew = worst PI tail seen this session. Skew doesn't save Broadwell.

3. **RustMutex wins cold-wait p99 on Intel Alder Lake + Zen 4.** Rust's load-only spin handles hot-thread monopoly better than Optimal's in-spin CAS. Alder Lake t=16 coldgap=2µs: Rust p99=183ns vs Optimal 397ns (2× better).

4. **Optimal wins NUMA skewed.** Broadwell 44c t=16 cold-wait p99: Optimal 17.3µs < NIO 25.6µs < Rust 26.6µs < Sync **616µs**. Depth-gate keeps cold threads out of CAS storm while hot thread holds.

5. **Skew exposes the "in-spin CAS vs load-only spin" trade-off.** When a hot holder dominates, in-spin CAS (Optimal) creates RFO storm as cold threads thrash the cache line. Load-only spin (Rust) and park-immediate (PI, NIO) avoid the thrash. Optimal's generic-case advantage inverts for this narrow regime.

### PI-futex cliff — per CPU on skewed

| CPU | t=16 gap=2µs | t=16 gap=10µs | t=64 gap=10µs |
|---|---|---|---|
| Intel Alder Lake 12c | **PI wins** (p99 365ns) | **PI wins** (p99 331ns) | **PI wins** (p99 423ns) |
| AMD EPYC Zen 4 64c | **PI wins** (p99 1.3µs) | **PI wins** (p99 1.3µs) | **PI wins** (p99 3.2µs) |
| Intel Xeon Gold Skylake NUMA | PI ties Rust (p99 15µs) | PI ties Rust (p99 14.8µs) | PI loses (p99 42µs) |
| Intel Xeon E5 Broadwell NUMA | **PI catastrophic** (p99 616µs) | **PI catastrophic** (p99 216µs) | **PI catastrophic** (p99 2.41ms) |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| Skewed + small cores / Intel consumer | Sync.Mutex or RustMutex | PI and Rust both win cold-wait tail |
| Skewed on AMD Zen 4 | Sync.Mutex | First AMD regime where PI wins |
| Skewed on Broadwell NUMA | **Optimal** | Only variant avoiding 100–1000× PI cliff |
| Skewed on Skylake NUMA | Rust or Sync | Tight cluster; Optimal slightly worse |
| Mixed workload (skewed + uniform phases) | **Optimal** | Generic default; skewed regime narrow |

## Implementations

- **Optimal** — OptimalMutex with lazy waiter-count backport.
- **RustMutex** — Rust std 1.62+ load-only spin + post-CAS park.
- **NIOLockedValueBox (NIO)** — pthread_mutex_t wrapper.
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex.

## Test hosts

Same 4 x86 hosts as other doc refreshes. M1 Ultra absent.

---

## Cold-wait p99 (tail fairness signal)

Lower = better. Cold threads' 99th-percentile wait time while the hot thread dominates.

#### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | 397ns | **183ns** | 691ns | 365ns |
| tasks=16 coldgap=10µs | 5.2µs | 380ns | 879ns | **331ns** |
| tasks=64 coldgap=10µs | 3.8µs | 558ns | 859ns | **423ns** |

RustMutex wins tasks=16 coldgap=2µs; Sync.Mutex wins the other two. Optimal's in-spin CAS thrashes cache line when cold threads pile on a hot holder.

#### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | 9.1µs | 1.6µs | 17.3µs | **1.3µs** |
| tasks=16 coldgap=10µs | 9.4µs | 1.8µs | 16.2µs | **1.3µs** |
| tasks=64 coldgap=10µs | 8.3µs | 4.4µs | 21.3µs | **3.2µs** |

Sync.Mutex (PI) wins all 3 configs. First AMD workload this session where PI is correct. Rust second. Optimal/NIO lose tail.

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | 25.4µs | 15.0µs | 18.4µs | **15.0µs** |
| tasks=16 coldgap=10µs | 25.8µs | 15.4µs | 18.8µs | **14.8µs** |
| tasks=64 coldgap=10µs | **25.3µs** | 33.3µs | 34.4µs | 42.0µs |

Rust and Sync tie at tasks=16; Optimal wins tasks=64 where Skylake's UPI starts to add chain-walk cost to PI.

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | **17.3µs** | 26.6µs | 25.6µs | **616µs** |
| tasks=16 coldgap=10µs | **17.1µs** | 26.5µs | 22.9µs | **216µs** |
| tasks=64 coldgap=10µs | 81.3µs | **67.6µs** | 74.4µs | **2.41ms** |

Optimal dominates tasks=16; Rust edges it at tasks=64. Sync.Mutex catastrophic — Broadwell QPI amplifies PI cost even when chain should be short.

## Cold-wait p50 (typical cold-thread latency)

#### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | 78ns | **62ns** | 71ns | 82ns |
| tasks=16 coldgap=10µs | 76ns | 80ns | 83ns | **75ns** |
| tasks=64 coldgap=10µs | 88ns | 82ns | 90ns | **77ns** |

#### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | **160ns** | 171ns | 180ns | 170ns |
| tasks=16 coldgap=10µs | 160ns | 160ns | 160ns | 160ns |
| tasks=64 coldgap=10µs | 160ns | **150ns** | 160ns | 160ns |

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | **317ns** | 410ns | 382ns | 548ns |
| tasks=16 coldgap=10µs | **295ns** | 479ns | 428ns | 541ns |
| tasks=64 coldgap=10µs | **329ns** | 322ns | 366ns | 398ns |

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | 580ns | 614ns | **537ns** | 148.5µs |
| tasks=16 coldgap=10µs | 668ns | 677ns | **477ns** | 1.3µs |
| tasks=64 coldgap=10µs | **654ns** | 734ns | 855ns | **1.97ms** |

Optimal wins median on 2/4 CPUs (Skylake / mostly Broadwell); Alder Lake + AMD are tied at ns-level noise.

## Hot-wait p99 (hot-thread contention when rare interrupts happen)

Hot thread wins the fast path almost always — tails only spike when a cold thread grabs the lock and the hot thread has to wait. All variants ≤10µs p99 on non-NUMA; NUMA amplifies hot-wait tail.

#### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | **47ns** | 46ns | 53ns | 175ns |
| tasks=16 coldgap=10µs | **44ns** | 66ns | 56ns | 56ns |
| tasks=64 coldgap=10µs | **49ns** | 50ns | 56ns | 99ns |

#### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | 2.6µs | **420ns** | 730ns | 430ns |
| tasks=16 coldgap=10µs | 2.4µs | **371ns** | 760ns | 410ns |
| tasks=64 coldgap=10µs | **59ns** | 50ns | 89ns | 50ns |

RustMutex and Sync.Mutex tie at tasks=16 (parking keeps hot-wait low). Optimal's in-spin CAS penalizes hot thread occasionally.

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | 7.1µs | **1.2µs** | 2.1µs | 1.2µs |
| tasks=16 coldgap=10µs | 6.8µs | **1.2µs** | 2.1µs | 1.2µs |
| tasks=64 coldgap=10µs | 14.4µs | 3.8µs | 10.5µs | **2.7µs** |

Sync.Mutex wins hot-wait p99 at tasks=64 — Rust close second.

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| tasks=16 coldgap=2µs | **2.0µs** | 2.2µs | 7.4µs | 4.7µs |
| tasks=16 coldgap=10µs | **1.5µs** | 2.0µs | 7.3µs | 2.0µs |
| tasks=64 coldgap=10µs | 14.1µs | **1.4µs** | 8.3µs | 2.34ms |

Optimal wins tasks=16; RustMutex wins tasks=64. Sync.Mutex hot-wait p99 = 2.34ms at tasks=64 — PI chain walks hurt even the hot thread on Broadwell.

---

## Summary table — cold-wait p99 winners

| CPU | t=16 g=2µs | t=16 g=10µs | t=64 g=10µs | Pattern |
|---|---|---|---|---|
| Intel Alder Lake 12c | **Rust** | **Sync** | **Sync** | PI/Rust dominate |
| AMD EPYC Zen 4 64c | **Sync** | **Sync** | **Sync** | PI dominates (first AMD win) |
| Intel Xeon Gold Skylake NUMA | Sync/Rust tie | **Sync** | **Optimal** | Mixed |
| Intel Xeon E5 Broadwell NUMA | **Optimal** | **Optimal** | **Rust** | PI catastrophic |

**Generic-algorithm conclusion:** on skewed workloads with a hot-thread-dominates pattern, Optimal is not the best pick on AMD / Alder Lake / Skylake at tasks=16. Rust or Sync.Mutex win the cold-wait tail. Optimal is only the right generic default when workload is *uniform* or *NUMA*; for skewed workloads with known hot-holder, RustMutex or PI (per CPU) is better.

This is the first bench in the session where OptimalMutex is **not** the best generic pick.
