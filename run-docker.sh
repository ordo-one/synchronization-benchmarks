#!/bin/bash
set -euo pipefail

# Build + run mutex-bench inside a container with varying CPU core counts.
# Works with both Linux Docker and macOS Apple Container.
# Mounts the local bench dir, results written to results/ on the host.
#
# Usage:
#   ./run-docker.sh                          # default core matrix: 1,2,4,8,16
#   ./run-docker.sh 2,4,8                    # custom core counts
#   ./run-docker.sh 4 --target SpinTuning    # single core count + bench args

# Detect container runtime: macOS Apple container vs Linux docker
if command -v container >/dev/null 2>&1 && [ "$(uname)" = "Darwin" ]; then
    RUNTIME="container"
    RUNTIME_NAME="apple-container"
elif command -v docker >/dev/null 2>&1; then
    if id -nG | grep -qw docker 2>/dev/null; then
        RUNTIME="docker"
    else
        RUNTIME="sudo -n docker"
    fi
    RUNTIME_NAME="docker"
else
    echo "Error: neither 'container' (macOS) nor 'docker' found."
    exit 1
fi

echo "Using runtime: ${RUNTIME_NAME}"

IMAGE="mutex-bench"
MEMORY="8G"
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default to (host cores - 2) so the bench doesn't fight the host/runtime for CPU.
# Override by passing a comma-separated matrix as the first arg.
if [ "$(uname)" = "Darwin" ]; then
    HOST_CORES=$(sysctl -n hw.ncpu)
else
    HOST_CORES=$(nproc)
fi
DEFAULT_CORES=$(( HOST_CORES > 2 ? HOST_CORES - 2 : HOST_CORES ))
CORES="$DEFAULT_CORES"
BENCH_ARGS=()
if [ $# -gt 0 ]; then
    if [[ "$1" =~ ^[0-9,]+$ ]]; then
        CORES="$1"
        shift
    fi
    BENCH_ARGS=("$@")
fi

IFS=',' read -ra CORE_LIST <<< "$CORES"

# Step 1: build image (cached after first run)
echo "=== Building container image ==="
if [ "$RUNTIME_NAME" = "apple-container" ]; then
    $RUNTIME build -t "$IMAGE" "$BENCH_DIR"
else
    $RUNTIME build --network host -t "$IMAGE" "$BENCH_DIR"
fi
echo ""

# Step 2: build the benchmark once inside the container (shared .build cache)
echo "=== Building benchmarks ==="
$RUNTIME run --rm \
    -v "${BENCH_DIR}:/mutex-bench" \
    -w /mutex-bench \
    -m "$MEMORY" \
    "$IMAGE" \
    swift build -c release
echo ""

# Step 3: run matrix
echo "=== Running benchmark matrix: cores=${CORES} ==="
mkdir -p "${BENCH_DIR}/results"

for NCPU in "${CORE_LIST[@]}"; do
    TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
    HOST=$(hostname -s)
    OUTFILE="results/${TIMESTAMP}-${RUNTIME_NAME}-${NCPU}cpu-${HOST}.txt"

    echo "--- cpus=${NCPU} memory=${MEMORY} ---"
    echo "  Output: ${OUTFILE}"

    # Apple container: -c limits visible CPUs directly (VM-based)
    # Docker: --cpuset-cpus pins to specific cores so nproc reports correctly
    if [ "$RUNTIME_NAME" = "apple-container" ]; then
        CPU_FLAG="-c ${NCPU}"
    else
        CPU_FLAG="--cpuset-cpus 0-$((NCPU - 1))"
    fi

    $RUNTIME run --rm \
        -v "${BENCH_DIR}:/mutex-bench" \
        -w /mutex-bench \
        $CPU_FLAG \
        -m "$MEMORY" \
        "$IMAGE" \
        bash -c "
            echo '# mutex-bench container run'
            echo \"runtime=${RUNTIME_NAME}\"
            echo \"host=\$(hostname)\"
            echo \"date=\$(date -Iseconds)\"
            echo \"uname=\$(uname -a)\"
            echo \"cpus=${NCPU}\"
            echo \"memory=${MEMORY}\"
            if command -v lscpu >/dev/null 2>&1; then
                echo '---'
                lscpu | grep -E 'Model name|CPU\(s\)|Socket|Core|Thread'
            fi
            if command -v nproc >/dev/null 2>&1; then
                echo \"nproc=\$(nproc)\"
            fi
            echo '---'
            swift package --allow-writing-to-package-directory benchmark --format markdown ${BENCH_ARGS[*]:-} 2>&1
        " | tee "${BENCH_DIR}/${OUTFILE}"

    echo ""
done

echo "=== Done ==="
echo "Results:"
ls -lt "${BENCH_DIR}/results/"*"${RUNTIME_NAME}"* 2>/dev/null | head -20
