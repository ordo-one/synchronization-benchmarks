#!/bin/bash
# Darwin: bench only sees Sync.Mutex + NIOLockedValueBox (manual impls are
# Linux-only via #if os(Linux)) — direct run produces useless results for the
# upstream case. Route to run-docker.sh which uses Apple container or Docker
# to get the full Linux matrix.
if [ "$(uname)" = "Darwin" ]; then
    exec "$(dirname "$0")/run-docker.sh" "$@"
fi

[ -f /etc/profile.d/swiftly.sh ] && source /etc/profile.d/swiftly.sh
set -euo pipefail

# Runs package-benchmark and captures all output (stdout + stderr, including
# HDR histogram / Gini summaries) to results/YYYY-MM-DD-HOST.txt.
#
# Pass-through args go to `swift package benchmark`, e.g.:
#   ./run-bench.sh --target LongRun
#   MUTEX_BENCH_MAX_SECS=1 ./run-bench.sh
#
# Designed to run on a target host after rsync from dev machine.

# Some hosts confine unprivileged shells to 2 cores via cpuset;
# /usr/bin/ordo-run-in-cpuset writes its own pid into a wider cgroup and exec's
# the command that follows. Re-exec this script under the wrapper so every
# child (incl. swift and its spawned bench executables) inherits the widened
# cpuset. Wrapper is absent on hosts without the restriction — skip silently.
if [ -x /usr/bin/ordo-run-in-cpuset ] && [ -z "${IN_CPUSET:-}" ]; then
    export IN_CPUSET=1
    exec /usr/bin/ordo-run-in-cpuset "$0" "$@"
fi

mkdir -p results
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
HOST=$(hostname -s)
OUT="results/${TIMESTAMP}-${HOST}.txt"

echo "Writing to: ${OUT}"
echo "Host: ${HOST}"
echo "Date: $(date -Iseconds)"
echo "---"

# Two ways to pin the benchmark to a subset of CPUs:
#
#   MUTEX_BENCH_CPU_LIST=<cpulist> — taskset to an explicit CPU range.
#     Example: MUTEX_BENCH_CPU_LIST=0-7 pins to CPUs 0..7 (one CCX on Zen 4,
#     part of a socket on NUMA hosts, etc.). Format is whatever taskset -c
#     accepts: "0-7", "0,2,4,6", "0-3,8-11".
#
#   MUTEX_BENCH_SINGLE_NUMA=1 — convenience: pin to NUMA node 0. On hosts
#     where NUMA boundaries match socket boundaries (Skylake/Broadwell 2-socket)
#     this isolates cross-socket coherence. On single-NUMA hosts (Zen 4 Genoa,
#     Alder Lake) it's a no-op for isolation purposes — use CPU_LIST instead
#     for sub-NUMA topology (CCX, chiplet).
#
# Both paths fail hard if the required tool is absent — silently running
# unrestricted would produce data that answers the wrong question.
CPU_WRAP=""
if [ -n "${MUTEX_BENCH_CPU_LIST:-}" ]; then
    if command -v taskset >/dev/null 2>&1; then
        CPU_WRAP="taskset -c ${MUTEX_BENCH_CPU_LIST}"
    else
        echo "ERROR: MUTEX_BENCH_CPU_LIST=${MUTEX_BENCH_CPU_LIST} but taskset not found" >&2
        exit 1
    fi
elif [ "${MUTEX_BENCH_SINGLE_NUMA:-0}" = "1" ]; then
    if command -v numactl >/dev/null 2>&1; then
        CPU_WRAP="numactl --cpunodebind=0 --membind=0"
    elif command -v taskset >/dev/null 2>&1 && [ -r /sys/devices/system/node/node0/cpulist ]; then
        NODE0_CPUS=$(cat /sys/devices/system/node/node0/cpulist)
        CPU_WRAP="taskset -c ${NODE0_CPUS}"
    else
        echo "ERROR: MUTEX_BENCH_SINGLE_NUMA=1 requires numactl or (taskset + /sys/devices/system/node/node0/cpulist)" >&2
        exit 1
    fi
fi

{
    echo "# mutex-bench run"
    echo "host=$(hostname -f)"
    echo "date=$(date -Iseconds)"
    echo "uname=$(uname -a)"
    if [ -n "${CPU_WRAP}" ]; then
        echo "cpu_wrap=${CPU_WRAP}"
    fi
    if command -v lscpu >/dev/null 2>&1; then
        echo "---"
        lscpu | grep -E 'Model name|CPU\(s\)|Socket|Core|Thread'
    fi
    echo "---"
    ${CPU_WRAP} swift package --allow-writing-to-package-directory benchmark --format markdown "$@" 2>&1
} | tee "${OUT}"
