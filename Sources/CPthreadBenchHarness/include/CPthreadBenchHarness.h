#ifndef CPthreadBenchHarness_h
#define CPthreadBenchHarness_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*PthreadBenchIncrementFn)(void *context, uint32_t index);

int pthread_bench_run(
    uint32_t threads,
    uint32_t locks,
    uint32_t ops,
    void *context,
    PthreadBenchIncrementFn increment,
    uint64_t *elapsed_ns
);

#ifdef __cplusplus
}
#endif

#endif
