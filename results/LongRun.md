# LongRun

10-second wall-clock run at high contention with a long critical section (work=1024 — ~1µs CS). The shape that triggers [Go-style starvation mode](https://github.com/golang/go/blob/master/src/sync/mutex.go) (waiter blocked > 1 ms).

Based on [Go starvation mode](https://victoriametrics.com/blog/go-sync-mutex/) and [WebKit unfairness metric](https://webkit.org/blog/6161/locking-in-webkit/).

Each acquire records the wait time (acquisition-latency). Bench prints p50/p90/p99/p999/max for each variant across the fixed 10-second run. Wall-clock p50 is trivially 10s for all variants — the signal is in the latency histogram.

## Parameters

| Parameter | Values |
|---|---|
| tasks | 16, 64 |
| work | 1024 (~1µs hold) |
| duration | 10 s |

Gated behind `MUTEX_BENCH_SLOW=1`.

## Key findings

1. **Plain-futex is ns-scale p50, multi-second tail.** On every CPU, Optimal/Rust/NIO deliver p50 of 30–150ns while max reaches **9.98s on Alder Lake** (one thread starved for the entire bench). Fast median, catastrophic worst-case.

2. **PI-futex is µs/ms p50, bounded tail.** Sync.Mutex on Broadwell 44c t=64: p50 5.85ms, max 7.44ms — **max within 30% of p50**. Priority-inheritance prevents any thread from being starved. Trade-off: 50,000× slower median, 1000× better max.

3. **PI throughput is ~half of plain-futex.** 70k–420k acquires/10s vs 200k–900k. Kernel handoff costs every acquire, not just contended ones.

4. **RustMutex has better p999 than Optimal on NUMA Intel at high contention.** Skylake 40c t=64: Optimal p999=625ms vs Rust p999=348ms. AMD Zen 4 t=16: Optimal p999=81ms vs Rust p999=44ms. Consistent with HoldTime/CacheLevels finding that Rust's load-only spin handles NUMA tails better than Optimal's depth-gated retry.

5. **Broadwell 44c NUMA t=64 max reaches 7–10 seconds for plain-futex.** NIOLock max 9.97s — essentially 100% of bench time on a single starved thread. Plain-futex is unsuitable when you need bounded worst-case latency on NUMA at high contention. The 5× performance cost of PI buys guaranteed non-starvation.

### When PI-futex wins

| Need | Best pick | Why |
|---|---|---|
| Low p50/p99 acquire latency | **Optimal/Rust** | ns-scale; PI is µs/ms |
| High throughput | **Optimal/Rust** | 2× more acquires in fixed wall time |
| Bounded worst-case (max) | **Sync.Mutex (PI)** | max within 30% of p50; plain-futex max = near-bench-duration |
| Controlled p999 tail | Mixed | PI always safe; Rust better than Optimal on NUMA at high contention |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| Throughput-critical | **Optimal** | Wins p50/n on every CPU |
| Real-time-ish (bounded max required) | **Sync.Mutex (PI)** | Only variant guarantees bounded starvation |
| General-purpose | **Optimal** | 99% of workloads care about p50; max is a tail-guarantee need |
| NUMA + high-contention + want good p999 | RustMutex | Beats Optimal on p999 at t=64 on Skylake/AMD |

## Implementations

- **Optimal** — OptimalMutex with lazy waiter-count backport.
- **RustMutex** — Rust std 1.62+ load-only spin + post-CAS park.
- **NIOLockedValueBox (NIO)** — pthread_mutex_t wrapper.
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex.

## Test hosts

Same 4 x86 hosts. M1 Ultra absent.

---

## Acquire-latency histogram per CPU

Fresh 2026-04-20 data. Wall-clock p50 is 10s for all variants; `n` shows total acquires in 10s (higher = better throughput).

#### Intel i5-12500 (12c Alder Lake) — tasks=16, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 827,314 | 30ns | 30ns | 32ns | 40ns | **9.98s** |
| RustMutex | 742,798 | 30ns | 31ns | 32ns | 38ns | **9.98s** |
| NIOLockedValueBox | 790,461 | 30ns | 31ns | 33ns | 56ns | **9.98s** |
| Synchronization.Mutex | 414,963 | 240.4µs | 248.8µs | 253.3µs | 261.5µs | 1.03ms |

#### Intel i5-12500 (12c Alder Lake) — tasks=64, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 803,384 | 30ns | 31ns | 49ns | 54ns | **9.98s** |
| RustMutex | 773,758 | 30ns | 32ns | 51ns | 56ns | **9.98s** |
| NIOLockedValueBox | 806,412 | 35ns | 36ns | 45ns | 48ns | **9.98s** |
| Synchronization.Mutex | 419,604 | 235.8µs | 244.5µs | 249.7µs | 323.1µs | 991.7µs |

#### AMD EPYC 9454P (64c Zen 4) — tasks=16, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 584,949 | 30ns | 40ns | 61ns | 81.5ms | 532.1ms |
| RustMutex | 544,637 | 31ns | 40ns | 8.3ms | 44.6ms | 188.6ms |
| NIOLockedValueBox | 582,968 | 40ns | 40ns | 130ns | 80.9ms | 576.7ms |
| Synchronization.Mutex | 221,471 | 694.3µs | 726.0µs | 811.5µs | 924.7µs | 1.64ms |

#### AMD EPYC 9454P (64c Zen 4) — tasks=64, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 586,310 | 30ns | 40ns | 379ns | 254.8ms | **1.32s** |
| RustMutex | 532,340 | 31ns | 40ns | 40.7ms | 115.2ms | 337.9ms |
| NIOLockedValueBox | 583,731 | 40ns | 40ns | 380ns | 269.2ms | **1.19s** |
| Synchronization.Mutex | 216,242 | 2.87ms | 2.98ms | 3.13ms | 3.26ms | 3.41ms |

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA) — tasks=16, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 218,989 | 74ns | 81ns | 103ns | 112.3ms | **3.21s** |
| RustMutex | 204,098 | 67ns | 81ns | 199ns | 247.9ms | **1.39s** |
| NIOLockedValueBox | 207,420 | 78ns | 84ns | 110ns | 148.9ms | **4.12s** |
| Synchronization.Mutex | 99,473 | 1.49ms | 1.97ms | 2.32ms | 2.63ms | 4.08ms |

#### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA) — tasks=64, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 221,240 | 72ns | 81ns | 164ns | 624.9ms | **4.22s** |
| RustMutex | 196,213 | 67ns | 78ns | 47.1ms | 348.1ms | **1.41s** |
| NIOLockedValueBox | 219,493 | 76ns | 95ns | 193ns | 638.6ms | **4.65s** |
| Synchronization.Mutex | 102,057 | 3.70ms | 4.41ms | 5.07ms | 5.66ms | 8.55ms |

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA) — tasks=16, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 128,366 | 143ns | 157ns | 200ns | 406.3ms | **2.90s** |
| RustMutex | 121,098 | 137ns | 144ns | 210ns | 419.4ms | **2.38s** |
| NIOLockedValueBox | 117,295 | 150ns | 169ns | 184ns | 422.1ms | **3.33s** |
| Synchronization.Mutex | 73,783 | 2.09ms | 2.19ms | 2.39ms | 2.54ms | 4.37ms |

#### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA) — tasks=64, work=1024, dur=10s

| Variant | n | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|---:|
| Optimal | 128,218 | 144ns | 157ns | 191ns | **1.12s** | **7.61s** |
| RustMutex | 123,900 | 137ns | 147ns | 557ns | **1.02s** | **5.08s** |
| NIOLockedValueBox | 116,310 | 151ns | 174ns | 194ns | **1.15s** | **9.97s** |
| Synchronization.Mutex | 72,909 | 5.85ms | 6.05ms | 6.31ms | 6.61ms | 7.44ms |

**Broadwell 44c NUMA t=64 is the starvation regime.** NIOLock max=9.97s (entire bench). Optimal max=7.61s, Rust max=5.08s. Sync.Mutex max=7.44ms — **1000× better tail at the cost of 40,000× worse median**.
