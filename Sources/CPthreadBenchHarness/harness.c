#include "CPthreadBenchHarness.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    uint32_t parties;
    uint32_t waiting;
    uint32_t generation;
} pthread_bench_barrier_t;

typedef struct {
    uint32_t threads;
    uint32_t locks;
    uint32_t ops;
    void *context;
    PthreadBenchIncrementFn increment;
    pthread_bench_barrier_t start_barrier;
    pthread_bench_barrier_t end_barrier;
} pthread_bench_shared_t;

typedef struct {
    pthread_bench_shared_t *shared;
    uint32_t seed;
} pthread_bench_worker_t;

static uint32_t pthread_bench_xorshift32(uint32_t *state) {
    uint32_t x = *state;
    if (x == 0) {
        x = 0xA341316Cu;
    }
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static int pthread_bench_barrier_init(pthread_bench_barrier_t *barrier, uint32_t parties) {
    memset(barrier, 0, sizeof(*barrier));
    barrier->parties = parties;

    int status = pthread_mutex_init(&barrier->mutex, NULL);
    if (status != 0) {
        return status;
    }

    status = pthread_cond_init(&barrier->cond, NULL);
    if (status != 0) {
        pthread_mutex_destroy(&barrier->mutex);
        return status;
    }

    return 0;
}

static void pthread_bench_barrier_destroy(pthread_bench_barrier_t *barrier) {
    pthread_cond_destroy(&barrier->cond);
    pthread_mutex_destroy(&barrier->mutex);
}

static int pthread_bench_barrier_wait(pthread_bench_barrier_t *barrier) {
    int status = pthread_mutex_lock(&barrier->mutex);
    if (status != 0) {
        return status;
    }

    uint32_t generation = barrier->generation;
    barrier->waiting += 1;
    if (barrier->waiting == barrier->parties) {
        barrier->waiting = 0;
        barrier->generation += 1;
        status = pthread_cond_broadcast(&barrier->cond);
        int unlock_status = pthread_mutex_unlock(&barrier->mutex);
        if (status != 0) {
            return status;
        }
        return unlock_status;
    }

    while (generation == barrier->generation) {
        status = pthread_cond_wait(&barrier->cond, &barrier->mutex);
        if (status != 0) {
            pthread_mutex_unlock(&barrier->mutex);
            return status;
        }
    }

    return pthread_mutex_unlock(&barrier->mutex);
}

static void *pthread_bench_worker_main(void *raw_worker) {
    pthread_bench_worker_t *worker = (pthread_bench_worker_t *)raw_worker;
    pthread_bench_shared_t *shared = worker->shared;
    uint32_t rng = worker->seed;

    if (pthread_bench_barrier_wait(&shared->start_barrier) != 0) {
        return NULL;
    }

    for (uint32_t i = 0; i < shared->ops; i++) {
        uint32_t idx = pthread_bench_xorshift32(&rng) % shared->locks;
        shared->increment(shared->context, idx);
    }

    pthread_bench_barrier_wait(&shared->end_barrier);
    return NULL;
}

static int pthread_bench_elapsed_ns(struct timespec start, struct timespec end, uint64_t *elapsed_ns) {
    uint64_t start_ns = ((uint64_t)start.tv_sec * 1000000000ULL) + (uint64_t)start.tv_nsec;
    uint64_t end_ns = ((uint64_t)end.tv_sec * 1000000000ULL) + (uint64_t)end.tv_nsec;
    *elapsed_ns = end_ns - start_ns;
    return 0;
}

int pthread_bench_run(
    uint32_t threads,
    uint32_t locks,
    uint32_t ops,
    void *context,
    PthreadBenchIncrementFn increment,
    uint64_t *elapsed_ns
) {
    if (threads == 0 || locks == 0 || increment == NULL || elapsed_ns == NULL) {
        return EINVAL;
    }

    pthread_t *thread_ids = (pthread_t *)calloc(threads, sizeof(pthread_t));
    pthread_bench_worker_t *workers =
        (pthread_bench_worker_t *)calloc(threads, sizeof(pthread_bench_worker_t));
    if (thread_ids == NULL || workers == NULL) {
        free(thread_ids);
        free(workers);
        return ENOMEM;
    }

    pthread_bench_shared_t shared;
    memset(&shared, 0, sizeof(shared));
    shared.threads = threads;
    shared.locks = locks;
    shared.ops = ops;
    shared.context = context;
    shared.increment = increment;

    int status = pthread_bench_barrier_init(&shared.start_barrier, threads + 1);
    if (status != 0) {
        free(thread_ids);
        free(workers);
        return status;
    }

    status = pthread_bench_barrier_init(&shared.end_barrier, threads + 1);
    if (status != 0) {
        pthread_bench_barrier_destroy(&shared.start_barrier);
        free(thread_ids);
        free(workers);
        return status;
    }

    uint32_t base_rng = 0x6F4A955Eu;
    uint32_t state = 0x9BA2BF27u;
    uint32_t created = 0;

    for (uint32_t i = 0; i < threads; i++) {
        state ^= pthread_bench_xorshift32(&base_rng);
        workers[i].shared = &shared;
        workers[i].seed = state;
        status = pthread_create(&thread_ids[i], NULL, pthread_bench_worker_main, &workers[i]);
        if (status != 0) {
            for (uint32_t j = 0; j < created; j++) {
                pthread_join(thread_ids[j], NULL);
            }
            pthread_bench_barrier_destroy(&shared.end_barrier);
            pthread_bench_barrier_destroy(&shared.start_barrier);
            free(thread_ids);
            free(workers);
            return status;
        }
        created += 1;
    }

    usleep(100000);

    status = pthread_bench_barrier_wait(&shared.start_barrier);
    if (status != 0) {
        goto cleanup;
    }

    struct timespec start;
    struct timespec end;
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
        status = errno;
        goto cleanup;
    }

    status = pthread_bench_barrier_wait(&shared.end_barrier);
    if (status != 0) {
        goto cleanup;
    }

    if (clock_gettime(CLOCK_MONOTONIC, &end) != 0) {
        status = errno;
        goto cleanup;
    }

    pthread_bench_elapsed_ns(start, end, elapsed_ns);

cleanup:
    for (uint32_t i = 0; i < created; i++) {
        pthread_join(thread_ids[i], NULL);
    }
    pthread_bench_barrier_destroy(&shared.end_barrier);
    pthread_bench_barrier_destroy(&shared.start_barrier);
    free(thread_ids);
    free(workers);
    return status;
}
