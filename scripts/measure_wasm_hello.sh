#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WASM_MOD="$ROOT_DIR/workloads/hello-wasm/target/wasm32-wasip1/release/hello-wasm.wasm"
RESULTS_DIR="$ROOT_DIR/results/raw/wasm/hello-wasm"

mkdir -p "$RESULTS_DIR"

if [[ ! -f "$WASM_MOD" ]]; then
  echo "ERROR: wasm module not found: $WASM_MOD" >&2
  echo "Build it first with:" >&2
  echo "  (cd workloads/hello-wasm && cargo build --release --target wasm32-wasip1)" >&2
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

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

echo "==== wasm hello-wasm run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "module: $WASM_MOD" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"

N_RUN=50
echo "[measure] running wasm module ${N_RUN} times..." | tee -a "$LOG_FILE"

for i in $(seq 1 "$N_RUN"); do
  t0_ns=$(gdate +%s%N)
  out=$(wasmtime run "$WASM_MOD" 2>&1)
  t1_ns=$(gdate +%s%N)

  delta_ns=$((t1_ns - t0_ns))
  delta_ms=$(awk "BEGIN { printf \"%.3f\", $delta_ns/1000000 }")

  # We can verify output if needed
  echo "run=${i} elapsed_ns=${delta_ns} elapsed_ms=${delta_ms} out=\"${out}\"" \
    | tee -a "$LOG_FILE"
done

echo "[measure] finished run, logs in: $LOG_FILE"
