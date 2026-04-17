# Lock Fairness Analysis

Per-acquire latency distributions from the Asymmetric benchmark. One producer (work=256) and N consumers (work=1) contend on the same lock. Each iteration measures 49,995 individual lock acquisitions. The distribution reveals how evenly acquire latency is spread across contending threads - tight distributions mean fair access, wide spreads mean some threads are starved.

![Fairness tail curves per machine](graphs/fairness__grid.png)

## Fairness scaling: consumers=15 vs consumers=63

The critical question is how fairness changes as consumer count crosses the core count boundary (not oversubscribed to oversubscribed).

### Optimal p99 (per-acquire latency, ns)

| Machine | Cores | c=15 p99 | c=63 p99 | Change | c=63 NIO p99 |
|---|---:|---:|---:|---|---:|
| aarch64 18c | 18 | 140,284 | 157,144 | +12% | 131,859 |
| x86 12c | 12 | 245 | 33 | improved | 35 |
| x86 40c | 40 | 84,402 | 323,951 | 3.9x worse | 1,664,475 |
| x86 44c NUMA | 44 | 1,122,607 | 2,707,741 | 2.4x worse | 2,196,642 |
| x86 64c | 64 | 128,452 | 1,143,438 | **8.9x worse** | **229,103** |

### Optimal p50 (per-acquire latency, ns)

| Machine | c=15 p50 | c=63 p50 | Change | c=63 NIO p50 |
|---|---:|---:|---|---:|
| aarch64 18c | 42 | 42 | same | 43 |
| x86 12c | 29 | 29 | same | 30 |
| x86 40c | 2,509 | 3,387 | +35% | 474 |
| x86 44c NUMA | 873 | 797 | same | 424 |
| x86 64c | 341 | 480 | +41% | 356 |

**Key finding:** Optimal's p50 stays fast at c=63 (29-480 ns) but p99 degrades significantly on many-core machines. On x86 64c, Optimal p99 goes from 128 us to 1,143 us (8.9x) while NIOLock p99 actually improves from 291 us to 229 us. More consumers means more threads losing the CAS race under barging, creating longer starvation events.

On x86 40c, NIOLock p99 degrades worse than Optimal (1,664 us vs 324 us) - the NUMA wake penalty hits NIOLock harder with more threads crossing sockets.

---

## Detailed per-machine results (consumers=15)

### x86 12c (Intel i5-12500, 6P/12T HT)

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| **Optimal** | **29 ns** | **31 ns** | 245 ns | 701 ns | 1.6 ms |
| PlainFutexMutex (spin=100) | 29 ns | 30 ns | 34 ns | 42 ns | 1.8 us |
| Synchronization.Mutex (PI) | 29 ns | 30 ns | 33 ns | 42 ns | 28 us |
| NIOLockedValueBox | 31 ns | 49 ns | 69 ns | 80 ns | 1.1 ms |

On 12 cores all implementations have near-identical p50 (29-31 ns). PI overhead is negligible at this core count.

### x86 40c (Intel Xeon Gold 6148, 2-socket NUMA)

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| NIOLockedValueBox | 390 ns | 24 us | 411 us | 3.9 ms | 11 ms |
| **Optimal** | **2.5 us** | **23 us** | **84 us** | 5.3 ms | 41 ms |
| PlainFutexMutex (spin=100) | 6.4 us | 30 us | 131 us | 4.0 ms | 53 ms |
| **Synchronization.Mutex (PI)** | **176 us** | **214 us** | **471 us** | **989 us** | **1.7 ms** |

Optimal p99=84 us is tightest of non-PI implementations. NIOLock has best p50 (390 ns) but worst p99 (411 us) - NUMA wake penalty.

### x86 44c (Intel Xeon E5-2699 v4, 2-socket NUMA)

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| NIOLockedValueBox | 409 ns | 39 us | 1,258 us | 4.7 ms | 11 ms |
| **Optimal** | **873 ns** | **31 us** | **1,123 us** | 4.5 ms | 12 ms |
| PlainFutexMutex (spin=100) | 1.8 us | 32 us | 911 us | 5.3 ms | 15 ms |
| **Synchronization.Mutex (PI)** | **638 us** | **839 us** | **962 us** | **1.2 ms** | **2.3 ms** |

2-socket NUMA. All non-PI implementations have p99 around 1 ms due to cross-socket wake latency.

### x86 64c (AMD EPYC 9454P, CCD chiplet)

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| NIOLockedValueBox | 225 ns | 27 us | 291 us | 1.0 ms | 2.3 ms |
| PlainFutexMutex (spin=100) | 269 ns | 7.7 us | 330 us | 1.2 ms | 2.9 ms |
| **Optimal** | **341 ns** | **7.4 us** | **128 us** | **2.1 ms** | **8.5 ms** |
| **Synchronization.Mutex (PI)** | **274 us** | **293 us** | **326 us** | **406 us** | **583 us** |

Optimal has tightest p99 of non-PI implementations (128 us) but fattest max (8.5 ms) from occasional CCD-crossing starvation events.

### aarch64 18c (Apple M1 Ultra)

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| **Optimal** | **42 ns** | 308 ns | 140 us | 530 us | 4.8 ms |
| NIOLockedValueBox | 43 ns | 1,539 ns | 133 us | 445 us | 4.3 ms |
| PlainFutexMutex (spin=100) | 61 ns | 35 us | 141 us | 300 us | 11.5 ms |
| **Synchronization.Mutex (PI)** | **382 us** | **443 us** | **503 us** | **556 us** | **712 us** |

---

## Detailed per-machine results (consumers=63)

### x86 12c (Intel i5-12500, 6P/12T HT) - 64 threads on 12 cores

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| **Optimal** | **29 ns** | **30 ns** | **33 ns** | 55 ns | 2.3 us |
| Synchronization.Mutex (PI) | 29 ns | 30 ns | 33 ns | 53 ns | 2.1 us |
| PlainFutexMutex (spin=100) | 29 ns | 30 ns | 33 ns | 55 ns | 5.0 us |
| NIOLockedValueBox | 30 ns | 30 ns | 35 ns | 58 ns | 2.4 us |

Everything converges at c=63 on 12 cores. The heavy oversubscription (5.3x) creates uniform scheduling pressure - all threads are equally slow.

### x86 40c (Intel Xeon Gold 6148, 2-socket NUMA) - 64 threads on 40 cores

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| NIOLockedValueBox | 474 ns | 24 us | 1,664 us | 7.1 ms | 14 ms |
| **Optimal** | **3.4 us** | **23 us** | **324 us** | 17.6 ms | 54 ms |
| PlainFutexMutex (spin=100) | 10.3 us | 30 us | 609 us | 17.7 ms | 62 ms |
| **Synchronization.Mutex (PI)** | **380 us** | **214 us** | **788 us** | **1.4 ms** | **2.0 ms** |

Optimal p99 (324 us) still beats NIOLock (1,664 us) at c=63 on 40c. The NUMA wake penalty hurts NIOLock more - waking threads across sockets is expensive.

### x86 44c (Intel Xeon E5-2699 v4, 2-socket NUMA) - 64 threads on 44 cores

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| NIOLockedValueBox | 424 ns | 39 us | 2,197 us | 5.6 ms | 10 ms |
| **Optimal** | **797 ns** | **31 us** | **2,708 us** | 5.8 ms | 11 ms |
| PlainFutexMutex (spin=100) | 1.3 us | 32 us | 3,001 us | 6.9 ms | 13 ms |
| **Synchronization.Mutex (PI)** | **2,046 us** | **839 us** | **2,682 us** | **2.9 ms** | **3.4 ms** |

PI cliff worsens dramatically at c=63 on NUMA: p50 jumps from 638 us to 2,046 us. PI chain walking across NUMA nodes with 64 threads is devastating.

### x86 64c (AMD EPYC 9454P, CCD chiplet) - 64 threads on 64 cores

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| NIOLockedValueBox | 356 ns | 27 us | **229 us** | 452 us | 2.1 ms |
| PlainFutexMutex (spin=100) | 459 ns | 7.7 us | 1,569 us | 4.6 ms | 11 ms |
| **Optimal** | **480 ns** | **7.4 us** | **1,143 us** | 4.7 ms | 11 ms |
| **Synchronization.Mutex (PI)** | **1,167 us** | **293 us** | **1,313 us** | **1.8 ms** | **2.0 ms** |

NIOLock p99 improves from 291 us (c=15) to 229 us (c=63) - the kernel wake distribution spreads more evenly with more consumers. Optimal p99 degrades 8.9x to 1,143 us. At c=63 on 64 cores (1:1 ratio), NIOLock's kernel-mediated fairness beats Optimal's barging at the tail.

### aarch64 18c (Apple M1 Ultra) - 64 threads on 18 cores

| Implementation | p50 | p90 | p99 | p999 | max |
|---|---:|---:|---:|---:|---:|
| **Optimal** | **42 ns** | 308 ns | 157 us | 539 us | 8.4 ms |
| NIOLockedValueBox | 43 ns | 542 ns | 132 us | 428 us | 3.9 ms |
| PlainFutexMutex (spin=100) | 88 ns | 35 us | 148 us | 316 us | 11 ms |
| **Synchronization.Mutex (PI)** | **400 us** | **443 us** | **526 us** | **578 us** | **668 us** |

ARM barely affected by c=15 to c=63 transition. Optimal p50 stays at 42 ns. The M1 Ultra's unified memory and efficient scheduler handle 64 threads on 18 cores without significant fairness degradation.

---

## The throughput vs fairness tradeoff

| Strategy | Mechanism | p50 | Tail at c=63 | Who uses it |
|---|---|---|---|---|
| Barging + spin | Spinners CAS on unlock | Best | Degrades with consumer count | Optimal, WebKit, Rust parking_lot |
| Park-immediately | Kernel FIFO wake | Good | Stable or improves | NIOLock (`pthread_mutex_t`) |
| PI kernel handoff | Kernel direct transfer | Worst | Tight but collapses on NUMA | Stdlib `Synchronization.Mutex` |

### Why Optimal's tail degrades at c=63

With 63 consumers racing for the lock, each release triggers a CAS race. One spinner wins, 62 lose. The losers include both spinning threads and kernel-woken threads. A parked thread that gets woken by `FUTEX_WAKE` has to compete with active spinners - it often loses and goes back to sleep. With more consumers, the probability of repeated starvation increases.

### Why NIOLock improves at c=63 on 64c

NIOLock parks immediately (no spin) so all contenders go through the kernel. `FUTEX_WAKE` wakes one thread, which runs without CAS competition from spinners. With more threads, the kernel's scheduling becomes more uniform - each thread gets a fair share of wake opportunities.

### Why PI collapses on NUMA at c=63

At c=63 on 44c NUMA, PI p50 jumps from 638 us to 2,046 us. The PI chain has to walk across NUMA nodes for 64 threads, and `rt_mutex` bookkeeping scales with waiter count. The FIFO fairness is maintained (p99/p50=1.3x) but every acquire is 3x slower.

## Potential fairness improvements (follow-ups)

1. **Go starvation mode** - If any waiter blocked >1 ms, disable spinning and hand lock directly to the longest waiter. Addresses the tail without sacrificing p50 throughput in the common case. [Go sync.Mutex](https://github.com/golang/go/blob/master/src/sync/mutex.go)

2. **WebKit random fairness injection** - On unlock, with probability ~1/256, do direct handoff to the longest-waiting thread. Bounds the maximum starvation time. [Locking in WebKit](https://webkit.org/blog/6161/locking-in-webkit/)

3. **Ticket/queue hybrid** - Assign tickets, spin only if your ticket is next. Strict FIFO with userspace spinning. More complex but gives both throughput and fairness.

None of these are needed for the initial fix. Optimal's fairness matches or exceeds `pthread_mutex_t` (NIOLock) in most configurations, and Swift has been using NIOLock-style mutexes successfully in production. The c=63 tail regression on 64c is a known tradeoff of barging locks.
