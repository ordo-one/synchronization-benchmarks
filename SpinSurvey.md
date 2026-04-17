# Mutex Spin-Before-Park: Cross-Ecosystem Survey

A survey of how major language runtimes and OS primitives implement the spin phase before parking a contending thread in the kernel.

## Spin counts ranked

| Implementation | Spin iterations | Strategy | Spin instruction | Kernel fallback | Source |
|---|---:|---|---|---|---|
| WebKit `WTF::Lock` | **40** | Fixed + yield between spins | `yield()` | ParkingLot queue | [WebKit blog](https://webkit.org/blog/6161/locking-in-webkit/) |
| glibc `PTHREAD_MUTEX_ADAPTIVE_NP` | **100** | Exponential backoff + random jitter | `pause` | `futex(FUTEX_WAIT)` | [glibc tunables](https://www.gnu.org/software/libc/manual/html_node/POSIX-Thread-Tunables.html) |
| Rust `std::sync::Mutex` (Linux) | **100** | Fixed, plain spin-loop hint | `spin_loop()` (`pause` / `yield`) | `futex(FUTEX_WAIT)` | [Rust source](https://github.com/rust-lang/rust/blob/master/library/std/src/sys/sync/mutex/futex.rs) |
| Go `sync.Mutex` | **120** | 4 attempts × 30 procyield; starvation mode disables spin entirely | `procyield(30)` | semaphore | [Go source](https://github.com/golang/go/blob/master/src/sync/mutex.go) |
| Rust `parking_lot` | **~few dozen** | Adaptive based on contention | platform-dependent | ParkingLot queue (from WebKit) | [parking_lot source](https://github.com/Amanieu/parking_lot/tree/master/core/src) |
| Linux kernel `mutex` | **500–1000** | Condition-based: exits if owner not on CPU, `need_resched`, or vcpu preempted | arch-specific | futex | [kernel docs](https://docs.kernel.org/locking/mutex-design.html) |

## Key observations

1. **Most modern implementations are adaptive.** Go disables spin entirely in starvation mode. glibc uses exponential backoff with jitter. `parking_lot` ramps from spin → yield → park. The Linux kernel checks whether the owner is still on-CPU and bails the instant that breaks.

2. **The community-validated range for fixed spin counts is ~40–120 iterations.** WebKit picked 40 and hasn't changed it in a decade. glibc ADAPTIVE_NP defaults to 100. Rust's std-mutex spins 100. Go caps at 120. Anything substantially larger trades latency for unclear benefit once `pause` costs grew post-Skylake.

3. **`pause` cost varies by ~14× across x86 microarchitectures.** Pre-Skylake Intel: ~10 cycles. Post-Skylake: ~140 cycles. AMD Zen 4: ~40 cycles. A spin count tuned for one microarch is mistuned elsewhere — argues for adaptive strategies or runtime tuning.

---

## Implementation details

### WebKit — `WTF::Lock` and the ParkingLot

The foundational design that influenced Rust's `parking_lot`. Designed by Filip Pizlo at Apple (2015–2016).

**Architecture:** Two-bit lock word (`isLocked`, `hasParked`) with a global hash-table-based **ParkingLot** for thread queuing. The lock itself is only 1 byte. Thread queues live in the ParkingLot, keyed by lock address — not embedded in the lock struct.

**Spin strategy:** 40 iterations with `yield()` between attempts. If spin exhausts, the thread parks itself in the ParkingLot queue.

**Fairness:** Barging (new arrivals can steal the lock from parked waiters) with random fairness injection. When the system detects unfairness (acquisition-count variance exceeds threshold), it switches to direct handoff for ~1ms before reverting to barging. This avoids both starvation and convoy effects.

**Post-2016 updates:**
- Thread-safety annotations added (2021): `Lock` renamed to `UncheckedLock`, `CheckedLock` renamed to `Lock` with clang `__attribute__((capability("mutex")))` integration.
- ParkingLot enhanced with token-based communication between `unparkOne()` and `parkConditionally()` for more efficient fair unlock.
- Spin count (40) has not changed since the original implementation.

**Source links:**
- [Locking in WebKit](https://webkit.org/blog/6161/locking-in-webkit/) — original design blog post (2016)
- [`Source/WTF/wtf/Lock.h`](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/Lock.h) — the lock implementation
- [`Source/WTF/wtf/ParkingLot.h`](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/ParkingLot.h) — the hash-table thread parking infrastructure
- [On mutex performance (WTF::Lock)](https://blog.mozilla.org/nfroyd/2017/03/29/on-mutex-performance-part-1/) — Mozilla's independent evaluation (2017)

**Takeaway:** ParkingLot is the conceptual ancestor of Rust's `parking_lot` and many modern lock designs. Its 40-iteration spin count was empirically chosen and has survived a decade unchanged — a reasonable upper bound for userspace spinning with a kernel fallback.

---

### Rust — `std::sync::Mutex` (Linux)

Since Rust 1.62 (June 2022), `std::sync::Mutex` on Linux, Android, and Fuchsia uses a custom futex-based implementation — no longer a `pthread_mutex_t` wrapper. Authored by Mara Bos / Amanieu d'Antras.

**Architecture:** 3-state futex word: 0 = unlocked, 1 = locked (no waiters), 2 = locked + contended. Size: 4 bytes. No separate heap allocation, no initialization. Stable across platforms with futex support.

**Spin strategy:** `spin_contended()` runs 100 iterations with `core::hint::spin_loop()` (`pause` on x86, `yield` on arm64). Exits early if the lock is seen unlocked OR if the state shows other waiters already parked (at which point the caller should mark the lock contended and park too, rather than barge). No backoff or jitter.

```rust
fn spin(&self) -> u32 {
    let mut spin = 100;
    loop {
        let state = self.futex.load(Relaxed);
        if state != LOCKED || spin == 0 { return state; }
        core::hint::spin_loop();
        spin -= 1;
    }
}
```

**Fairness:** Barging — spinners race with the woken waiter on `FUTEX_WAKE`.

**Source links:**
- [`library/std/src/sys/sync/mutex/futex.rs`](https://github.com/rust-lang/rust/blob/master/library/std/src/sys/sync/mutex/futex.rs) — the futex-mutex impl
- [Rust 1.62 release notes](https://blog.rust-lang.org/2022/06/30/Rust-1.62.0/) — announced the switch
- [Inside Rust's std and parking_lot mutexes — who win?](https://blog.cuongle.dev/p/inside-rusts-std-and-parking-lot-mutexes-who-win) — walkthrough

**Takeaway:** std-mutex deliberately mirrors the conservative glibc-ADAPTIVE count (100) rather than the more aggressive `parking_lot` design — a pragmatic choice given std must satisfy all workloads with one fixed number.

---

### Rust — `parking_lot`

Directly based on WebKit's `WTF::ParkingLot` design. Author: Amanieu d'Antras.

**Architecture:** Hash-table-based ParkingLot (borrowed from WebKit) mapping lock addresses to thread queues. Lock word is 1 byte for Mutex, 1 word for RwLock/Condvar. Callbacks during queue operations allow the lock algorithm to make decisions during park/unpark.

**Spin strategy:** Adaptive, few-dozen iterations. Uses platform-specific spin hints (`pause` on x86, `yield` on ARM). The `SpinWait` utility tracks spin iterations and transitions from spinning → yielding → parking based on accumulated count.

**Performance vs std::sync::Mutex:**
- 1.5× faster uncontended
- Up to 5× faster under contention
- Storage: 1 byte vs 40 bytes (std Mutex wraps pthread_mutex_t)

**Key design paper:** No dedicated blog post by Amanieu. The README and source comments are the primary design documentation:
- [parking_lot README](https://github.com/Amanieu/parking_lot) — design rationale, benchmarks, motivation
- [parking_lot_core](https://github.com/Amanieu/parking_lot/tree/master/core/src) — the ParkingLot implementation
- [lock_api/src/mutex.rs](https://github.com/Amanieu/parking_lot/blob/master/lock_api/src/mutex.rs) — the Mutex algorithm
- [Benchmark gist](https://gist.github.com/Amanieu/6a4b4151b89b78224992106f9bc4374f) — raw benchmark results by Amanieu
- [Inside Rust's std and parking_lot mutexes — who win?](https://blog.cuongle.dev/p/inside-rusts-std-and-parking-lot-mutexes-who-win) — third-party comparison (Cuong Le)

**Takeaway:** `parking_lot` proves the WebKit ParkingLot pattern works cross-platform at production scale. Its 1-byte lock with few-dozen spins outperforms pthread_mutex wrappers — the design has held up well enough that `std::sync::Mutex` adopted parts of it (the futex-only path) while keeping the std-simple 100-spin fixed strategy.

---

### Go — `sync.Mutex`

**Architecture:** Single `int32` state word with 3 bit-fields: `mutexLocked`, `mutexWoken`, `mutexStarving`. Waiter count in upper bits. Uses a runtime semaphore for parking.

**Spin strategy:** 4 attempts, each calling `runtime.procyield(30)` (30 iterations of architecture-specific spin hint). Total: ~120 spin iterations. Spinning is only attempted when:
- Running on a multiprocessor machine
- GOMAXPROCS > 1
- At least one other goroutine is running
- Current P's (processor) local run queue is empty

**Two modes:**
- **Normal mode:** Spinning allowed. New arrivals compete with parked waiters (barging). Provides better throughput.
- **Starvation mode:** Activated when a waiter has been blocked >1ms. Ownership handed directly to the longest-waiting goroutine. **Spinning disabled entirely.** Prevents tail latency.

**Source links:**
- [`sync/mutex.go`](https://github.com/golang/go/blob/master/src/sync/mutex.go) — full algorithm with extensive comments
- [`runtime/lock_futex.go`](https://github.com/golang/go/blob/master/src/runtime/lock_futex.go) — futex-based lock primitives
- [`runtime/asm_amd64.s`](https://github.com/golang/go/blob/master/src/runtime/asm_amd64.s) — `procyield` assembly (search for `TEXT runtime·procyield`)
- [Go sync.Mutex: Normal and Starvation Mode](https://victoriametrics.com/blog/go-sync-mutex/) — design walkthrough

**Takeaway:** Go's starvation mode is the most sophisticated fairness mechanism in this survey — contention-driven rather than count-driven. When any waiter exceeds 1 ms, spinning is disabled entirely and the lock becomes strict FIFO, then reverts once the queue drains. Cooperative-runtime semantics (goroutines + GOMAXPROCS) make this design a useful reference for any M:N scheduler lock.

---

### Linux kernel — adaptive mutex spinning

**Architecture:** `struct mutex` with `owner` field (pointer to owning `task_struct`), wait list, and optimistic spin queue (OSQ based on MCS locks). The kernel mutex is the gold standard for adaptive spinning.

**Spin strategy:** Condition-based, not iteration-counted. The spinning loop checks these conditions every iteration and exits immediately if any is true:
1. **Owner not running on any CPU** — no point spinning if owner is sleeping
2. **`need_resched()` set** — higher-priority task wants this CPU
3. **`vcpu_is_preempted(owner_cpu)`** — owner's virtual CPU was preempted (VM guest)

This means: spin for as long as the owner is actively running and will likely release soon. Park the instant that assumption breaks.

**MCS queue:** Only one spinner competes for the lock at a time. Others queue behind an MCS (Mellor-Crummey & Scott) lock that provides local spinning — each waiter spins on its own cache line rather than the shared lock word.

**Source links:**
- [`kernel/locking/mutex.c`](https://github.com/torvalds/linux/blob/master/kernel/locking/mutex.c) — `mutex_optimistic_spin()` is the key function
- [`kernel/locking/mcs_spinlock.h`](https://github.com/torvalds/linux/blob/master/kernel/locking/mcs_spinlock.h) — MCS queue-based spinning
- [Mutex Design](https://docs.kernel.org/locking/mutex-design.html) — official design document
- [RT-Mutex](https://docs.kernel.org/locking/rt-mutex.html) — priority-inheritance mutex (the underlying type behind `FUTEX_LOCK_PI`)
- [PI-futex](https://www.kernel.org/doc/Documentation/pi-futex.txt) — PI-futex design document
- [LWN: mutex adaptive spinning](https://lwn.net/Articles/314512/) — Peter Zijlstra's original patch (2009)

**Takeaway:** The kernel's approach — "spin while owner is running, park when it's not" — is the most principled. It requires kernel-level knowledge (is the owner on-CPU? was its vCPU preempted?) that userspace locks can't directly observe. Fixed iteration counts are always wrong against this baseline: sometimes 10 is too many (owner sleeping), sometimes 10,000 isn't enough (owner running but slow). Userspace locks approximate this with contention feedback (Go's starvation mode) or adaptive backoff (glibc, parking_lot).

---

### glibc — `pthread_mutex` adaptive

**Architecture:** glibc offers `PTHREAD_MUTEX_ADAPTIVE_NP` (non-portable) as an alternative to the default `PTHREAD_MUTEX_NORMAL`. The adaptive variant spins before falling to futex.

**Spin strategy:** Default 100 iterations. Tunable at runtime via `glibc.pthread.mutex_spin_count` (max 32767). Uses exponential backoff with random jitter to avoid thundering herd:

```
spin_count = exp_backoff + (jitter & (exp_backoff - 1))
```

This means the first few retries are short, then progressively longer with randomization to desynchronize competing threads.

**Source links:**
- [`nptl/pthread_mutex_lock.c`](https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_lock.c) — the lock implementation
- [POSIX Thread Tunables](https://www.gnu.org/software/libc/manual/html_node/POSIX-Thread-Tunables.html) — `glibc.pthread.mutex_spin_count` docs
- Note: the default `PTHREAD_MUTEX_NORMAL` (what most `pthread_mutex_t` users get) does **not** spin — it goes directly to `futex(FUTEX_WAIT)`. Only the `ADAPTIVE_NP` variant spins.

**Takeaway:** Even for adaptive pthread users, 100 iterations with backoff+jitter is glibc's community-validated default. Matches Rust's std-mutex choice. Both suggest ~100 is the sweet spot for fixed-count spinning before falling to futex.

---

## The ParkingLot pattern

Both WebKit and Rust `parking_lot` use the same fundamental pattern, which is worth calling out separately because it represents the state of the art for userspace lock infrastructure:

**Concept:** Instead of embedding a wait queue in each lock (like pthread_mutex embeds state for futex), use a **global hash table** that maps lock addresses to thread queues. The lock itself needs only 1–2 bits of state. The hash table is sharded for scalability.

**Advantages over futex-per-lock:**
- Lock size: 1 byte (vs 4+ bytes for futex word, 40 bytes for pthread_mutex_t)
- No kernel state until contention actually occurs
- Callbacks during park/unpark allow the lock algorithm to make atomic decisions about fairness and barging
- Thread queue operations happen in userspace; kernel is only consulted for the actual sleep/wake

**WebKit's contribution:** Invented the ParkingLot pattern for browser use (JSC, WebCore). Published the design in 2016.

**Rust's contribution:** Generalized ParkingLot into a standalone crate. Made it the basis for a 1-byte Mutex that outperforms a pthread_mutex_t wrapper at every contention level. (Note: since 1.62, `std::sync::Mutex` switched to its own futex-only impl — simpler than parking_lot, still 4 bytes, still beats the pthread wrapper it replaced.)

---

## Advanced spin instructions (not yet adopted by userspace locks)

| Instruction | Arch | What it does | Status |
|---|---|---|---|
| `UMWAIT` / `UMONITOR` | Intel (Tremont+) | User-mode MWAIT — monitor address, halt core until write | Kernel-gated via MSR; not in any userspace lock impl yet |
| `TPAUSE` | Intel (Tremont+) | Timed pause — two low-power states (C0.1, C0.2) | Simpler than UMWAIT; not adopted |
| `WFE` + `LDXR` | arm64 | Wait-for-event — halt core until cache-coherency event | Used by Linux kernel (OSQ locks); occasionally appears in userspace spin loops |

Reference: [LWN: Short waits with umwait](https://lwn.net/Articles/790920/)

## `pause` instruction cost by microarchitecture

| CPU generation | `pause` latency | 100 pauses @ 3 GHz |
|---|---:|---:|
| Sandy Bridge → Broadwell (2011–2014) | ~10 cycles | ~0.3 µs |
| Skylake → Cascade Lake (2015–2020) | ~140 cycles | ~4.7 µs |
| Alder Lake / Sapphire Rapids (2021+) | ~100 cycles | ~3.3 µs |
| AMD Zen 2/3 | ~65 cycles | ~2.2 µs |
| AMD Zen 4 (EPYC 9xxx) | ~40 cycles | ~1.3 µs |

A typical 100-spin loop therefore costs ~0.3–4.7 µs depending on microarchitecture — a ~14× spread from one fixed count.

Source: [Intel Optimization Manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html), [PAUSE cost analysis](https://community.intel.com/t5/Intel-ISA-Extensions/Pause-instruction-cost-and-proper-use-in-spin-loops/m-p/1137387)

## References

- [Locking in WebKit](https://webkit.org/blog/6161/locking-in-webkit/) — Filip Pizlo, Apple (2016). The foundational ParkingLot design.
- [Mutexes Are Faster Than Spinlocks](https://matklad.github.io/2020/01/04/mutexes-are-faster-than-spinlocks.html) — Aleksey Kladov (matklad)
- [Measuring Mutexes and Spinlocks](https://probablydance.com/2019/12/30/measuring-mutexes-spinlocks-and-how-bad-the-linux-scheduler-really-is/) — Malte Skarupke
- [On mutex performance (WTF::Lock)](https://blog.mozilla.org/nfroyd/2017/03/29/on-mutex-performance-part-1/) — Nathan Froyd (Mozilla, 2017)
- [Inside Rust's std and parking_lot mutexes — who win?](https://blog.cuongle.dev/p/inside-rusts-std-and-parking-lot-mutexes-who-win) — Cuong Le
- [LWN: mutex adaptive spinning](https://lwn.net/Articles/314512/) — Peter Zijlstra (2009)
- [LWN: Short waits with umwait](https://lwn.net/Articles/790920/) — Jonathan Corbet (2019)
- [Mutable Locks: Combining the Best of Spin and Sleep Locks](https://arxiv.org/pdf/1906.00490)
- [Go sync.Mutex: Normal and Starvation Mode](https://victoriametrics.com/blog/go-sync-mutex/)
