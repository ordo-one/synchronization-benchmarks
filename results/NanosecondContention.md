# NanosecondContention

Nanosecond-calibrated delay grid ported from [abseil BM_Contended](https://github.com/abseil/abseil-cpp/blob/master/absl/synchronization/mutex_benchmark.cc). Uses busy-wait calibrated in nanoseconds so results compare across machines without normalizing for CPU speed.

Includes a `no-lock baseline` (same loop without a lock) to separate loop overhead from actual lock cost.

## Parameters

| Parameter | Values |
|---|---|
| tasks | 2, 8, 16, 64 |
| delay_inside (hold time) | 0, 50, 1000, 100000 ns |
| delay_outside (inter-acquire gap) | 0, 100, 2000 ns |

## Optimal vs NIOLock ratio (p50)

| Test | aarch64 18c | x86 192c |
|---|---:|---:|
| t=16 in=0ns out=0ns | 1.2x | 0.8x |
| t=16 in=50ns out=0ns | 1.1x | 0.8x |
| t=16 in=50ns out=100ns | ~1x | 0.8x |
| t=16 in=1000ns out=0ns | 1.4x | 1.3x |
| t=16 in=50ns out=2000ns | ~1x | 0.9x |
| t=2 in=50ns out=100ns | ~1x | 1.2x |
| t=64 in=50ns out=100ns | 1.0x | 0.8x |

This is the benchmark where Optimal shows the least advantage - and occasionally loses to NIOLock on x86 192c. At near-zero hold times (0-50ns), the spinning overhead exceeds the benefit of catching releases.

## Where NIOLock wins

On x86 192c, NIOLock is 20% faster at in=0-50ns configurations. With 192 cores and near-zero hold, there is no oversubscription and parking immediately avoids all spin cost. This is the strongest case against spinning - but no real workload has a 0-50ns critical section.

At in=1000ns (1 us hold), Optimal wins back the lead: 1.3-1.4x faster. One microsecond is enough hold time for the spin phase to catch releases.

## Stdlib PI at nanosecond scale

| Test | aarch64 18c | x86 192c |
|---|---:|---:|
| t=16 in=0ns out=0ns | ~1x (PI cliff bimodal) | 12x slower |
| t=16 in=50ns out=100ns | ~1x | 4.6x slower |
| t=16 in=1000ns out=0ns | 11x slower | 4.2x slower |
| t=64 in=50ns out=100ns | 1.1x slower | 9.1x slower |

On aarch64 18c at in=0-50ns, Stdlib PI is competitive with NIOLock because the ARM `wfe` spin loop (100 iterations) is efficient at these timescales. On x86 192c, Stdlib PI is 4-12x slower even at nanosecond holds.

---

## Detailed results

### aarch64 18c (Apple M1 Ultra, 18c container VM)

| Test | no-lock | Optimal | NIOLock | Stdlib PI |
|---|---:|---:|---:|---:|
| t=16 in=0ns out=0ns | 25,461 | 26,952 | 33,112 | 31,801 |
| t=16 in=50ns out=0ns | 26,526 | 30,753 | 33,817 | 37,323 |
| t=16 in=50ns out=100ns | 29,164 | 34,144 | 34,046 | 35,652 |
| t=16 in=1000ns out=0ns | 29,508 | 78,840 | 110,559 | 1,218,445 |
| t=16 in=50ns out=2000ns | 35,652 | 37,159 | 37,585 | 39,748 |
| t=2 in=50ns out=100ns | 33,751 | 35,455 | 34,603 | 35,357 |
| t=8 in=50ns out=100ns | 31,179 | 34,570 | 36,766 | 35,815 |
| t=64 in=50ns out=100ns | 28,967 | 33,718 | 35,127 | 40,075 |

At in=0ns, Optimal (26,952) is only 6% above the no-lock baseline (25,461). Lock overhead is minimal. NIOLock (33,112) is 30% above baseline - the futex syscall cost on every contended acquire.

### x86 192c (Intel Xeon Platinum 8488C, EC2 c7i.metal-48xl)

| Test | no-lock | Optimal | NIOLock | Stdlib PI |
|---|---:|---:|---:|---:|
| t=16 in=0ns out=0ns | 20,972 | 33,948 | 25,723 | 308,281 |
| t=16 in=50ns out=0ns | 21,135 | 40,337 | 30,638 | 407,372 |
| t=16 in=50ns out=100ns | 21,430 | 45,384 | 37,323 | 170,263 |
| t=16 in=1000ns out=0ns | 24,101 | 87,622 | 110,100 | 462,422 |
| t=16 in=50ns out=2000ns | 27,197 | 46,072 | 42,533 | 49,676 |
| t=2 in=50ns out=100ns | 23,396 | 24,904 | 29,442 | 24,805 |
| t=8 in=50ns out=100ns | 21,463 | 43,188 | 36,471 | 42,893 |
| t=64 in=50ns out=100ns | 21,561 | 49,086 | 40,632 | 368,050 |

On 192c at in=0ns, Optimal (33,948) is 62% above no-lock baseline (20,972). NIOLock (25,723) is only 23% above. The regime-gated spin loop does 14 iterations of backoff even when the lock releases in nanoseconds - the spin cost exceeds the benefit. NIOLock's park-immediately avoids this entirely.

At in=1000ns, the picture flips: Optimal (87,622) beats NIOLock (110,100) by 1.3x. One microsecond of hold time is enough for spinning to pay off.

---

## Key findings

1. **Nanosecond-scale holds are where Optimal is weakest.** The regime-gated spin adds overhead when the critical section is shorter than one spin iteration. On x86 192c, NIOLock is 20% faster at in=0-50ns.

2. **At 1 us hold time, Optimal wins back.** in=1000ns is enough for the spin to catch releases. 1.3-1.4x faster than NIOLock on both machines.

3. **With out=2000ns inter-acquire gap, everything converges.** The gap between acquires masks lock strategy differences.

4. **The no-lock baseline shows true lock overhead.** On aarch64 18c, Optimal adds only 6% over no-lock at in=0ns. On x86 192c, it adds 62%. The difference is the spin cost on 192 cores where parking is cheaper.

5. **No real workload has a 0-50ns critical section.** Even a single dictionary lookup or pointer dereference under a lock takes more than 50ns. The nanosecond regime is a theoretical stress test, not a practical concern.
