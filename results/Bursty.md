# Bursty

Thundering-herd probe. All N Tasks wait on a shared deadline, then simultaneously try to acquire the lock. After `opsPerBurst` acquires each, quiet period, then repeat.

Tests settling-time distribution under bursty arrivals - the first few acquires in each burst are the worst case for fairness. Targets the same shape [glibc's `exp_backoff + jitter`](https://www.gnu.org/software/libc/manual/html_node/POSIX-Thread-Tunables.html) addresses, and the pattern [WebKit's unfairness detection](https://webkit.org/blog/6161/locking-in-webkit/) monitors.

## Parameters

| Config | Burst tasks | Bursts | Ops/burst | Quiet gap |
|---|---:|---:|---:|---:|
| 64x100 ops=32 | 64 | 100 | 32 | 2 ms |
| 16x200 ops=64 | 16 | 200 | 64 | 2 ms |
| 4x200 ops=64 | 4 | 200 | 64 | 2 ms |
| 8x5 ops=2048 | 8 | 5 | 2048 | 800 ms |

## Results (p50 wall clock, us)

### burst=64x100 ops=32 quiet=2ms

| Impl | x86 12c | x86 64c | x86 192c |
|---|---:|---:|---:|
| Optimal | 317,191 | 317,719 | 319,554 |
| NIOLock | 317,194 | 318,243 | 319,816 |
| PlainFutexMutex (spin=100) | 317,194 | 317,863 | 319,554 |
| Stdlib PI | 317,194 | **3,783,262** | **1,852,834** |

### burst=16x200 ops=64 quiet=2ms

| Impl | x86 12c | x86 64c | x86 192c |
|---|---:|---:|---:|
| Optimal | 617,312 | 617,523 | 618,136 |
| NIOLock | 617,342 | 617,611 | 618,660 |
| PlainFutexMutex (spin=100) | 617,087 | 617,419 | 618,660 |
| Stdlib PI | 617,085 | **3,458,204** | **1,811,939** |

### burst=4x200 ops=64 quiet=2ms

| Impl | x86 12c | x86 64c | x86 192c |
|---|---:|---:|---:|
| Optimal | 617,038 | 617,150 | 617,325 |
| NIOLock | 617,038 | 617,167 | 617,339 |
| PlainFutexMutex (spin=100) | 617,118 | 617,180 | 617,343 |
| Stdlib PI | 617,033 | 617,191 | 617,611 |

### burst=8x5 ops=2048 quiet=800ms

| Impl | x86 12c | x86 64c | x86 192c |
|---|---:|---:|---:|
| Optimal | 3,224,536 | 3,227,259 | 3,231,711 |
| NIOLock | 3,224,599 | 3,229,614 | 3,235,906 |
| PlainFutexMutex (spin=100) | 3,224,632 | 3,227,517 | 3,231,711 |
| Stdlib PI | 3,224,606 | 3,468,689 | 3,363,832 |

## Key findings

1. **Bursty workloads are dominated by the quiet period and ops count.** With ops=64 and quiet=2ms, the wall clock is ~617ms regardless of lock implementation. The lock overhead is negligible relative to the work and sleep.

2. **Stdlib PI collapses on many-core bursty workloads.** At burst=64x100 on x86 64c, Stdlib PI takes 3,783ms vs everyone else at 318ms - **12x slower**. The burst of 64 simultaneous tasks triggers the PI-futex cliff. On x86 192c: 1,853ms - **5.8x slower**.

3. **At burst=4, Stdlib PI is fine.** Only 4 tasks contending per burst - below the PI cliff threshold on all machines.

4. **Optimal, NIOLock, and PlainFutexMutex (spin=100) are identical.** Within measurement noise across all configurations. The 2ms quiet gap between bursts allows all parked threads to wake, eliminating any spin strategy advantage.

5. **On x86 12c, everything converges.** No PI cliff with 12 cores. All implementations within 0.01% of each other.
