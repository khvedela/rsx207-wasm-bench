#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMP_DIR="$ROOT_DIR/workloads/wasmcloud-http-hello"
RESULTS_DIR="$ROOT_DIR/results/raw/wasmcloud/http-hello"

mkdir -p "$RESULTS_DIR"

if [[ ! -d "$COMP_DIR" ]]; then
  echo "ERROR: wasmcloud-http-hello component dir not found: $COMP_DIR" >&2
  echo "Create it with:" >&2
  echo "  (cd workloads && wash new component wasmcloud-http-hello --template-name hello-world-rust)" >&2
  exit 1
fi

if ! command -v gdate >/dev/null 2>&1; then
  echo "ERROR: gdate not found. Install coreutils with:" >&2
  echo "  brew install coreutils" >&2
  exit 1
fi

if ! command -v wash >/dev/null 2>&1; then
  echo "ERROR: wash not found. Install with:" >&2
  echo "  brew install wasmcloud/wasmcloud/wash" >&2
  exit 1
fi

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"
SERVER_LOG="$RESULTS_DIR/${RUN_TS}_wash_dev.log"

PORT=8000
URL="http://127.0.0.1:${PORT}/"

echo "==== wasmCloud http-hello run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "component_dir: $COMP_DIR" | tee -a "$LOG_FILE"
echo "url: $URL" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"

# Start wash dev in background from component dir
echo "[measure] starting wash dev..." | tee -a "$LOG_FILE"
t0_ns=$(gdate +%s%N)

(
  cd "$COMP_DIR"
  wash dev
) >"$SERVER_LOG" 2>&1 &
WASH_PID=$!

cleanup() {
  if kill -0 "$WASH_PID" 2>/dev/null; then
    kill "$WASH_PID" 2>/dev/null || true
    wait "$WASH_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Wait for readiness: first HTTP 200
echo "[measure] waiting for HTTP 200 from wasmCloud app..." | tee -a "$LOG_FILE"
retries=0
max_retries=600  # ~6 seconds
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
  echo "[measure] ERROR: wasmCloud app did not become ready in time" | tee -a "$LOG_FILE"
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
