#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BIN="$ROOT_DIR/workloads/cpu-hash/target/release/cpu-hash"
RESULTS_DIR="$ROOT_DIR/results/raw/native/cpu-hash"

mkdir -p "$RESULTS_DIR"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: binary not found or not executable: $BIN" >&2
  echo "Build it first with:" >&2
  echo "  (cd workloads/cpu-hash && cargo build --release)" >&2
  exit 1
fi

if ! command -v gdate >/dev/null 2>&1; then
  echo "ERROR: gdate not found. Install coreutils with:" >&2
  echo "  brew install coreutils" >&2
  exit 1
fi

ITERATIONS="${ITERATIONS:-2000000}"

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

echo "==== native cpu-hash run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "binary: $BIN" | tee -a "$LOG_FILE"
echo "iterations: $ITERATIONS" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"
if command -v rustc >/dev/null 2>&1; then
  echo "rustc_version: $(rustc --version)" | tee -a "$LOG_FILE"
fi

N_RUN=20
echo "[measure] running ${N_RUN} executions..." | tee -a "$LOG_FILE"

for i in $(seq 1 "$N_RUN"); do
  t0_ns=$(gdate +%s%N)
  out=$("$BIN" "$ITERATIONS" 2>&1)
  t1_ns=$(gdate +%s%N)

  elapsed_ns=$((t1_ns - t0_ns))
  elapsed_ms=$(awk "BEGIN { printf \"%.3f\", $elapsed_ns/1000000 }")

  internal_ms=$(echo "$out" | sed -n 's/.*elapsed_ms=\([0-9.]\+\).*/\1/p')

  echo "run=${i} outer_ms=${elapsed_ms} inner_ms=${internal_ms:-NA} out=\"${out}\"" \
    | tee -a "$LOG_FILE"
done

echo "[measure] finished run, logs in: $LOG_FILE"
