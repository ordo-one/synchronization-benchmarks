# Cache Levels

How mutex performance varies when the protected data spans different cache hierarchy levels — from L1 to DRAM.

## Workload

16 contending Tasks, each acquiring the lock and performing 8 random-key map updates. The map capacity (working set) varies to push the critical section through L1, L2, L3, and into DRAM. Random keys defeat the hardware prefetcher — each access inside the critical section is a potential cache miss.

| Parameter | Values | Expected cache level |
|---|---|---|
| ws=64 | 64 entries (~2 KB) | L1 |
| ws=1024 | 1,024 entries (~32 KB) | L2 |
| ws=16384 | 16,384 entries (~512 KB) | L2/L3 boundary |
| ws=262144 | 262,144 entries (~8 MB) | L3 |
| ws=1048576 | 1,048,576 entries (~32 MB) | DRAM |

All tests: tasks=16, work=8, pause=0.

## Key findings

1. **Cache-level spread is narrow for plain-futex variants** — ws=64 → ws=1048576 changes Optimal p50 by only 1.5–2.5× across all CPUs. Lock overhead dominates over CS-internal cache misses once CS is non-trivial.

2. **PI-futex cliff is cache-level-independent.** AMD Zen 4 Sync.Mutex stays at 1.36–1.39s across all 5 cache levels (variance within 2%). Chain-walk cost is kernel-side; working-set size doesn't shift it. Same pattern on Broadwell 44c NUMA (1.42–1.88s).

3. **RustMutex ties or slightly beats Optimal on Intel Alder Lake and Skylake NUMA.** Alder Lake ws=1MB: Rust 35.5k vs Optimal 53k (34% faster). Skylake 40c NUMA: Rust 5–13% faster across all ws. Load-only spin handles cache-coherence-sensitive workloads better on simple topologies — consistent with HoldTime's work≥16 crossover.

4. **Optimal wins ws=64 (L1) on AMD + Broadwell — cache-line contention is Optimal's regime.** AMD ws=64: Optimal 45k vs Rust 56k vs NIO 55k. Broadwell ws=64: Optimal 73k vs Rust 126k vs NIO 103k. When lockWord cache line is the only hot data, depth-gate + pause budget wins.

5. **Alder Lake 12c cache-level spread is almost flat** (25.6k → 53.1k across full range). Small-core consumer doesn't expose the sharp cache-level transitions NUMA machines do.

### PI-futex cliff — per CPU on CacheLevels

| CPU | ws=64 (L1) | ws=1024 (L2) | ws=1048576 (DRAM) |
|---|---:|---:|---:|
| Intel i5-12500 (12c Alder Lake) | within 10% | within 5% | within 15% |
| AMD EPYC 9454P (64c Zen 4) | **30×** | **22×** | **18×** |
| Intel Xeon Gold 6148 (40c Skylake NUMA) | 6× | 5× | 5× |
| Intel Xeon E5-2699 v4 (44c Broadwell NUMA) | **13×** | **12×** | **9×** |

### Workload-choice matrix

| Workload shape | Ship choice | Why |
|---|---|---|
| Hot cache-line (L1, tasks=16) | Optimal (AMD/Broadwell) or Rust (Intel simple) | Cache-line contention wins pattern depends on CPU topology |
| L2/L3 sized working set | Optimal or Rust (within 10%) | All variants within 10% of each other |
| DRAM-sized (ws ≥ 1MB) | Rust on Intel Alder Lake; Optimal elsewhere | Rust beats Optimal 34% on simple topology at DRAM |
| Any config on AMD/NUMA | **Optimal** | Avoids PI cliff |

## Implementations

- **Optimal** — OptimalMutex with lazy waiter-count backport.
- **RustMutex** — Rust std 1.62+ load-only spin + post-CAS park.
- **NIOLockedValueBox (NIO)** — pthread_mutex_t wrapper.
- **Synchronization.Mutex (PI)** — Swift stdlib PI-futex.

## Test hosts

Same 4 x86 hosts as ContentionRatio / HoldTime. M1 Ultra absent.

---

## Detailed p50 wall-clock (µs)

Fresh 2026-04-20 data; all configs at tasks=16 work=8 pause=0.

### Intel i5-12500 (12c Alder Lake)

| Working set | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| ws=64 (~2 KB, L1) | 25,625 | 25,002 | 27,804 | 25,788 |
| ws=1024 (~32 KB, L2) | 27,017 | 26,214 | 28,099 | 28,295 |
| ws=16384 (~512 KB, L2/L3) | 27,476 | 26,739 | 28,525 | 28,918 |
| ws=262144 (~8 MB, L3) | 28,328 | 26,018 | 30,491 | 30,179 |
| ws=1048576 (~32 MB, DRAM) | 53,117 | 35,488 | 53,445 | 46,137 |

Flat across L1/L2/L3 (25.6k–28.3k); sharp jump at DRAM where RustMutex's load-only spin wins by 34% over Optimal. No PI cliff.

### AMD EPYC 9454P (64c Zen 4)

| Working set | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| ws=64 (~2 KB, L1) | 45,384 | 55,542 | 54,755 | **1.36s** |
| ws=1024 (~32 KB, L2) | 62,456 | 68,813 | 69,009 | **1.36s** |
| ws=16384 (~512 KB, L2/L3) | 67,011 | 72,483 | 72,483 | **1.37s** |
| ws=262144 (~8 MB, L3) | 70,779 | 78,643 | 77,332 | **1.39s** |
| ws=1048576 (~32 MB, DRAM) | 78,512 | 85,524 | 84,869 | **1.38s** |

Optimal wins ws=64 by 22% over Rust/NIO (tightest-contention regime). PI cliff essentially constant (1.36–1.39s) across cache levels — kernel-side cost, working-set independent.

### Intel Xeon Gold 6148 (40c Skylake, 2-socket NUMA)

| Working set | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| ws=64 (~2 KB, L1) | 82,182 | 83,689 | 90,702 | 516,948 |
| ws=1024 (~32 KB, L2) | 96,797 | 84,345 | 101,188 | 496,501 |
| ws=16384 (~512 KB, L2/L3) | 101,384 | 88,736 | 103,875 | 479,461 |
| ws=262144 (~8 MB, L3) | 102,629 | 93,913 | 106,365 | 479,199 |
| ws=1048576 (~32 MB, DRAM) | 109,773 | 100,794 | 117,309 | 511,705 |

RustMutex beats Optimal by 5–13% across all working sets — load-only spin amortizes better on cross-socket Skylake than depth-gated retry. PI cliff 5–6× plain, constant across ws.

### Intel Xeon E5-2699 v4 (44c Broadwell, 2-socket NUMA)

| Working set | Optimal | RustMutex | NIOLockedValueBox | Synchronization.Mutex |
|---|---:|---:|---:|---:|
| ws=64 (~2 KB, L1) | 73,204 | 125,829 | 103,285 | 951,583 |
| ws=1024 (~32 KB, L2) | 140,640 | 151,126 | 150,077 | **1.73s** |
| ws=16384 (~512 KB, L2/L3) | 139,985 | 153,485 | 155,582 | **1.88s** |
| ws=262144 (~8 MB, L3) | 146,407 | 154,141 | 160,301 | **1.42s** |
| ws=1048576 (~32 MB, DRAM) | 170,394 | 162,529 | 166,461 | **1.51s** |

Optimal dominates ws=64 (73k vs Rust 126k / NIO 103k — 42% lead). L1 cache-line thrash on 44c NUMA is where depth-gate + jitter pay off most. At larger ws the ranking tightens; Rust edges Optimal at DRAM. PI cliff 9–13× plain.
