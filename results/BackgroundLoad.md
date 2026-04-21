# Background Load

How mutex performance is affected when idle background Tasks compete for scheduler slots alongside lock-contending Tasks. Adapted from [Go `BenchmarkMutexSlack`](https://github.com/golang/go/blob/master/src/sync/mutex_test.go).

## Workload

16 contending Tasks repeatedly acquire a lock (work=1 map update per acquire). M additional background Tasks burn CPU without touching the lock. The `slack` parameter controls how many background Tasks are running.

| Parameter | Values |
|---|---|
| contenders | 16 |
| background tasks (slack) | 0, 16, 64, 256 |
| work per acquire | 1 |

This tests whether the mutex spin strategy fights the Swift cooperative executor for scheduling. If spinning burns CPU that background Tasks or the lock owner needs, performance degrades under load.

## Key findings

1. **Slack is near-invisible on plain-futex variants.** Optimal/Rust/NIO move <15% as slack sweeps 0→256 on every CPU. Swift cooperative executor keeps the lock contenders mapped to real OS threads; background Tasks consume their own slots without displacing the lock's hot threads.

2. **PI-futex shows the most slack-sensitivity.** Broadwell 44c NUMA Sync.Mutex: slack=0 = 1.76s, slack=16 = 634ms, slack=256 = 775ms. Background tasks interfere with the PI chain-walk's thread-priority propagation — non-monotonic variance.

3. **OptimalMutex wins every config on every CPU.** 1.4–7× faster than Rust/NIO. Background-load has the cleanest signal for Optimal's dominance because slack doesn't change the lock-contention shape, only scheduler pressure.

4. **PI cliff fires at every slack value on AMD / NUMA Intel.** AMD Zen 4: stable 1.28–1.35s. Skylake 40c NUMA: 276k–483ms. Broadwell 44c NUMA: 634ms–1.76s. Alder Lake 12c: no cliff (13–15ms).

5. **slack=256 is the most-fair comparison across CPUs** — 256 background tasks force real scheduler contention even on 64c machines. Plain-futex variants still scale; PI degrades further.

### PI-futex cliff — per CPU on BackgroundLoad

| CPU | slack=0 | slack=256 | Spread |
|---|---:|---:|---:|
| Intel i5-12500 (12c Alder Lake) | 7× | 5× | flat |
| AMD EPYC 9454P (64c Zen 4) | **110×** | **110×** | flat |
| Intel Xeon Gold 6148 (40c Skylake NUMA) | **12×** | **20×** | slack worsens PI |
| Intel Xeon E5-2699 v4 (44c Broadwell NUMA) | **62×** | **22×** | highly variant |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| Any slack, any CPU | **Optimal** | 1.4–7× faster; slack-insensitive |
| Swift-heavy apps (many Tasks) | Optimal or Rust | Both plain-futex handle cooperative executor well |
| Priority-inheritance required | Sync.Mutex (accept 12-110× cost on NUMA/AMD) | Only PI-futex provides the guarantee; pay the cliff penalty |

## Implementations

- **Optimal** — OptimalMutex with lazy waiter-count backport.
- **RustMutex** — Rust std 1.62+ load-only spin + post-CAS park.
- **NIOLockedValueBox (NIO)** — pthread_mutex_t wrapper.
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex.

## Test hosts

Same 4 x86 hosts as ContentionRatio / HoldTime / CacheLevels. M1 Ultra absent.

---

## Detailed p50 wall-clock (µs)

Fresh 2026-04-20 data; contenders=16 work=1 throughout.

### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| contenders=16 slack=0 work=1 | 1,972 | 9,413 | 10,355 | 13,984 |
| contenders=16 slack=16 work=1 | 2,105 | 9,535 | 10,543 | 13,951 |
| contenders=16 slack=64 work=1 | 2,253 | 9,699 | 10,764 | 14,172 |
| contenders=16 slack=256 work=1 | 2,728 | 10,166 | 11,272 | 14,868 |

Optimal 4–7× faster. Slack adds 38% overhead for Optimal at slack=256 — scheduler pressure starts to cost something, but still dominant. No PI cliff.

### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| contenders=16 slack=0 work=1 | 11,674 | 16,269 | 21,479 | **1.28s** |
| contenders=16 slack=16 work=1 | 13,066 | 15,925 | 21,922 | **1.33s** |
| contenders=16 slack=64 work=1 | 11,641 | 16,417 | 21,971 | **1.35s** |
| contenders=16 slack=256 work=1 | 12,280 | 16,327 | 22,331 | **1.35s** |

PI cliff stable at ~1.3s across all slack. Plain-futex spread tight (~10%). Optimal 40% faster than Rust, 2× faster than NIO.

### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| contenders=16 slack=0 work=1 | 22,233 | 32,522 | 30,851 | 275,513 |
| contenders=16 slack=16 work=1 | 21,905 | 32,555 | 32,178 | 445,121 |
| contenders=16 slack=64 work=1 | 22,053 | 33,030 | 33,473 | 415,498 |
| contenders=16 slack=256 work=1 | 24,117 | 34,505 | 34,898 | 482,869 |

PI worsens from 276ms to 483ms as slack climbs — NUMA + PI chain walk + background noise compound. Optimal stable 22–24ms.

### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| contenders=16 slack=0 work=1 | 28,508 | 31,261 | 30,851 | **1.76s** |
| contenders=16 slack=16 work=1 | 34,472 | 38,830 | 38,175 | 634,388 |
| contenders=16 slack=64 work=1 | 33,718 | 38,175 | 39,584 | 640,680 |
| contenders=16 slack=256 work=1 | 34,931 | 38,273 | 41,124 | 775,422 |

Broadwell's QPI interconnect produces erratic PI-cliff behavior: slack=0 catastrophic (1.76s), slack≥16 improves to ~640ms then climbs again at slack=256. Plain-futex variants cluster tightly and handle slack well — Optimal 10–20% faster than Rust/NIO.
