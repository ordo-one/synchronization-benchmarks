//===----------------------------------------------------------------------===//
// C shims for Linux futex, atomics, and spin hints.
// Replaces stdlib-internal _SynchronizationShims.h and LLVM intrinsics.
//===----------------------------------------------------------------------===//

#ifndef CFUTEX_SHIMS_H
#define CFUTEX_SHIMS_H

#include <stdint.h>
#include <stdbool.h>

#if defined(__linux__)

#include <errno.h>
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// PI-futex lock word bits
// ---------------------------------------------------------------------------

// FUTEX_WAITERS (0x80000000) is defined in <linux/futex.h>.
// FUTEX_TID_MASK extracts the owning thread's TID from the lock word.
#ifndef FUTEX_TID_MASK
#define FUTEX_TID_MASK 0x3FFFFFFF
#endif

// Convenience for Swift: import as functions since Swift can't see #define values.
static inline uint32_t futex_tid_mask(void) { return FUTEX_TID_MASK; }
static inline uint32_t futex_waiters_bit(void) { return FUTEX_WAITERS; }

// ---------------------------------------------------------------------------
// Thread ID (TLS-cached, matches stdlib behavior)
// ---------------------------------------------------------------------------

static inline uint32_t mutex_gettid(void) {
    static __thread uint32_t tid = 0;
    if (__builtin_expect(tid == 0, 0)) {
        tid = (uint32_t)syscall(SYS_gettid);
    }
    return tid;
}

// ---------------------------------------------------------------------------
// PI-futex operations (matches stdlib FUTEX_LOCK_PI_PRIVATE usage)
// All return 0 on success, errno on failure.
// ---------------------------------------------------------------------------

static inline uint32_t futex_lock_pi(uint32_t *lock) {
    int ret = (int)syscall(SYS_futex, lock, FUTEX_LOCK_PI_PRIVATE, 0, NULL);
    return ret == 0 ? 0 : (uint32_t)errno;
}

static inline uint32_t futex_trylock_pi(uint32_t *lock) {
    int ret = (int)syscall(SYS_futex, lock, FUTEX_TRYLOCK_PI);
    return ret == 0 ? 0 : (uint32_t)errno;
}

static inline uint32_t futex_unlock_pi(uint32_t *lock) {
    int ret = (int)syscall(SYS_futex, lock, FUTEX_UNLOCK_PI_PRIVATE);
    return ret == 0 ? 0 : (uint32_t)errno;
}

// ---------------------------------------------------------------------------
// Plain futex operations (for comparison benchmarks without PI overhead)
// ---------------------------------------------------------------------------

static inline uint32_t futex_wait(uint32_t *addr, uint32_t expected) {
    int ret = (int)syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, expected, NULL);
    return ret == 0 ? 0 : (uint32_t)errno;
}

static inline uint32_t futex_wake(uint32_t *addr, int count) {
    int ret = (int)syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, count);
    return ret < 0 ? (uint32_t)errno : 0;
}

// ---------------------------------------------------------------------------
// Atomic operations (GCC builtins — well-defined, no Swift Atomic needed)
// ---------------------------------------------------------------------------

static inline uint32_t atomic_load_relaxed_u32(uint32_t *addr) {
    return __atomic_load_n(addr, __ATOMIC_RELAXED);
}

static inline void atomic_store_relaxed_u32(uint32_t *addr, uint32_t val) {
    __atomic_store_n(addr, val, __ATOMIC_RELAXED);
}

static inline void atomic_store_release_u32(uint32_t *addr, uint32_t val) {
    __atomic_store_n(addr, val, __ATOMIC_RELEASE);
}

// Returns true if exchange succeeded (old value matched expected).
// On failure, caller doesn't see old value — fine for this algorithm.
static inline bool atomic_cas_acquire_u32(
    uint32_t *addr, uint32_t expected, uint32_t desired
) {
    return __atomic_compare_exchange_n(
        addr, &expected, desired,
        /*weak=*/false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED
    );
}

static inline bool atomic_cas_release_u32(
    uint32_t *addr, uint32_t expected, uint32_t desired
) {
    return __atomic_compare_exchange_n(
        addr, &expected, desired,
        /*weak=*/false, __ATOMIC_RELEASE, __ATOMIC_RELAXED
    );
}

// Atomic exchange — returns previous value.
static inline uint32_t atomic_exchange_acquire_u32(uint32_t *addr, uint32_t val) {
    return __atomic_exchange_n(addr, val, __ATOMIC_ACQUIRE);
}

static inline uint32_t atomic_exchange_release_u32(uint32_t *addr, uint32_t val) {
    return __atomic_exchange_n(addr, val, __ATOMIC_RELEASE);
}

// ---------------------------------------------------------------------------
// Spin loop hint (replaces @_extern LLVM intrinsics)
// ---------------------------------------------------------------------------

#if defined(__x86_64__) || defined(__i386__)

static inline void spin_loop_hint(void) {
    __asm__ __volatile__("pause" ::: "memory");
}

// Stdlib value: 1000 for x86
static inline int default_spin_tries(void) { return 1000; }

#elif defined(__aarch64__)

static inline void spin_loop_hint(void) {
    // WFE: Wait For Event — halts core until cache-coherency event.
    // Note: heavier than yield (hint 1). See analysis in survey doc.
    __asm__ __volatile__("wfe" ::: "memory");
}

// Stdlib value: 100 for arm64
static inline int default_spin_tries(void) { return 100; }

#elif defined(__arm__)

static inline void spin_loop_hint(void) {
    __asm__ __volatile__("wfe" ::: "memory");
}

static inline int default_spin_tries(void) { return 100; }

#else

static inline void spin_loop_hint(void) {}
static inline int default_spin_tries(void) { return 100; }

#endif

// ---------------------------------------------------------------------------
// CPU count + adaptive backoff cap
//
// Used ONLY by the SpinTuning bench to sweep the `256/nproc` adaptive-cap
// variant. Experiments.md §8/§11 showed this formula breaks on mid-range
// cores (40c → cap=6, too tight) and in containers (reports host cores, not
// cgroup limit). Do NOT use in OptimalMutex or any shipped code — regime-
// gated state-driven cap replaced it.
// ---------------------------------------------------------------------------

static inline int get_cpu_count(void) {
    static int count = 0;
    if (__builtin_expect(count == 0, 0)) {
        count = (int)sysconf(_SC_NPROCESSORS_ONLN);
        if (count < 1) count = 1;
    }
    return count;
}

static inline uint32_t adaptive_backoff_cap(void) {
    int cpus = get_cpu_count();
    uint32_t cap = 256 / (uint32_t)cpus;
    if (cap < 4) cap = 4;
    if (cap > 32) cap = 32;
    return cap;
}

// ---------------------------------------------------------------------------
// Thread yield (for spin-then-yield strategies)
// ---------------------------------------------------------------------------

#include <sched.h>

static inline void thread_yield(void) { sched_yield(); }

// ---------------------------------------------------------------------------
// Adaptive pthread mutex (PTHREAD_MUTEX_ADAPTIVE_NP)
// glibc only — musl defines the constant but ignores it (behaves as NORMAL).
// Bionic (Android) doesn't define it at all.
// ---------------------------------------------------------------------------

#include <pthread.h>

static inline int adaptive_mutex_init(pthread_mutex_t *m) {
#if defined(__GLIBC__) && defined(PTHREAD_MUTEX_ADAPTIVE_NP)
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ADAPTIVE_NP);
    int ret = pthread_mutex_init(m, &attr);
    pthread_mutexattr_destroy(&attr);
    return ret;
#else
    // Fallback: plain NORMAL mutex (no spinning)
    return pthread_mutex_init(m, NULL);
#endif
}

static inline int adaptive_mutex_lock(pthread_mutex_t *m) {
    return pthread_mutex_lock(m);
}

static inline int adaptive_mutex_unlock(pthread_mutex_t *m) {
    return pthread_mutex_unlock(m);
}

static inline int adaptive_mutex_destroy(pthread_mutex_t *m) {
    return pthread_mutex_destroy(m);
}

#endif // defined(__linux__)
#endif // CFUTEX_SHIMS_H
