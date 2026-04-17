# LongRun

60-second wall-clock run at high contention with a long critical section. The shape that triggers [Go-style starvation mode](https://github.com/golang/go/blob/master/src/sync/mutex.go) (waiter blocked > 1 ms).

Based on [Go starvation mode](https://victoriametrics.com/blog/go-sync-mutex/) and [WebKit unfairness metric](https://webkit.org/blog/6161/locking-in-webkit/).

## Parameters

| Parameter | Values |
|---|---|
| tasks | 16, 64 |
| work | 1024 |
| duration | 60 s |

## Results (p50 wall clock, us)

All implementations converge to exactly 60,000,000 us (60s) across all machines:

| Config | x86 12c | x86 64c | x86 192c |
|---|---:|---:|---:|
| tasks=16 Optimal | 60,000,000 | 60,000,000 | 60,000,000 |
| tasks=16 NIOLock | 60,000,000 | 60,000,000 | 60,000,000 |
| tasks=16 Stdlib PI | 60,000,000 | 60,000,000 | 60,000,000 |
| tasks=64 Optimal | 60,000,000 | 60,000,000 | 60,000,000 |
| tasks=64 NIOLock | 60,000,000 | 60,000,000 | 60,000,000 |
| tasks=64 Stdlib PI | 60,000,000 | 60,000,000 | 60,000,000 |

Wall clock is capped at the 60s target duration - all implementations complete within the time window. With work=1024, the critical section is long enough that lock acquisition overhead is negligible.

The useful signal from LongRun is in the per-task acquire-count distribution (Gini coefficient) and per-acquire latency histograms reported to stderr during the run, not the wall clock p50. These expose barging-induced starvation that throughput metrics hide - a thread that acquires 10x fewer times than its peers has been systematically starved even though the aggregate looks healthy.

See [Fairness.md](Fairness.md) for the per-acquire latency analysis from the Asymmetric benchmark, which captures similar fairness data at shorter timescales.
