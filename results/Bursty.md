# Bursty

Thundering-herd probe. All N Tasks wait on a shared deadline, then simultaneously try to acquire the lock. After `opsPerBurst` acquires each, quiet period, then repeat.

Tests settling-time distribution under bursty arrivals — the first few acquires in each burst are the worst case for fairness. Targets the same shape [glibc's `exp_backoff + jitter`](https://www.gnu.org/software/libc/manual/html_node/POSIX-Thread-Tunables.html) addresses, and the pattern [WebKit's unfairness detection](https://webkit.org/blog/6161/locking-in-webkit/) monitors.

Wall-clock p50 is the total workload time: (bursts × opsPerBurst × per-op-cost) + (bursts × quietPeriod). Quiet-period drives most of wall time — look at the spread, not the absolute number, to see lock differences.

## Parameters

| Config | Burst tasks | Bursts | Ops/burst | Quiet gap |
|---|---:|---:|---:|---:|
| burst=4×200 ops=64 | 4 | 200 | 64 | 2 ms |
| burst=16×200 ops=64 | 16 | 200 | 64 | 2 ms |
| burst=64×100 ops=32 | 64 | 100 | 32 | 2 ms |
| burst=8×5 ops=2048 | 8 | 5 | 2048 | 800 ms |

Bench gated behind `MUTEX_BENCH_SLOW=1` — wall time is multi-second per config.

## Key findings

1. **Quiet period dominates wall time for plain-futex variants.** Optimal/Rust/NIO land within 0.1% of each other and within 0.1% of the raw quiet-period budget (618ms ≈ 200 bursts × 2ms, minus a few µs of acquire cost). Lock design matters only for the acquire phase, which is a tiny fraction of the bench.

2. **PI-futex cliff fires spectacularly at burst=16 and burst=64 on AMD/NUMA.** Broadwell 44c burst=64×100: Sync.Mutex **9.81 seconds** vs Optimal 319ms (31× slower). AMD Zen 4 burst=64×100: **5.96s** vs 319ms (19×). Skylake 40c NUMA burst=64×100: **2.04s** vs 319ms (6×).

3. **burst=4 is PI-cliff-free everywhere.** 4 tasks simultaneously waking to contend don't form enough of a chain for PI-futex to misbehave. Same 4 variants cluster within 0.01% on all 4 CPUs.

4. **burst=8 long-ops (2048 ops per burst, 800ms quiet) shows minor PI overhead only on AMD.** Sync.Mutex 3.61s on AMD vs 3.23s plain (12% slower). Every other CPU matches within 0.3%. Low burst count + long ops + long quiet = most-benign PI regime besides sleep-in-lock.

5. **Thundering herd is the worst PI regime tested this session.** burst=64×100 on Broadwell 44c: 9.81s. Same machine's ContentionScaling at t=64 peaks around 3.5s. The burst-then-release pattern maximizes PI chain depth because all 64 waiters park simultaneously with priority-inheritance metadata.

### PI-futex cliff — per CPU on Bursty

| CPU | burst=4 (200) | burst=16 (200) | burst=64 (100) | burst=8 (long ops) |
|---|---:|---:|---:|---:|
| Intel i5-12500 (12c Alder Lake) | within 0.01% | within 0.01% | within 0.1% | within 0.01% |
| AMD EPYC 9454P (64c Zen 4) | within 0.01% | **8.8×** | **19×** | 12% |
| Intel Xeon Gold 6148 (40c Skylake NUMA) | within 0.01% | within 0.01% | **6.4×** | within 0.3% |
| Intel Xeon E5-2699 v4 (44c Broadwell NUMA) | within 0.01% | **12×** | **31×** | 6% |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| Low-burst (≤ 4 tasks) | any | All variants within 0.01% |
| Moderate burst (16 tasks) on Intel consumer | any | Quiet period dominates |
| Moderate burst (16 tasks) on AMD/Broadwell | **Optimal** | Avoids 8–12× PI cliff |
| High burst (64 tasks) on AMD/NUMA | **Optimal** | Avoids 6–31× PI cliff |
| Long-ops bursts with long quiet | any (Sync.Mutex 12% slower on AMD) | Quiet period dominates; lock barely matters |

## Implementations

- **Optimal** — OptimalMutex with lazy waiter-count backport.
- **RustMutex** — Rust std 1.62+ load-only spin + post-CAS park.
- **NIOLockedValueBox (NIO)** — pthread_mutex_t wrapper.
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex.

## Test hosts

Same 4 x86 hosts. M1 Ultra absent.

---

## Detailed p50 wall-clock (µs)

Fresh 2026-04-20 data. Gated behind `MUTEX_BENCH_SLOW=1`.

### Intel i5-12500 (12c Alder Lake)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| burst=4×200 ops=64 quiet=2ms | 617,157 | 617,251 | 617,280 | 617,306 |
| burst=16×200 ops=64 quiet=2ms | 617,348 | 618,058 | 617,271 | 618,609 |
| burst=64×100 ops=32 quiet=2ms | 317,744 | 319,029 | 319,260 | 319,554 |
| burst=8×5 ops=2048 quiet=800ms | **3.23s** | **3.23s** | **3.23s** | **3.23s** |

No PI cliff. All variants within 0.3%.

### AMD EPYC 9454P (64c Zen 4)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| burst=4×200 ops=64 quiet=2ms | 617,442 | 617,481 | 617,445 | 617,432 |
| burst=16×200 ops=64 quiet=2ms | 617,962 | 618,136 | 618,427 | **5.42s** |
| burst=64×100 ops=32 quiet=2ms | 318,767 | 318,974 | 319,206 | **5.96s** |
| burst=8×5 ops=2048 quiet=800ms | **3.23s** | **3.23s** | **3.23s** | **3.61s** |

PI cliff at burst=16 (8.8×) and burst=64 (19×). burst=4 stays safe — 4 threads not enough for chain-walk pathology.

### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| burst=4×200 ops=64 quiet=2ms | 617,347 | 617,407 | 617,388 | 617,411 |
| burst=16×200 ops=64 quiet=2ms | 617,578 | 618,016 | 618,080 | 618,660 |
| burst=64×100 ops=32 quiet=2ms | 318,505 | 318,767 | 318,767 | **2.04s** |
| burst=8×5 ops=2048 quiet=800ms | **3.23s** | **3.24s** | **3.24s** | **3.24s** |

Skylake UPI handles 16-task bursts fine; cliff only at burst=64 (6×). Milder than AMD/Broadwell.

### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Config | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| burst=4×200 ops=64 quiet=2ms | 617,288 | 617,410 | 617,408 | 617,339 |
| burst=16×200 ops=64 quiet=2ms | 618,641 | 618,660 | 618,488 | **7.52s** |
| burst=64×100 ops=32 quiet=2ms | 319,291 | 319,029 | 319,291 | **9.81s** |
| burst=8×5 ops=2048 quiet=800ms | **3.23s** | **3.24s** | **3.24s** | **3.42s** |

Worst PI regime tested. burst=64×100: **9.81s**, 31× slower than Optimal. Broadwell's older QPI + large chain = catastrophic.
