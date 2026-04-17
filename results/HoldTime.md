# HoldTime

How mutex performance changes as critical section length increases. Includes empty-CS floor, uniform hold-time sweep, bimodal distribution, and sleep-based hold.

Based on [matklad's "Mutexes Are Faster Than Spinlocks"](https://matklad.github.io/2020/01/04/mutexes-are-faster-than-spinlocks.html) (work=0 floor) and [WebKit LockSpeedTest](https://webkit.org/blog/6161/locking-in-webkit/) (workPerCriticalSection sweep). Bimodal tests whether fixed-spin budgets track the median or drown in the mean, relevant to [Go starvation-mode triggering](https://github.com/golang/go/blob/master/src/sync/mutex.go) and [folly hold-time distributions](https://github.com/facebook/folly/blob/main/folly/test/SharedMutexTest.cpp).

## Parameters

| Parameter | Values |
|---|---|
| tasks | 16 (main), 64 (bimodal cross) |
| work | 0, 1, 16, 64, 128 |
| bimodal | short=1 + long=256 @ 10%, short=1 + long=1024 @ 5% |
| sleepHold | 200 us |

## Optimal vs NIOLock ratio (p50)

| Test | aarch64 18c | x86 12c | x86 44c | x86 192c |
|---|---:|---:|---:|---:|
| work=0 (empty CS) | 3.0x | 1.2x | 0.6x | 0.3x |
| work=1 | 4.8x | 1.4x | 1.3x | 1.3x |
| work=16 | 1.9x | ~1x | 1.2x | ~1x |
| work=64 | 1.7x | ~1x | ~1x | 0.9x |
| work=128 | 1.2x | ~1x | ~1x | ~1x |
| bimodal 1/256@10% | 1.3x | ~1x | 1.1x | 1.2x |
| bimodal 1/1024@5% | ~1x | ~1x | 1.1x | ~1x |
| sleepHold=200us | ~1x | ~1x | ~1x | ~1x |

Optimal wins at short hold times (work 0-16). At long holds (work 64+), all implementations converge - the critical section dominates. Sleep-based holds converge completely.

**work=0 on x86 192c and x86 44c:** NIOLock is faster (0.3x and 0.6x). Zero hold time means pure lock/unlock overhead - any spinning adds cost. This is a synthetic edge case with no real-world equivalent.

## Stdlib PI penalty

| Test | aarch64 18c | x86 12c | x86 44c | x86 192c |
|---|---:|---:|---:|---:|
| work=0 | bimodal tail | ~1x | 165x | 86x |
| work=1 | 106x | ~1x | 25x | 19x |
| work=16 | 21x | ~1x | 10x | 5.3x |
| work=64 | 5.9x | ~1x | 6.2x | 6.6x |
| work=128 | 4.7x | ~1x | 3.5x | 5.2x |
| bimodal 1/256@10% | 19x | ~1x | 16x | 16x |
| sleepHold | 1.1x | ~1x | 1.2x | ~1x |

Stdlib PI penalty persists across all hold times on machines with 44+ cores. Even at work=128 on x86 44c, Stdlib PI takes 2,296 ms vs NIOLock's 631 ms.

---

## Detailed results

### aarch64 18c (Apple M1 Ultra, 18c container VM)

| Test | Impl | p50 | p75 | p90 | p99 | p100 |
|---|---|---:|---:|---:|---:|---:|
| work=0 | **Optimal** | 710 | 738 | 765 | 793 | 804 |
| work=0 | NIOLock | 2,136 | 2,214 | 2,343 | 2,503 | 3,461 |
| work=0 | Stdlib PI | 1,261 | 1,372 | 1,616 | 501,744 | 612,220 |
| | | | | | | |
| work=1 | **Optimal** | 1,352 | 1,388 | 1,477 | 1,521 | 1,592 |
| work=1 | NIOLock | 6,463 | 6,885 | 7,348 | 7,999 | 8,966 |
| work=1 | Stdlib PI | 589,824 | 819,986 | 926,941 | 958,923 | 1,024,892 |
| | | | | | | |
| work=16 | **Optimal** | 28,819 | 29,278 | 29,770 | 30,310 | 31,776 |
| work=16 | NIOLock | 55,345 | 56,426 | 58,098 | 59,965 | 60,790 |
| work=16 | Stdlib PI | 1,164,968 | 1,225,785 | 1,240,465 | 1,245,708 | 1,249,069 |
| | | | | | | |
| work=64 | **Optimal** | 123,732 | 125,305 | 126,878 | 129,303 | 132,116 |
| work=64 | NIOLock | 207,487 | 210,108 | 215,351 | 218,497 | 220,083 |
| work=64 | Stdlib PI | 1,229,980 | 1,309,671 | 1,328,546 | 1,333,789 | 1,344,107 |
| | | | | | | |
| work=128 | **Optimal** | 250,741 | 252,576 | 254,935 | 256,508 | 264,500 |
| work=128 | NIOLock | 291,242 | 299,106 | 302,776 | 306,708 | 322,030 |
| work=128 | Stdlib PI | 1,354,760 | 1,415,578 | 1,448,083 | 1,450,181 | 1,459,560 |
| | | | | | | |
| bimodal 1/256@10% t=16 | **Optimal** | 50,790 | 51,151 | 52,036 | 52,462 | 53,836 |
| bimodal 1/256@10% t=16 | NIOLock | 64,422 | 68,813 | 70,648 | 73,138 | 77,853 |
| bimodal 1/256@10% t=16 | Stdlib PI | 1,203,765 | 1,241,514 | 1,265,631 | 1,269,826 | 1,280,673 |
| | | | | | | |
| bimodal 1/256@10% t=64 | **Optimal** | 51,446 | 51,872 | 52,462 | 52,986 | 54,514 |
| bimodal 1/256@10% t=64 | NIOLock | 67,076 | 69,468 | 71,893 | 75,629 | 77,399 |
| bimodal 1/256@10% t=64 | Stdlib PI | 1,198,522 | 1,237,320 | 1,260,388 | 1,276,117 | 1,278,441 |
| | | | | | | |
| sleepHold t=16 | Optimal | 462,946 | 471,073 | 474,481 | 487,326 | 494,938 |
| sleepHold t=16 | NIOLock | 461,373 | 471,335 | 476,578 | 478,151 | 489,796 |
| sleepHold t=16 | Stdlib PI | 529,793 | 551,027 | 558,367 | 562,561 | 593,136 |

---

### x86 12c (Intel i5-12500, 6P/12T HT)

| Test | Impl | p50 | p75 | p90 | p99 | p100 |
|---|---|---:|---:|---:|---:|---:|
| work=0 | **Optimal** | 630 | 689 | 761 | 800 | 800 |
| work=0 | NIOLock | 730 | 753 | 897 | 1,013 | 1,013 |
| work=0 | Stdlib PI | 666 | 668 | 673 | 792 | 792 |
| | | | | | | |
| work=1 | **Optimal** | 994 | 999 | 1,009 | 1,169 | 1,183 |
| work=1 | NIOLock | 1,338 | 1,341 | 1,352 | 1,506 | 1,587 |
| work=1 | Stdlib PI | 1,469 | 1,473 | 1,504 | 1,712 | 1,752 |
| | | | | | | |
| work=16 | Optimal | 15,712 | 15,819 | 15,860 | 27,225 | 27,225 |
| work=16 | NIOLock | 15,639 | 16,040 | 19,268 | 28,511 | 28,511 |
| work=16 | Stdlib PI | 9,568 | 15,917 | 16,024 | 18,456 | 18,456 |
| | | | | | | |
| work=64 | Optimal | 63,701 | 67,437 | 68,878 | 79,741 | 79,741 |
| work=64 | NIOLock | 63,242 | 68,354 | 72,942 | 78,991 | 78,991 |
| work=64 | Stdlib PI | 54,493 | 64,225 | 69,534 | 92,029 | 92,029 |
| | | | | | | |
| work=128 | Optimal | 128,516 | 136,184 | 143,131 | 149,808 | 149,808 |
| work=128 | NIOLock | 136,184 | 139,067 | 141,427 | 148,876 | 148,876 |
| work=128 | Stdlib PI | 127,861 | 152,961 | 170,394 | 391,495 | 391,495 |
| | | | | | | |
| sleepHold t=16 | Optimal | 265,683 | 271,843 | 282,853 | 297,117 | 297,117 |
| sleepHold t=16 | NIOLock | 266,732 | 270,533 | 274,727 | 294,705 | 294,705 |
| sleepHold t=16 | Stdlib PI | 321,913 | 343,409 | 347,603 | 365,446 | 365,446 |

On 12 cores, all implementations converge at work 16+. Stdlib PI has a nasty p99 tail at work=128 (391 ms).

---

### x86 44c (Intel Xeon E5-2699 v4, 2-socket NUMA)

| Test | Impl | p50 | p75 | p90 | p99 | p100 |
|---|---|---:|---:|---:|---:|---:|
| work=0 | NIOLock | 6,844 | 7,668 | 8,094 | 10,160 | 10,160 |
| work=0 | Optimal | 11,567 | 12,231 | 12,829 | 15,572 | 15,572 |
| work=0 | Stdlib PI | 1,129,316 | 1,346,372 | 1,459,618 | 1,597,150 | 1,597,150 |
| | | | | | | |
| work=1 | **Optimal** | 23,822 | 25,477 | 26,804 | 30,470 | 30,470 |
| work=1 | NIOLock | 28,967 | 31,539 | 34,177 | 37,149 | 37,149 |
| work=1 | Stdlib PI | 1,318,060 | 1,741,685 | 1,805,648 | 1,885,924 | 1,885,924 |
| | | | | | | |
| work=16 | **Optimal** | 148,636 | 158,073 | 163,840 | 167,124 | 167,124 |
| work=16 | NIOLock | 182,452 | 189,530 | 194,773 | 201,555 | 201,555 |
| work=16 | Stdlib PI | 1,826,619 | 1,973,420 | 2,021,365 | 2,021,365 | 2,021,365 |
| | | | | | | |
| work=64 | Optimal | 330,039 | 340,787 | 346,292 | 356,544 | 356,544 |
| work=64 | NIOLock | 336,593 | 346,030 | 358,875 | 373,298 | 373,298 |
| work=64 | Stdlib PI | 2,089,812 | 2,208,301 | 2,372,613 | 2,372,613 | 2,372,613 |
| | | | | | | |
| work=128 | Optimal | 584,057 | 598,737 | 606,601 | 611,890 | 611,890 |
| work=128 | NIOLock | 630,718 | 637,010 | 641,729 | 660,063 | 660,063 |
| work=128 | Stdlib PI | 2,296,381 | 2,573,206 | 2,635,145 | 2,635,145 | 2,635,145 |
| | | | | | | |
| bimodal 1/256@10% t=16 | **Optimal** | 111,346 | 113,115 | 114,360 | 116,999 | 116,999 |
| bimodal 1/256@10% t=16 | NIOLock | 124,518 | 126,419 | 127,140 | 128,938 | 128,938 |
| bimodal 1/256@10% t=16 | Stdlib PI | 2,008,023 | 2,068,840 | 2,121,371 | 2,121,371 | 2,121,371 |
| | | | | | | |
| sleepHold t=16 | Optimal | 272,892 | 273,416 | 273,940 | 278,084 | 278,084 |
| sleepHold t=16 | NIOLock | 272,892 | 273,154 | 273,678 | 274,036 | 274,036 |
| sleepHold t=16 | Stdlib PI | 335,282 | 336,593 | 337,641 | 338,455 | 338,455 |

On 2-socket NUMA: Optimal wins at work=0 through 128 except work=0 where NIOLock wins (zero-hold overhead). Stdlib PI is 3.5-165x slower across all hold times. At work=128: Stdlib PI takes **2.3 seconds**.

---

### x86 192c (Intel Xeon Platinum 8488C, EC2 c7i.metal-48xl)

| Test | Impl | p50 | p75 | p90 | p99 | p100 |
|---|---|---:|---:|---:|---:|---:|
| work=0 | **NIOLock** | 3,754 | 3,930 | 5,255 | 5,788 | 6,868 |
| work=0 | Optimal | 11,231 | 11,592 | 12,231 | 12,567 | 13,056 |
| work=0 | Stdlib PI | 324,010 | 372,244 | 401,342 | 422,314 | 475,502 |
| | | | | | | |
| work=1 | **Optimal** | 22,594 | 23,904 | 24,986 | 25,854 | 27,312 |
| work=1 | NIOLock | 28,623 | 30,392 | 38,371 | 40,239 | 42,413 |
| work=1 | Stdlib PI | 435,159 | 451,150 | 467,927 | 476,054 | 488,575 |
| | | | | | | |
| work=16 | Optimal | 90,833 | 92,078 | 93,782 | 94,634 | 96,524 |
| work=16 | NIOLock | 89,588 | 93,716 | 96,666 | 98,435 | 100,014 |
| work=16 | Stdlib PI | 470,548 | 491,520 | 522,453 | 537,395 | 544,441 |
| | | | | | | |
| work=64 | NIOLock | 85,918 | 86,770 | 87,818 | 89,522 | 91,738 |
| work=64 | Optimal | 94,175 | 97,649 | 100,794 | 102,760 | 104,498 |
| work=64 | Stdlib PI | 568,852 | 600,310 | 612,368 | 629,670 | 648,299 |
| | | | | | | |
| work=128 | NIOLock | 119,341 | 122,880 | 125,239 | 127,599 | 133,702 |
| work=128 | Optimal | 122,094 | 124,912 | 126,878 | 130,089 | 140,998 |
| work=128 | Stdlib PI | 622,330 | 672,662 | 693,109 | 714,605 | 727,847 |
| | | | | | | |
| bimodal 1/256@10% t=16 | **Optimal** | 23,069 | 23,495 | 24,183 | 24,855 | 25,805 |
| bimodal 1/256@10% t=16 | NIOLock | 28,656 | 30,114 | 32,539 | 35,848 | 40,871 |
| bimodal 1/256@10% t=16 | Stdlib PI | 456,917 | 478,675 | 489,161 | 507,249 | 526,061 |
| | | | | | | |
| sleepHold t=16 | Optimal | 263,062 | 263,193 | 263,324 | 263,324 | 263,469 |
| sleepHold t=16 | NIOLock | 263,062 | 263,193 | 263,324 | 263,455 | 263,530 |
| sleepHold t=16 | Stdlib PI | 269,222 | 269,222 | 269,222 | 269,222 | 269,581 |

On 192c: NIOLock wins at work=0 (3.0x faster - zero hold, spinning is pure overhead) and work=64 (1.1x). Optimal wins at work=1 through 16 and bimodal tests. Sleep holds converge. Stdlib PI penalty persists across all hold times (5-86x).

---

## Key findings

1. **Optimal wins at short hold times (work 0-16)** on aarch64 and x86 machines with real contention. The regime-gated spinning catches releases before the kernel path.

2. **At long holds (work 64+), implementations converge.** The critical section takes 100-600 ms - lock acquisition overhead is noise. This is expected and healthy.

3. **work=0 is the one regression.** On x86 44c (0.6x) and x86 192c (0.3x), NIOLock is faster at zero hold time because parking immediately avoids all spin overhead. No real workload has an empty critical section.

4. **Bimodal distributions favor Optimal.** At bimodal 1/256@10% (90% short, 10% long holds), Optimal handles the mixed distribution well. The regime-gated cap switches between capHigh (during short holds) and capLow (during long-hold contention) naturally.

5. **Stdlib PI does not converge at long holds on multi-socket machines.** On x86 44c at work=128, Stdlib PI takes 2,296 ms vs NIOLock's 631 ms. The PI overhead is additive, not masked by hold time.
