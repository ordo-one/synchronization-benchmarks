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

{
    echo "# mutex-bench run"
    echo "host=$(hostname -f)"
    echo "date=$(date -Iseconds)"
    echo "uname=$(uname -a)"
    if command -v lscpu >/dev/null 2>&1; then
        echo "---"
        lscpu | grep -E 'Model name|CPU\(s\)|Socket|Core|Thread'
    fi
    echo "---"
    swift package --allow-writing-to-package-directory benchmark --format markdown "$@" 2>&1
} | tee "${OUT}"
