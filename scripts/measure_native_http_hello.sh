#!/usr/bin/env bash
set -euo pipefail

# Root of the repository (one level up from scripts/)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
if ! command -v gdate >/dev/null 2>&1; then
  echo "ERROR: gdate not found. Install coreutils with:" >&2
  echo "  brew install coreutils" >&2
  exit 1
fi

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

PORT=8080
URL="http://127.0.0.1:${PORT}/"

echo "==== native http-hello run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "binary: $BIN" | tee -a "$LOG_FILE"
echo "url: $URL" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"

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
}
trap cleanup EXIT

# Wait for readiness: first HTTP 200
echo "[measure] waiting for HTTP 200 from server..." | tee -a "$LOG_FILE"
retries=0
max_retries=200  # ~2 seconds total if sleep 0.01
ready=0

while (( retries < max_retries )); do
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" "$URL" || echo "000")
  if [[ "$http_code" == "200" ]]; then
    t_ready_ns=$(gdate +%s%N)
    ready=1
    break
  fi
  retries=$((retries + 1))
  sleep 0.01
done

if (( ready == 0 )); then
  echo "[measure] ERROR: server did not become ready in time" | tee -a "$LOG_FILE"
  exit 1
fi

cold_start_ns=$((t_ready_ns - t0_ns))
cold_start_ms=$(awk "BEGIN { printf \"%.3f\", $cold_start_ns/1000000 }")

echo "[measure] cold_start_ns=${cold_start_ns}" | tee -a "$LOG_FILE"
echo "[measure] cold_start_ms=${cold_start_ms}" | tee -a "$LOG_FILE"

# Latency test: N sequential requests
N_REQ=50
echo "[measure] running ${N_REQ} sequential requests..." | tee -a "$LOG_FILE"

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

echo "[measure] finished run, logs in: $LOG_FILE"
