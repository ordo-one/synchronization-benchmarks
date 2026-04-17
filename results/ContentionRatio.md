# ContentionRatio

How much unlocked work between lock acquires affects contention. Real applications do processing between acquires - not every thread immediately re-contends after releasing.

Based on [Go sync.Mutex benchmark](https://github.com/golang/go/blob/master/src/sync/mutex_test.go) (ratio parameter) and [folly SharedMutex tests](https://github.com/facebook/folly/blob/main/folly/test/SharedMutexTest.cpp) (write fraction control).

## Parameters

| Parameter | Values |
|---|---|
| tasks | 4, 16, 64 |
| work | 1, 4 |
| pause | 0, 10, 100 |

Cross-axis points: tasks=4 (low contention), tasks=64 (high contention), work=4 (longer CS with inter-acquire gap).

## Optimal vs NIOLock ratio (p50)

| Test | aarch64 18c | x86 12c | x86 44c | x86 192c |
|---|---:|---:|---:|---:|
| t=4 w=1 p=10 | 3.9x | 1.4x | 1.3x | 0.8x |
| t=16 w=1 p=0 | 4.8x | 1.4x | 1.3x | 1.3x |
| t=16 w=1 p=10 | 4.1x | 1.4x | 1.1x | ~1x |
| t=16 w=1 p=100 | 1.7x | ~1x | 1.1x | ~1x |
| t=16 w=4 p=10 | 2.3x | 1.1x | 1.7x | 1.2x |
| t=64 w=1 p=10 | 3.4x | 1.3x | 1.2x | 1.1x |

Optimal wins at every configuration on aarch64. On x86 machines, the advantage narrows as pause increases - more inter-acquire gap means less contention pressure and less opportunity for spinning to help.

At pause=100 on x86 12c, all implementations converge. The inter-acquire work dominates lock acquisition time.

## Stdlib PI penalty

| Test | aarch64 18c | x86 12c | x86 44c |
|---|---|---|---|
| t=16 w=1 p=0 | 106x (Stdlib PI in cliff) | ~1x | 25x |
| t=16 w=1 p=10 | 109x | ~1x | 34x |
| t=16 w=1 p=100 | bimodal | ~1x | 29x |
| t=16 w=4 p=10 | 69x | ~1x | 15x |
| t=64 w=1 p=10 | 130x | ~1x | 73x |

Stdlib PI penalty persists regardless of inter-acquire gap on 44+ core machines. Adding pause=100 does not rescue it.

---

## Detailed results

### aarch64 18c (Apple M1 Ultra, 18c container VM)

| Test | Impl | p50 |
|---|---|---:|
| t=4 w=1 p=10 | **Optimal** | 1,266 |
| t=4 w=1 p=10 | PlainFutexMutex (spin=100) | 1,330 |
| t=4 w=1 p=10 | NIOLock | 4,903 |
| | | |
| t=16 w=1 p=0 | **Optimal** | 1,352 |
| t=16 w=1 p=0 | PlainFutexMutex (spin=100) | 2,615 |
| t=16 w=1 p=0 | NIOLock | 6,504 |
| t=16 w=1 p=0 | Stdlib PI | 694,682 |
| | | |
| t=16 w=1 p=10 | **Optimal** | 1,739 |
| t=16 w=1 p=10 | PlainFutexMutex (spin=100) | 3,072 |
| t=16 w=1 p=10 | NIOLock | 7,160 |
| t=16 w=1 p=10 | Stdlib PI | 756,548 |
| | | |
| t=16 w=1 p=100 | **Optimal** | 9,716 |
| t=16 w=1 p=100 | NIOLock | 16,941 |
| t=16 w=1 p=100 | PlainFutexMutex (spin=100) | 18,711 |
| t=16 w=1 p=100 | Stdlib PI | 18,481 |
| | | |
| t=16 w=4 p=10 | **Optimal** | 7,303 |
| t=16 w=4 p=10 | PlainFutexMutex (spin=100) | 11,870 |
| t=16 w=4 p=10 | NIOLock | 16,523 |
| t=16 w=4 p=10 | Stdlib PI | 1,138,754 |
| | | |
| t=64 w=1 p=10 | **Optimal** | 2,193 |
| t=64 w=1 p=10 | PlainFutexMutex (spin=100) | 4,084 |
| t=64 w=1 p=10 | NIOLock | 7,434 |
| t=64 w=1 p=10 | Stdlib PI | 901,775 |

### x86 12c (Intel i5-12500, 6P/12T HT)

| Test | Impl | p50 |
|---|---|---:|
| t=4 w=1 p=10 | **Optimal** | 1,155 |
| t=4 w=1 p=10 | NIOLock | 1,637 |
| t=4 w=1 p=10 | Stdlib PI | 1,715 |
| | | |
| t=16 w=1 p=0 | **Optimal** | 981 |
| t=16 w=1 p=0 | NIOLock | 1,338 |
| t=16 w=1 p=0 | Stdlib PI | 1,469 |
| | | |
| t=16 w=1 p=10 | **Optimal** | 1,202 |
| t=16 w=1 p=10 | NIOLock | 1,651 |
| t=16 w=1 p=10 | Stdlib PI | 1,704 |
| | | |
| t=16 w=1 p=100 | Optimal | 4,506 |
| t=16 w=1 p=100 | Stdlib PI | 4,514 |
| t=16 w=1 p=100 | NIOLock | 4,776 |
| | | |
| t=16 w=4 p=10 | **Optimal** | 2,802 |
| t=16 w=4 p=10 | NIOLock | 3,092 |
| t=16 w=4 p=10 | Stdlib PI | 3,168 |
| | | |
| t=64 w=1 p=10 | **Optimal** | 1,203 |
| t=64 w=1 p=10 | NIOLock | 1,573 |
| t=64 w=1 p=10 | Stdlib PI | 1,753 |

On 12 cores, all close. Optimal 1.1-1.4x faster. No PI cliff.

### x86 44c (Intel Xeon E5-2699 v4, 2-socket NUMA)

| Test | Impl | p50 |
|---|---|---:|
| t=4 w=1 p=10 | **Optimal** | 9,959 |
| t=4 w=1 p=10 | NIOLock | 12,809 |
| t=4 w=1 p=10 | Stdlib PI | 25,334 |
| | | |
| t=16 w=1 p=0 | **Optimal** | 16,751 |
| t=16 w=1 p=0 | NIOLock | 22,089 |
| t=16 w=1 p=0 | Stdlib PI | 629,991 |
| | | |
| t=16 w=1 p=10 | **Optimal** | 20,627 |
| t=16 w=1 p=10 | NIOLock | 22,348 |
| t=16 w=1 p=10 | Stdlib PI | 709,362 |
| | | |
| t=16 w=1 p=100 | **Optimal** | 28,377 |
| t=16 w=1 p=100 | NIOLock | 32,375 |
| t=16 w=1 p=100 | Stdlib PI | 1,139,802 |
| | | |
| t=16 w=4 p=10 | **Optimal** | 39,551 |
| t=16 w=4 p=10 | NIOLock | 66,814 |
| t=16 w=4 p=10 | Stdlib PI | 799,015 |
| | | |
| t=64 w=1 p=10 | **Optimal** | 24,232 |
| t=64 w=1 p=10 | NIOLock | 30,441 |
| t=64 w=1 p=10 | Stdlib PI | 2,085,618 |

On 2-socket NUMA, Optimal 1.1-1.7x faster than NIOLock. Stdlib PI 25-73x slower. At t=64 p=10, Stdlib PI reaches 2 seconds.

### x86 192c (Intel Xeon Platinum 8488C, EC2 c7i.metal-48xl)

| Test | Impl | p50 |
|---|---|---:|
| t=4 w=1 p=10 | NIOLock | 12,222 |
| t=4 w=1 p=10 | PlainFutexMutex (spin=100) | 14,041 |
| t=4 w=1 p=10 | **Optimal** | 15,892 |
| | | |
| t=16 w=1 p=0 | **Optimal** | 22,594 |
| t=16 w=1 p=0 | PlainFutexMutex (spin=100) | 24,347 |
| t=16 w=1 p=0 | NIOLock | 28,623 |
| | | |
| t=16 w=1 p=10 | **Optimal** | 27,181 |
| t=16 w=1 p=10 | NIOLock | 28,672 |
| t=16 w=1 p=10 | PlainFutexMutex (spin=100) | 29,491 |
| | | |
| t=16 w=1 p=100 | PlainFutexMutex (spin=100) | 33,243 |
| t=16 w=1 p=100 | Optimal | 33,882 |
| t=16 w=1 p=100 | NIOLock | 34,013 |
| | | |
| t=16 w=4 p=10 | PlainFutexMutex (spin=100) | 45,842 |
| t=16 w=4 p=10 | **Optimal** | 46,268 |
| t=16 w=4 p=10 | NIOLock | 56,492 |
| | | |
| t=64 w=1 p=10 | **Optimal** | 31,572 |
| t=64 w=1 p=10 | PlainFutexMutex (spin=100) | 33,505 |
| t=64 w=1 p=10 | NIOLock | 34,341 |

On 192c, modest advantages. At t=4 p=10, NIOLock wins (low contention, parking is cheaper). At higher contention, Optimal 1.1-1.3x faster. At p=100, everything converges.

---

## Key findings

1. **Inter-acquire gap reduces all implementations toward convergence.** At pause=100, the unlocked work between acquires dominates - lock strategy barely matters. This is the healthy real-world case.

2. **Optimal advantage is largest at low pause, high tasks.** t=64 w=1 p=10 on aarch64 18c: 3.4x faster. The spinning catches releases in the tight contention window.

3. **work=4 with pause=10 is the "Ordo-realistic" workload** - dictionary lookup under lock plus message processing between acquires. Optimal 1.1-2.3x faster depending on machine.

4. **Stdlib PI does not benefit from inter-acquire gaps on multi-socket machines.** On x86 44c, even pause=100 gives 1,140 ms for Stdlib PI vs 32 ms for NIOLock. The PI-futex kernel handoff cost is per-acquire, not affected by what happens between acquires.
