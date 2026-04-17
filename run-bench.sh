#!/bin/bash
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
