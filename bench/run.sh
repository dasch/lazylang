#!/usr/bin/env bash
# Lazylang benchmark suite.
# Usage: ./bench/run.sh [iterations]
set -euo pipefail

LAZY="${LAZY:-./bin/lazy}"
ITERS="${1:-10}"
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$LAZY" ]; then
  echo "Building lazylang..."
  zig build 2>/dev/null
fi

run_bench() {
  local name="$1"
  local file="$2"
  local cmd="${3:-eval}"

  local sum=0
  local min=999999
  local max=0

  for i in $(seq 1 "$ITERS"); do
    # Use gdate/date for nanosecond precision where available
    local start end elapsed_ms
    if command -v gdate &>/dev/null; then
      start=$(gdate +%s%N)
      "$LAZY" "$cmd" "$file" > /dev/null 2>&1
      end=$(gdate +%s%N)
      elapsed_ms=$(( (end - start) / 1000000 ))
    else
      start=$(date +%s)
      "$LAZY" "$cmd" "$file" > /dev/null 2>&1
      end=$(date +%s)
      elapsed_ms=$(( (end - start) * 1000 ))
    fi

    sum=$((sum + elapsed_ms))
    if [ "$elapsed_ms" -lt "$min" ]; then min=$elapsed_ms; fi
    if [ "$elapsed_ms" -gt "$max" ]; then max=$elapsed_ms; fi
  done

  local avg=$((sum / ITERS))
  printf "  %-40s avg: %5dms  min: %5dms  max: %5dms\n" "$name" "$avg" "$min" "$max"
}

echo "=== Lazylang Benchmark Suite ==="
echo "Iterations: $ITERS"
echo ""

echo "--- Macro Benchmarks ---"
run_bench "k8s-app (5 components × 3 envs)" "examples/kubernetes-app/app/build.lazy"
run_bench "k8s-simple (3 envs)" "examples/kubernetes/manifests.lazy"
echo ""

echo "--- Micro Benchmarks ---"
run_bench "array-ops (map/filter/fold)" "$BENCH_DIR/array_ops.lazy"
run_bench "object-merge (deep merge chain)" "$BENCH_DIR/object_merge.lazy"
run_bench "string-ops (interpolation/concat)" "$BENCH_DIR/string_ops.lazy"
run_bench "comprehensions (nested)" "$BENCH_DIR/comprehensions.lazy"
run_bench "pattern-matching" "$BENCH_DIR/pattern_matching.lazy"
run_bench "fibonacci (recursion)" "$BENCH_DIR/fibonacci.lazy"
run_bench "large-array (200 elements)" "$BENCH_DIR/large_array.lazy"
run_bench "deep-object (nested access)" "$BENCH_DIR/deep_object.lazy"
run_bench "many-imports (stdlib)" "$BENCH_DIR/many_imports.lazy"
echo ""

echo "Done."
