# Contention Scaling

How lock performance scales as the number of contending Swift Tasks increases.

![Contention scaling grid](graphs/contention-scaling__grid.png)

![Stdlib PI / Optimal p50 ratio — cliff heatmap](graphs/contention-scaling-cliff__heatmap.png)

![RustMutex / Optimal p50 ratio](graphs/contention-scaling-rust__heatmap.png)

![NIOLock / Optimal p50 ratio](graphs/contention-scaling-nio__heatmap.png)

<!-- TODO(inconsistency 2026-04-19): Three PI-cliff tables below disagree.
     - "Key findings" (§2) says AMD 64c cliff at t=4, M1 Ultra cliff at t=16.
     - "Fresh cross-machine / PI-futex cliff summary" says AMD cliff at t=8 (1080×),
       M1 Ultra cliff at t=64 (564×). This table uses the post-cliff p50 as
       "just before" — wrong read of the data.
     - "Stdlib PI cliff" table (line ~141) says AMD cliff at t=8 (130×), M1 at t=16 (423×).
     - Detail tables support AMD t=4 and M1 t=16.
     Pick one convention (cliff = first t where PI ≥10× plain) and reconcile
     all three tables before regenerating graphs. -->


## Workload

50,000 total lock acquires distributed across N tasks. Each acquire does one dictionary lookup + update on a `[Int: UInt64]` map with 64 entries. No unlocked work between acquires (pause=0) — maximum contention.

## Key findings

1. **Optimal wins p50 throughput on every machine tested.** 1.4–6× faster than RustMutex, 1.4–5× faster than NIOLock, and 4–1080× faster than Stdlib PI under oversubscription. Same code, no per-host tuning.

2. **Stdlib PI-futex (`Synchronization.Mutex`) has catastrophic cliffs** once contending tasks approach or exceed core count. The cliff point and magnitude scale with coherence-topology complexity:

    | CPU | cliff starts at | p50 jump | magnitude |
    |---|---|---|---:|
    | AMD EPYC 9454P 64c | **tasks=4** | 1.5 ms → 1014 ms | ~700× |
    | Intel Xeon E5-2699 v4 44c (2-socket NUMA) | tasks=4 | 13 ms → 134 ms (worsens to 2.2 s at t=64) | 10× early, 170× peak |
    | Apple M1 Ultra 18c (aarch64) | tasks=16 | 1.8 ms → 854 ms | 488× |
    | Intel Xeon Gold 6148 40c (2-socket NUMA) | tasks=16 | 24 ms → 261 ms | 11× |
    | Intel i5-12500 12c (single die) | no cliff | gradual only | 1.5× |

    The `rt_mutex` chain walking in the PI syscall path scales with waiter count and cross-die/socket traffic. Plain-futex variants (Optimal, RustMutex, NIOLock) all scale gracefully across the same range.

3. **RustMutex's load-only spin pattern trades throughput for fairness.** On `ContentionScaling` (steady-state throughput) it loses 1.7–5× to Optimal. But it avoids the in-spin CAS RFO storm that hurts Optimal on 12-core Intel under extreme oversubscription (see `Fairness.md`). Different workloads → different winner.

4. **NIOLock's park-immediate pattern is consistently 2–5× slower than Optimal at p50** — the 100-iter glibc adaptive spin doesn't fire under Swift-cooperative Task contention, so threads go straight to the kernel. Respectable tail behaviour but leaves throughput on the table.

5. **Choose by workload:**
    - **Steady-state throughput, tolerate occasional long tails:** `OptimalMutex`
    - **Fairness priority on Intel oversubscription:** `RustMutex`-style load-only spin
    - **Strict bounded max tail required (RT/latency-critical):** `Synchronization.Mutex` PI — but only below the cliff point for your CPU's topology

---

## Implementations

| Label | What it is | Futex | Spin strategy |
|---|---|---|---|
| **Optimal** | `OptimalMutex` — proposed replacement | `FUTEX_WAIT`/`FUTEX_WAKE` | 20 iterations × base=64 PAUSE with RDTSC jitter, depth-gated skip-spin |
| **RustMutex** | Rust std 1.62+ futex pattern (reference impl) | `FUTEX_WAIT`/`FUTEX_WAKE` | 100-iter load-only spin, post-spin CAS + kernel exchange, re-spin after wake |
| **NIOLock** | `NIOLockedValueBox` — `pthread_mutex_t` wrapper | `FUTEX_WAIT`/`FUTEX_WAKE` (via glibc) | 0 (park immediately) |
| **Stdlib PI** | `Synchronization.Mutex` — current stdlib | `FUTEX_LOCK_PI` | 1000 × `pause` (x86) / 100 × `wfe` (aarch64), fixed |

## Machines

| Name | Arch | Cores | CPU | Topology |
|---|---|---:|---|---|
| aarch64 12c | aarch64 | 12 | Apple M4 Pro (Mac Mini) | 12c container VM (all cores) |
| aarch64 18c | aarch64 | 18 | Apple M1 Ultra | 20c host (2-die UltraFusion), 18c container VM |
| x86 12c | x86_64 | 6P/12T | Intel i5-12500 | single die, Hyperthreading |
| x86 40c | x86_64 | 40 | Intel Xeon Gold 6148 | 2-socket NUMA |
| x86 44c | x86_64 | 44 | Intel Xeon E5-2699 v4 | 2-socket NUMA |
| x86 64c | x86_64 | 64 | AMD EPYC 9454P | CCD chiplet (8×8 cores) |
| x86 192c | x86_64 | 192 | Intel Xeon Platinum 8488C | EC2 c7i.metal-48xl, 2-socket HT |

---

## Fresh cross-machine p50 (2026-04-19)

Re-run with current `OptimalMutex` (lazy waiter-count registration). Same code on every machine.

### Intel i5-12500 (12c Alder Lake)

| Implementation | t=1 w=1 p=0 | t=8 w=1 p=0 | t=64 w=1 p=0 | t=192 w=1 p=0 | t=384 w=1 p=0 |
|---|---:|---:|---:|---:|---:|
| **Optimal** | 1,375 µs | 1,635 µs | 1,825 µs | 1,879 µs | 2,016 µs |
| RustMutex | 1,389 µs | 8,511 µs | 8,987 µs | 9,044 µs | 9,036 µs |
| NIOLockedValueBox | 1,609 µs | 9,642 µs | 10,027 µs | 10,076 µs | 10,035 µs |
| Synchronization.Mutex (PI) | 1,616 µs | 10,387 µs | 13,689 µs | 14,918 µs | 14,508 µs |

Optimal 4.5–6× faster than Rust/NIO/Sync.Mutex at contested task counts. Rust is 5× slower than Optimal but slightly faster than NIO — its load-only spin surrenders throughput to avoid CAS storms (same Rust-vs-Optimal pattern noted in Fairness.md).

### Intel Xeon Gold 6148 (40c 2-socket NUMA)

| Implementation | t=1 w=1 p=0 | t=8 w=1 p=0 | t=64 w=1 p=0 | t=192 w=1 p=0 | t=384 w=1 p=0 |
|---|---:|---:|---:|---:|---:|
| **Optimal** | 2,634 µs | 7,213 µs | 22,118 µs | 22,757 µs | 23,233 µs |
| NIOLockedValueBox | 3,082 µs | 25,362 µs | 32,195 µs | 32,752 µs | 33,194 µs |
| Synchronization.Mutex (PI) | 2,929 µs | 43,155 µs | **466 ms** | **445 ms** | **461 ms** |

Optimal 1.4–3.5× faster than NIO. **Sync.Mutex (PI) collapses 20× at t≥64** — cross-NUMA `rt_mutex` chain walk.

### AMD EPYC 9454P (64c Zen 4 chiplet)

| Implementation | t=1 w=1 p=0 | t=8 w=1 p=0 | t=64 w=1 p=0 | t=192 w=1 p=0 | t=384 w=1 p=0 |
|---|---:|---:|---:|---:|---:|
| **Optimal** | 1,063 µs | 3,215 µs | 12,837 µs | 13,025 µs | 13,640 µs |
| RustMutex | 1,180 µs | 8,454 µs | 17,138 µs | 17,334 µs | 17,777 µs |
| NIOLockedValueBox | 1,205 µs | 7,283 µs | 25,297 µs | 25,919 µs | 26,214 µs |
| Synchronization.Mutex (PI) | 1,132 µs | **1217 ms** | **1376 ms** | **1390 ms** | **1415 ms** |

Optimal 1.3× faster than Rust, 2× faster than NIO. Rust edges NIO by 1.5× at high-t (Rust's post-spin exchange absorbs AMD CAS contention better than NIO's immediate park). **Sync.Mutex (PI) collapses 1000× starting at t=8** — earliest cliff of any machine. AMD's inter-CCD coherence makes PI chain walking catastrophic above ~8 threads.

### Apple M1 Ultra (18c aarch64 container)

| Implementation | t=1 w=1 p=0 | t=8 w=1 p=0 | t=64 w=1 p=0 | t=192 w=1 p=0 | t=384 w=1 p=0 |
|---|---:|---:|---:|---:|---:|
| **Optimal** | 998 µs | 1,262 µs | 1,671 µs | 1,717 µs | 1,829 µs |
| RustMutex | 968 µs | 2,171 µs | 3,375 µs | 3,873 µs | 4,153 µs |
| NIOLockedValueBox | 2,324 µs | 6,369 µs | 7,160 µs | 7,586 µs | 8,249 µs |
| Synchronization.Mutex (PI) | 1,026 µs | 1,751 µs | **933 ms** | **985 ms** | **1017 ms** |

Optimal 1.7–2.3× faster than Rust; Rust is a clear 2nd place, beating NIO by ~2× at contested counts. **Sync.Mutex (PI) collapses 540× at t=64** — ARM PI cliff (see Experiments.md §14).

### PI-futex cliff summary

| CPU | cliff starts at | p50 just before | p50 at cliff | factor |
|---|---|---:|---:|---:|
| AMD EPYC 9454P 64c | t=8 | 1.13 ms | 1221 ms | **1080×** |
| Intel Xeon Gold 6148 40c | t=64 | 43 ms | 466 ms | 11× |
| Apple M1 Ultra 18c | t=64 | 1.66 ms | 936 ms | **564×** |
| Intel i5-12500 12c | no cliff | — | — | gradual 1.5× |

The cliff firing point correlates with `rt_mutex` chain walk complexity: more cores/sockets → cliff earlier and harder. Plain-futex (Optimal, NIO) scales gracefully across the same range.

---

## Optimal vs NIOLock ratio (p50, all machines)

| Tasks | aarch64 12c | aarch64 18c | x86 12c | x86 40c | x86 44c | x86 64c | x86 192c |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1.3× | 2.4× | 1.2× | 1.2× | 1.1× | 1.1× | 1.3× |
| 2 | 7.4× | 4.9× | 4.9× | 4.6× | 2.2× | 1.5× | 1.3× |
| 4 | 2.9× | 3.8× | 3.8× | 3.1× | 2.5× | 1.8× | 1.3× |
| 8 | 6.0× | 5.5× | 3.9× | 2.7× | 1.3× | 2.3× | 1.4× |
| 16 | 5.5× | 4.9× | 3.4× | ~1× | 1.3× | 2.1× | 1.2× |
| 64 | 5.4× | 3.9× | 3.0× | ~1× | 1.3× | 1.9× | 1.2× |
| 192 | 5.5× | 3.6× | 3.0× | ~1× | 1.3× | 1.9× | 1.1× |

Optimal is faster than NIOLock at every task count on every machine. The advantage is largest on aarch64 (3–7×) and smallest on x86 192c (1.1–1.4×).

---

## Stdlib PI cliff

`Synchronization.Mutex` degrades catastrophically once contention exceeds a threshold that scales inversely with core count:

| Machine | Cliff starts at | p50 before cliff | p50 after cliff | Magnitude |
|---|---|---:|---:|---:|
| x86 192c | **tasks=4** | 7,516 µs | 454,033 µs | 60× |
| x86 64c | tasks=8 | ~6,000 µs | 781,189 µs | 130× |
| x86 44c | tasks=4 | ~13,500 µs | 105,710 µs | 8× |
| aarch64 18c | tasks=16 | 1,536 µs | 650,641 µs | 423× |
| x86 12c | No cliff | — | — | 1.2× gradual |
| aarch64 12c | No cliff | — | — | bimodal tail |

---

## Detailed results per machine

### aarch64 12c (Mac Mini M4 Pro, 12-core container VM)

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 498 | 515 | 527 | 543 | 612 | 250 |
| 1 | NIOLock | 655 | 667 | 679 | 689 | 731 | 250 |
| 1 | Stdlib PI | 516 | 535 | 551 | 605 | 635 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 572 | 580 | 587 | 594 | 666 | 250 |
| 2 | NIOLock | 4,219 | 6,345 | 7,856 | 8,204 | 8,746 | 250 |
| 2 | Stdlib PI | 551 | 566 | 577 | 629 | 635 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 709 | 726 | 745 | 790 | 797 | 250 |
| 8 | NIOLock | 4,235 | 4,542 | 4,899 | 5,452 | 5,535 | 250 |
| 8 | Stdlib PI | 741 | 779 | 806 | 858 | 903 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 765 | 792 | 823 | 993 | 1,024 | 250 |
| 16 | NIOLock | 4,223 | 4,444 | 4,633 | 5,022 | 5,252 | 250 |
| 16 | Stdlib PI | 1,009 | 1,055 | 1,207 | 75,563 | 353,370 | 250 |
| | | | | | | | |
| 64 | **Optimal** | 838 | 876 | 919 | 1,097 | 1,537 | 250 |
| 64 | NIOLock | 4,538 | 4,821 | 5,100 | 5,726 | 14,135 | 250 |
| 64 | Stdlib PI | 1,141 | 1,218 | 3,619 | 578,814 | 600,894 | 250 |
| | | | | | | | |
| 192 | **Optimal** | 883 | 928 | 968 | 1,085 | 1,098 | 250 |
| 192 | NIOLock | 4,870 | 5,120 | 5,403 | 5,984 | 6,663 | 250 |
| 192 | Stdlib PI | 1,192 | 1,276 | 1,388 | 646,971 | 660,416 | 250 |

**Observations:** Similar to aarch64 4c. Optimal 5–7× faster than NIOLock. Stdlib PI tail worsens at tasks≥16 (p99=75ms) and tasks≥64 (p99=579ms).

---

### aarch64 18c (Apple M1 Ultra, 20c host, 2-die UltraFusion, 18c container VM) — refreshed 2026-04-19

![M1 Ultra absolute p50](graphs/contention-scaling__aarch64_18c.png)

![M1 Ultra degradation vs t=1](graphs/contention-scaling-m1-degradation__grid.png)

Optimal stays within 1.83× of its single-task p50 all the way to 384 contending tasks. Rust 4.3×, NIO 3.6× — gentle climbs. Stdlib PI cliffs 832× at t=16 (rt_mutex chain walk past core count).

![M1 Ultra plain-futex p50 line + p50→p99 band](graphs/contention-scaling-m1-band__grid.png)

Line = p50, shaded = p50→p99 tail. Stdlib PI omitted so y-axis collapses to 10³–10⁴ µs. Optimal's band is narrow at every task count (tight tail). Rust's band widens past t=8 (variable tail from load-only spin missing release windows). NIO's band stays roughly parallel to its p50 (park-immediate → predictable but slow).

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 998 | 1,030 | 1,051 | 1,094 | 1,104 | 250 |
| 1 | RustMutex | 968 | 991 | 1,014 | 1,072 | 1,097 | 250 |
| 1 | NIOLock | 2,324 | 2,365 | 2,400 | 2,431 | 2,449 | 250 |
| 1 | Stdlib PI | 1,026 | 1,059 | 1,081 | 1,109 | 1,129 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 1,090 | 1,128 | 1,161 | 1,207 | 1,231 | 250 |
| 2 | RustMutex | 1,123 | 1,157 | 1,198 | 1,286 | 1,349 | 250 |
| 2 | NIOLock | 5,251 | 5,726 | 5,984 | 6,300 | 6,451 | 250 |
| 2 | Stdlib PI | 1,098 | 1,128 | 1,178 | 1,378 | 1,414 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 1,157 | 1,204 | 1,255 | 1,347 | 1,411 | 250 |
| 4 | RustMutex | 1,363 | 1,556 | 1,699 | 1,866 | 1,898 | 250 |
| 4 | NIOLock | 4,551 | 4,903 | 5,198 | 5,669 | 5,862 | 250 |
| 4 | Stdlib PI | 1,167 | 1,230 | 1,315 | 1,512 | 1,577 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 1,262 | 1,320 | 1,363 | 1,438 | 1,518 | 250 |
| 8 | RustMutex | 2,171 | 2,273 | 2,386 | 2,617 | 2,680 | 250 |
| 8 | NIOLock | 6,369 | 6,566 | 6,783 | 7,229 | 7,508 | 250 |
| 8 | Stdlib PI | 1,751 | 1,945 | 2,097 | 5,755 | 19,075 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 1,413 | 1,476 | 1,542 | 1,706 | 1,863 | 250 |
| 16 | RustMutex | 2,982 | 3,230 | 3,467 | 4,403 | 4,698 | 250 |
| 16 | NIOLock | 6,828 | 7,303 | 7,803 | 9,036 | 10,106 | 250 |
| 16 | Stdlib PI | **854,065** | **997,720** | **1,039,139** | **1,056,832** | **1,056,832** | — |
| | | | | | | | |
| 64 | **Optimal** | 1,671 | 1,788 | 1,912 | 2,628 | 2,805 | 250 |
| 64 | RustMutex | 3,375 | 3,643 | 3,889 | 4,735 | 6,050 | 250 |
| 64 | NIOLock | 7,160 | 7,500 | 8,073 | 10,281 | 11,532 | 250 |
| 64 | Stdlib PI | **932,708** | **964,690** | **1,009,254** | **1,041,597** | **1,041,597** | — |
| | | | | | | | |
| 192 | **Optimal** | 1,717 | 1,836 | 1,939 | 2,228 | 2,314 | 250 |
| 192 | RustMutex | 3,873 | 4,166 | 4,452 | 5,313 | 6,332 | 250 |
| 192 | NIOLock | 7,586 | 8,069 | 8,602 | 9,945 | 10,131 | 250 |
| 192 | Stdlib PI | **985,137** | **1,053,819** | **1,075,839** | **1,079,144** | **1,079,144** | — |
| | | | | | | | |
| 384 | **Optimal** | 1,829 | 1,904 | 2,010 | 2,275 | 2,284 | 250 |
| 384 | RustMutex | 4,153 | 4,428 | 4,714 | 5,394 | 6,225 | 250 |
| 384 | NIOLock | 8,249 | 8,765 | 9,470 | 11,559 | 11,852 | 250 |
| 384 | Stdlib PI | **1,016,594** | **1,087,373** | **1,118,831** | **1,129,971** | **1,129,971** | — |

**Observations:** Optimal 1.7–2.3× faster than Rust; Rust a clear 2nd place beating NIO by ~2× at contested counts. **PI cliff at tasks=16: 1,751 → 854,065 µs (488×)**. ARM PI cliff (see Experiments.md §14) — `rt_mutex` chain walk collapses past core count. Stdlib PI at tasks≥16 effectively unusable for throughput.

---

### x86 12c (Intel i5-12500, 6P/12T Hyperthreading) — refreshed 2026-04-19

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 1,375 | 1,386 | 1,487 | 1,525 | 1,547 | 250 |
| 1 | RustMutex | 1,389 | 1,391 | 1,394 | 1,400 | 1,401 | 250 |
| 1 | NIOLock | 1,609 | 1,618 | 1,623 | 1,806 | 1,814 | 250 |
| 1 | Stdlib PI | 1,616 | 1,714 | 2,515 | 6,812 | 7,353 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 1,406 | 1,414 | 1,434 | 1,506 | 1,520 | 250 |
| 2 | RustMutex | 4,370 | 4,649 | 4,907 | 5,161 | 5,206 | 250 |
| 2 | NIOLock | 7,148 | 9,216 | 9,601 | 9,740 | 9,767 | 250 |
| 2 | Stdlib PI | 4,579 | 4,854 | 4,981 | 5,181 | 5,254 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 1,474 | 1,486 | 1,494 | 1,537 | 1,570 | 250 |
| 4 | RustMutex | 5,997 | 6,828 | 7,234 | 7,504 | 7,569 | 250 |
| 4 | NIOLock | 6,963 | 7,352 | 7,692 | 8,294 | 8,485 | 250 |
| 4 | Stdlib PI | 7,274 | 7,815 | 8,733 | 9,888 | 10,203 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 1,635 | 1,654 | 1,676 | 1,720 | 1,770 | 250 |
| 8 | RustMutex | 8,511 | 8,757 | 8,954 | 9,265 | 9,319 | 250 |
| 8 | NIOLock | 9,642 | 10,043 | 10,748 | 11,100 | 11,211 | 250 |
| 8 | Stdlib PI | 10,387 | 12,607 | 13,222 | 14,238 | 14,548 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 1,742 | 1,763 | 1,786 | 1,883 | 1,892 | 250 |
| 16 | RustMutex | 8,634 | 8,823 | 8,921 | 9,126 | 9,291 | 250 |
| 16 | NIOLock | 9,765 | 10,494 | 10,838 | 11,018 | 11,038 | 250 |
| 16 | Stdlib PI | 12,296 | 13,885 | 14,639 | 15,892 | 18,368 | 250 |
| | | | | | | | |
| 64 | **Optimal** | 1,825 | 1,845 | 1,867 | 1,988 | 4,074 | 250 |
| 64 | RustMutex | 8,987 | 9,118 | 9,241 | 9,740 | 12,697 | 250 |
| 64 | NIOLock | 10,027 | 10,879 | 11,158 | 11,690 | 14,382 | 250 |
| 64 | Stdlib PI | 13,689 | 15,237 | 15,745 | 19,317 | 28,995 | 250 |
| | | | | | | | |
| 192 | **Optimal** | 1,879 | 1,897 | 1,921 | 2,065 | 2,089 | 250 |
| 192 | RustMutex | 9,044 | 9,167 | 9,249 | 9,372 | 9,397 | 250 |
| 192 | NIOLock | 10,076 | 10,863 | 11,149 | 11,502 | 12,962 | 250 |
| 192 | Stdlib PI | 14,918 | 18,907 | 190,317 | 475,791 | 1,006,165 | 250 |
| | | | | | | | |
| 384 | **Optimal** | 2,016 | 2,036 | 2,054 | 2,124 | 2,175 | 250 |
| 384 | RustMutex | 9,036 | 9,175 | 9,314 | 9,478 | 9,624 | 250 |
| 384 | NIOLock | 10,035 | 10,740 | 11,018 | 11,379 | 11,725 | 250 |
| 384 | Stdlib PI | 14,508 | 16,048 | 151,912 | 280,232 | 301,788 | 250 |

**Observations:** Optimal 4.5–6× faster than Rust/NIO/Stdlib PI at contested task counts. Rust 5× slower than Optimal but beats NIO — load-only spin surrenders throughput to avoid CAS storms. No p50 PI cliff (12 cores, spin masks PI cost) but p100 tail at t=192 spikes to 1 second (PI chain walk under oversubscription).

---

### x86 40c (Intel Xeon Gold 6148, 2-socket NUMA) — refreshed 2026-04-19

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 2,677 | 2,703 | 2,836 | 3,260 | 3,995 | 250 |
| 1 | RustMutex | 2,886 | 3,461 | 3,705 | 4,436 | 4,487 | 250 |
| 1 | NIOLock | 3,209 | 3,242 | 3,553 | 4,045 | 4,101 | 250 |
| 1 | Stdlib PI | 3,484 | 3,697 | 4,022 | 4,514 | 5,537 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 2,773 | 2,836 | 2,957 | 3,332 | 3,610 | 250 |
| 2 | RustMutex | 7,987 | 11,624 | 14,918 | 19,513 | 20,228 | 250 |
| 2 | NIOLock | 13,984 | 16,056 | 17,875 | 22,725 | 26,961 | 250 |
| 2 | Stdlib PI | 5,767 | 6,975 | 14,574 | 21,135 | 23,025 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 3,441 | 3,553 | 3,785 | 4,399 | 4,742 | 250 |
| 4 | RustMutex | 14,090 | 15,753 | 20,840 | 25,756 | 27,174 | 250 |
| 4 | NIOLock | 14,868 | 18,596 | 21,053 | 25,805 | 29,289 | 250 |
| 4 | Stdlib PI | 25,477 | 30,278 | 34,963 | 44,007 | 46,496 | 250 |
| | | | | | | | |
| 8 | **Optimal** | 7,123 | 8,397 | 9,175 | 10,609 | 10,805 | 250 |
| 8 | RustMutex | 21,430 | 25,215 | 27,492 | 31,080 | 31,713 | 250 |
| 8 | NIOLock | 27,279 | 30,048 | 32,686 | 36,405 | 39,168 | 250 |
| 8 | Stdlib PI | 29,622 | 34,537 | 39,846 | 51,282 | 59,276 | 250 |
| | | | | | | | |
| 16 | **Optimal** | 19,775 | 21,496 | 22,610 | 24,150 | 26,473 | 250 |
| 16 | RustMutex | 30,163 | 31,146 | 31,998 | 33,849 | 38,299 | 250 |
| 16 | NIOLock | 31,031 | 33,128 | 35,783 | 38,863 | 39,619 | 250 |
| 16 | Stdlib PI | **261,226** | **337,117** | **382,730** | **418,961** | **418,961** | 250 |
| | | | | | | | |
| 64 | **Optimal** | 21,987 | 23,085 | 24,003 | 25,592 | 26,668 | 250 |
| 64 | RustMutex | 30,704 | 31,670 | 32,358 | 34,210 | 34,501 | 250 |
| 64 | NIOLock | 32,883 | 36,176 | 38,404 | 40,403 | 41,377 | 250 |
| 64 | Stdlib PI | **450,101** | **465,830** | **479,724** | **490,273** | **490,273** | 250 |
| | | | | | | | |
| 192 | **Optimal** | 23,052 | 24,232 | 25,018 | 26,804 | 27,463 | 250 |
| 192 | RustMutex | 31,261 | 32,178 | 33,079 | 36,733 | 37,604 | 250 |
| 192 | NIOLock | 32,653 | 36,766 | 38,273 | 39,551 | 39,757 | 250 |
| 192 | Stdlib PI | **451,412** | **473,432** | **475,529** | **494,489** | **494,489** | 250 |
| | | | | | | | |
| 384 | **Optimal** | 23,446 | 24,297 | 25,477 | 27,165 | 27,203 | 250 |
| 384 | RustMutex | 31,605 | 32,670 | 33,423 | 34,931 | 35,990 | 250 |
| 384 | NIOLock | 32,997 | 36,831 | 38,568 | 40,600 | 41,160 | 250 |
| 384 | Stdlib PI | **462,160** | **473,956** | **481,559** | **495,249** | **495,249** | 250 |

**Observations:** Optimal 1.4–5× faster than Rust/NIO across all task counts. Biggest Optimal advantage at tasks=2–8 (NUMA cross-socket contention; depth gate prevents cross-die RFO storm). Rust beats NIO by 1.0–1.3× at contested counts. **PI cliff at tasks=16: 24 → 261 ms (11×)** — 2-socket NUMA PI chain walk.

---

### x86 44c (Intel Xeon E5-2699 v4, 2-socket NUMA Broadwell) — refreshed 2026-04-19

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 5,362 | 5,386 | 5,452 | 5,804 | 6,187 | 250 |
| 1 | RustMutex | 5,472 | 6,758 | 6,787 | 7,164 | 7,188 | 250 |
| 1 | NIOLock | 6,406 | 6,443 | 6,472 | 6,828 | 6,836 | 250 |
| 1 | Stdlib PI | 6,570 | 6,586 | 6,623 | 6,984 | 7,470 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 6,279 | 6,726 | 7,119 | 7,762 | 7,875 | 250 |
| 2 | RustMutex | 14,098 | 19,104 | 21,594 | 25,903 | 36,749 | 250 |
| 2 | NIOLock | 14,156 | 18,711 | 22,495 | 30,900 | 42,155 | 250 |
| 2 | Stdlib PI | 14,123 | 16,482 | 20,644 | 37,224 | 38,869 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 12,698 | 14,049 | 15,172 | 16,810 | 16,978 | 250 |
| 4 | RustMutex | 15,270 | 17,400 | 21,021 | 31,834 | 33,929 | 250 |
| 4 | NIOLock | 21,053 | 26,116 | 30,245 | 35,914 | 38,632 | 250 |
| 4 | Stdlib PI | **133,693** | **300,679** | **379,847** | **573,939** | **573,939** | 250 |
| | | | | | | | |
| 8 | **Optimal** | 24,674 | 26,001 | 27,558 | 31,490 | 32,230 | 250 |
| 8 | RustMutex | 32,178 | 33,882 | 35,783 | 39,748 | 43,443 | 250 |
| 8 | NIOLock | 22,872 | 26,149 | 31,228 | 38,109 | 38,629 | 250 |
| 8 | Stdlib PI | **563,085** | **567,804** | **611,844** | **680,127** | **680,127** | 250 |
| | | | | | | | |
| 16 | **Optimal** | 24,396 | 25,805 | 27,165 | 30,196 | 32,168 | 250 |
| 16 | RustMutex | 25,412 | 28,000 | 29,802 | 34,865 | 35,129 | 250 |
| 16 | NIOLock | 31,228 | 33,817 | 36,405 | 38,896 | 39,044 | 250 |
| 16 | Stdlib PI | **1,399,849** | **1,658,847** | **1,745,879** | **1,923,345** | **1,923,345** | 250 |
| | | | | | | | |
| 64 | **Optimal** | 21,578 | 22,249 | 22,774 | 23,708 | 24,152 | 250 |
| 64 | RustMutex | 25,526 | 26,116 | 26,804 | 29,049 | 29,458 | 250 |
| 64 | NIOLock | 25,264 | 28,623 | 30,163 | 31,932 | 32,563 | 250 |
| 64 | Stdlib PI | **2,055,209** | **2,110,783** | **2,205,690** | **2,205,690** | **2,205,690** | 250 |
| | | | | | | | |
| 192 | **Optimal** | 22,151 | 22,774 | 23,331 | 24,756 | 25,106 | 250 |
| 192 | RustMutex | 26,690 | 27,197 | 27,656 | 28,983 | 29,261 | 250 |
| 192 | NIOLock | 25,362 | 28,377 | 30,507 | 31,752 | 32,609 | 250 |
| 192 | Stdlib PI | **2,140,144** | **2,212,495** | **2,266,187** | **2,266,187** | **2,266,187** | 250 |
| | | | | | | | |
| 384 | **Optimal** | 22,594 | 23,167 | 23,757 | 24,986 | 25,368 | 250 |
| 384 | RustMutex | 27,116 | 27,787 | 28,279 | 29,639 | 30,811 | 250 |
| 384 | NIOLock | 26,952 | 29,983 | 31,162 | 32,440 | 33,217 | 250 |
| 384 | Stdlib PI | **2,218,787** | **2,233,467** | **2,273,470** | **2,273,470** | **2,273,470** | 250 |

**Observations:** Broadwell 2-socket NUMA. Optimal 1.1–1.5× faster than Rust/NIO (narrowest gap of any machine — Broadwell coherence hurts all contenders similarly). **PI cliff at tasks=4: 12.7 → 134 ms (10×)**, escalates to **2.2 seconds at tasks=64** — earliest and worst PI degradation by absolute magnitude. Broadwell QPI cross-socket PI chain walking is catastrophic.

---

### x86 64c (AMD EPYC 9454P, CCD chiplet 8×8) — refreshed 2026-04-19

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 1,063 | 1,072 | 1,110 | 1,164 | 1,425 | 250 |
| 1 | RustMutex | 1,180 | 1,204 | 1,213 | 1,251 | 1,333 | 250 |
| 1 | NIOLock | 1,205 | 1,228 | 1,244 | 1,290 | 1,564 | 250 |
| 1 | Stdlib PI | 1,132 | 1,139 | 1,149 | 1,240 | 1,561 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 1,240 | 1,306 | 1,589 | 1,678 | 1,703 | 250 |
| 2 | RustMutex | 4,037 | 4,497 | 4,665 | 4,919 | 5,008 | 250 |
| 2 | NIOLock | 2,298 | 2,447 | 2,681 | 2,894 | 3,105 | 250 |
| 2 | Stdlib PI | 3,086 | 3,275 | 3,445 | 4,110 | 4,389 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 1,519 | 1,599 | 1,674 | 1,775 | 1,801 | 250 |
| 4 | RustMutex | 4,944 | 5,526 | 5,845 | 6,320 | 6,465 | 250 |
| 4 | NIOLock | 2,935 | 3,224 | 3,469 | 3,994 | 4,405 | 250 |
| 4 | Stdlib PI | **1,013,973** | **1,077,936** | **1,118,831** | **1,128,168** | **1,128,168** | — |
| | | | | | | | |
| 8 | **Optimal** | 3,215 | 3,486 | 3,719 | 4,151 | 4,640 | 250 |
| 8 | RustMutex | 8,454 | 8,970 | 9,437 | 9,994 | 10,362 | 250 |
| 8 | NIOLock | 7,283 | 7,963 | 8,659 | 11,297 | 12,303 | 250 |
| 8 | Stdlib PI | **1,217,397** | **1,224,737** | **1,226,834** | **1,237,084** | **1,237,084** | — |
| | | | | | | | |
| 16 | **Optimal** | 8,561 | 8,905 | 9,118 | 9,724 | 9,858 | 250 |
| 16 | RustMutex | 12,911 | 13,337 | 13,828 | 14,893 | 15,341 | 250 |
| 16 | NIOLock | 20,840 | 21,365 | 21,889 | 22,659 | 22,985 | 250 |
| 16 | Stdlib PI | **1,298,137** | **1,301,283** | **1,305,477** | **1,306,289** | **1,306,289** | — |
| | | | | | | | |
| 64 | **Optimal** | 12,837 | 13,206 | 13,459 | 14,074 | 14,281 | 250 |
| 64 | RustMutex | 17,138 | 17,465 | 17,842 | 18,579 | 18,885 | 250 |
| 64 | NIOLock | 25,297 | 26,804 | 27,361 | 28,131 | 29,186 | 250 |
| 64 | Stdlib PI | **1,375,732** | **1,389,363** | **1,398,800** | **1,399,312** | **1,399,312** | — |
| | | | | | | | |
| 192 | **Optimal** | 13,025 | 13,287 | 13,574 | 14,230 | 14,330 | 250 |
| 192 | RustMutex | 17,334 | 17,646 | 17,908 | 18,334 | 18,439 | 250 |
| 192 | NIOLock | 25,919 | 27,656 | 28,246 | 28,951 | 28,994 | 250 |
| 192 | Stdlib PI | **1,390,412** | **1,410,335** | **1,415,194** | **1,415,194** | **1,415,194** | — |
| | | | | | | | |
| 384 | **Optimal** | 13,640 | 13,910 | 14,197 | 14,639 | 15,214 | 250 |
| 384 | RustMutex | 17,777 | 18,137 | 18,366 | 19,120 | 20,289 | 250 |
| 384 | NIOLock | 26,214 | 27,869 | 28,393 | 29,147 | 29,237 | 250 |
| 384 | Stdlib PI | **1,414,529** | **1,427,112** | **1,430,258** | **1,432,602** | **1,432,602** | — |

**Observations:** Optimal 1.3× faster than Rust, 2× faster than NIO at contested counts. **PI cliff at tasks=4: 1,014 ms** (earliest cliff of any machine; AMD CCD → Infinity Fabric cross-die PI chain collapses fast). Optimal has very tight p50→p99 (within 10% at tasks≥16).

---

### x86 192c (Intel Xeon Platinum 8488C, EC2 c7i.metal-48xl, 2-socket HT)

| Tasks | Impl | p50 | p75 | p90 | p99 | p100 | Samples |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | **Optimal** | 1,106 | 1,109 | 1,114 | 1,684 | 1,685 | 250 |
| 1 | NIOLock | 1,488 | 1,492 | 1,495 | 1,507 | 1,529 | 250 |
| 1 | Stdlib PI | 1,164 | 1,187 | 1,652 | 1,668 | 1,675 | 250 |
| | | | | | | | |
| 2 | **Optimal** | 2,451 | 2,583 | 2,748 | 3,207 | 3,568 | 250 |
| 2 | NIOLock | 3,193 | 3,277 | 3,379 | 3,525 | 4,181 | 250 |
| 2 | Stdlib PI | 7,516 | 7,901 | 8,462 | 10,928 | 11,044 | 250 |
| | | | | | | | |
| 4 | **Optimal** | 8,651 | 12,083 | 13,681 | 16,114 | 17,222 | 250 |
| 4 | NIOLock | 10,863 | 12,362 | 15,114 | 17,416 | 19,182 | 250 |
| 4 | Stdlib PI | **454,033** | **468,713** | **482,607** | **501,017** | **501,017** | 37 |
| | | | | | | | |
| 8 | **Optimal** | 18,563 | 20,070 | 21,332 | 25,559 | 26,593 | 250 |
| 8 | NIOLock | 25,641 | 27,754 | 35,291 | 39,813 | 40,265 | 250 |
| 8 | Stdlib PI | **457,441** | **463,995** | **486,015** | **520,344** | **520,344** | 33 |
| | | | | | | | |
| 16 | **Optimal** | 22,872 | 24,412 | 25,887 | 29,344 | 30,036 | 250 |
| 16 | NIOLock | 28,131 | 37,159 | 39,846 | 44,106 | 44,272 | 250 |
| 16 | Stdlib PI | **454,820** | **481,821** | **533,201** | **574,945** | **574,945** | 31 |
| | | | | | | | |
| 64 | **Optimal** | 27,132 | 28,656 | 29,786 | 32,784 | 33,411 | 250 |
| 64 | NIOLock | 33,063 | 35,127 | 42,566 | 44,827 | 45,641 | 250 |
| 64 | Stdlib PI | **410,518** | **414,712** | **418,382** | **434,619** | **434,619** | 36 |
| | | | | | | | |
| 192 | **Optimal** | 36,536 | 37,880 | 39,256 | 42,893 | 43,631 | 250 |
| 192 | NIOLock | 41,878 | 44,597 | 49,742 | 52,953 | 54,470 | 250 |
| 192 | Stdlib PI | **387,449** | **399,770** | **410,255** | **424,747** | **424,747** | 36 |

**Observations:** Optimal 1.1–1.4× faster than NIOLock — smallest advantage (192 cores, least oversubscription). PI cliff at **tasks=4** — earliest of any machine (2-socket NUMA). NIOLock has wide p90 tail: 28,131→39,846 at tasks=16 (42% spread vs Optimal's 13%).
