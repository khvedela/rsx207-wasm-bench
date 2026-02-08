#!/usr/bin/env bash
set -euo pipefail

# Root of the repository (one level up from scripts/)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/common.sh"

BIN="$ROOT_DIR/workloads/http-hello/target/release/http-hello"
RESULTS_DIR="$ROOT_DIR/results/raw/native/http-hello"

mkdir -p "$RESULTS_DIR"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: binary not found or not executable: $BIN" >&2
  echo "Build it first with:" >&2
  echo "  (cd workloads/http-hello && cargo build --release)" >&2
  exit 1
fi

# Check gdate is available (coreutils)
check_gdate || exit 1

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

PORT=8080
PATH_SUFFIX="${PATH_SUFFIX:-/}"
if [[ "$PATH_SUFFIX" != /* ]]; then
  PATH_SUFFIX="/${PATH_SUFFIX}"
fi
URL="http://127.0.0.1:${PORT}${PATH_SUFFIX}"

echo "==== native http-hello run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "binary: $BIN" | tee -a "$LOG_FILE"
echo "url: $URL" | tee -a "$LOG_FILE"
log_versions "$LOG_FILE"

# Start server in background
echo "[measure] starting server..." | tee -a "$LOG_FILE"
t0_ns=$(gdate +%s%N)

SERVER_LOG="$RESULTS_DIR/${RUN_TS}_server.log"
"$BIN" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}cleanup_process "$SERVER_PID"
}
trap cleanup EXIT

# Wait for readiness: first HTTP 200
wait_for_http_ready "$URL" "$LOG_FILE" "$t0_ns" || exit 1

# Warm-up requests (not measured)
WARMUP_REQ="${WARMUP_REQ:-5}"
run_warmup_requests "$URL" "$WARMUP_REQ" "$LOG_FILE"

record_resources "$SERVER_PID" "$LOG_FILEEQ} sequential requests..." | tee -a "$LOG_FILE"

for i in $(seq 1 "$N_REQ"); do
  req_start_ns=$(gdate +%s%N)
  body=$(curl -sS -w "%{http_code}" "$URL" 2>/dev/null)
  req_end_ns=$(gdate +%s%N)

  http_code="${body: -3}"
  latency_ns=$((req_end_ns - req_start_ns))
  latency_ms=$(awk "BEGIN { printf \"%.3f\", $latency_ns/1000000 }")

  echo "req=${i} http_code=${http_code} latency_ns=${latency_ns} latency_ms=${latency_ms}" \
    | tee -a "$LOG_FILE"
done

THROUGHPUT_REQS="${THROUGHPUT_REQS:-200}"
THROUGHPUT_CONC="${THROUGHPUT_CONC:-10}"
if (( THROUGHPUT_REQS > 0 )); then
  echo "[measure] throughput_reqs=${THROUGHPUT_REQS} throughput_conc=${THROUGHPUT_CONC}" | tee -a "$LOG_FILE"
  t_tp_start_ns=$(gdate +%s%N)
  seq 1 "$THROUGHPUT_REQS" | xargs -P "$THROUGHPUT_CONC" -I {} \
    curl -sS -o /dev/null "$URL" >/dev/null 2>&1 || true
  t_tp_end_ns=$(gdate +%s%N)
  tp_ns=$((t_tp_end_ns - t_tp_start_ns))
  tp_s=$(awk -v ns="$tp_ns" 'BEGIN { printf "%.6f", ns/1000000000 }')
  tp_rps=$(awk -v n="$THROUGHPUT_REQS" -v ns="$tp_ns" 'BEGIN { if (ns>0) printf "%.3f", n/(ns/1000000000); else print "0" }')
  echo "[measure] throughput_total_s=${tp_s} throughput_rps=${tp_rps}" | tee -a "$LOG_FILE"
fi

echo "[measure] finished run, logs in: $LOG_FILE"
measure_latency_sequential "$URL" "$N_REQ" "$LOG_FILE"

# Throughput test
THROUGHPUT_REQS="${THROUGHPUT_REQS:-200}"
THROUGHPUT_CONC="${THROUGHPUT_CONC:-10}"
if (( THROUGHPUT_REQS > 0 )); then
  measure_throughput_concurrent "$URL" "$THROUGHPUT_REQS" "$THROUGHPUT_CONC"