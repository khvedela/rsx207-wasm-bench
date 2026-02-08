#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WASM_MOD="$ROOT_DIR/workloads/cpu-hash/target/wasm32-wasip1/release/cpu-hash.wasm"
RESULTS_DIR="$ROOT_DIR/results/raw/wasm/cpu-hash"

mkdir -p "$RESULTS_DIR"

if [[ ! -f "$WASM_MOD" ]]; then
  echo "ERROR: wasm module not found: $WASM_MOD" >&2
  echo "Build it first with:" >&2
  echo "  (cd workloads/cpu-hash && cargo build --release --target wasm32-wasip1)" >&2
  exit 1
fi

if ! command -v gdate >/dev/null 2>&1; then
  echo "ERROR: gdate not found. Install coreutils with:" >&2
  echo "  brew install coreutils" >&2
  exit 1
fi

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "ERROR: wasmtime not found. Install with:" >&2
  echo "  brew install wasmtime" >&2
  exit 1
fi

ITERATIONS=2000000  # same as native

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

echo "==== wasm cpu-hash run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "module: $WASM_MOD" | tee -a "$LOG_FILE"
echo "iterations: $ITERATIONS" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"
echo "wasmtime_version: $(wasmtime --version)" | tee -a "$LOG_FILE"

CACHE_MODE="${WASMTIME_CACHE_MODE:-cold}"
CACHE_BASE="$RESULTS_DIR/${RUN_TS}_cache"
mkdir -p "$CACHE_BASE"
echo "wasmtime_cache_mode: $CACHE_MODE" | tee -a "$LOG_FILE"
echo "wasmtime_cache_base: $CACHE_BASE" | tee -a "$LOG_FILE"

N_RUN=20
echo "[measure] running ${N_RUN} executions via wasmtime..." | tee -a "$LOG_FILE"

if [[ "$CACHE_MODE" == "warm" ]]; then
  export WASMTIME_CACHE_DIR="$CACHE_BASE"
fi

for i in $(seq 1 "$N_RUN"); do
  t0_ns=$(gdate +%s%N)
  if [[ "$CACHE_MODE" == "cold" ]]; then
    run_cache="$CACHE_BASE/run${i}"
    mkdir -p "$run_cache"
    out=$(WASMTIME_CACHE_DIR="$run_cache" wasmtime run "$WASM_MOD" "$ITERATIONS" 2>&1)
  else
    out=$(wasmtime run "$WASM_MOD" "$ITERATIONS" 2>&1)
  fi
  t1_ns=$(gdate +%s%N)

  elapsed_ns=$((t1_ns - t0_ns))
  elapsed_ms=$(awk "BEGIN { printf \"%.3f\", $elapsed_ns/1000000 }")

  internal_ms=$(echo "$out" | sed -n 's/.*elapsed_ms=\([0-9.]\+\).*/\1/p')

  echo "run=${i} outer_ms=${elapsed_ms} inner_ms=${internal_ms:-NA} out=\"${out}\"" \
    | tee -a "$LOG_FILE"
done

echo "[measure] finished run, logs in: $LOG_FILE"
