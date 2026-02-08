#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMP_DIR="$ROOT_DIR/workloads/wasmcloud-http-hello"
COMP_WASM="$COMP_DIR/build/http_hello_world_s.wasm"

RESULTS_DIR="$ROOT_DIR/results/raw/wasmtime/http-hello"
mkdir -p "$RESULTS_DIR"

if [[ ! -f "$COMP_WASM" ]]; then
  echo "ERROR: component wasm not found: $COMP_WASM" >&2
  echo "Build it first with:" >&2
  echo "  (cd workloads/wasmcloud-http-hello && wash build)" >&2
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

PORT="${PORT:-8001}"
PATH_SUFFIX="${PATH_SUFFIX:-/}"
if [[ "$PATH_SUFFIX" != /* ]]; then
  PATH_SUFFIX="/${PATH_SUFFIX}"
fi
URL="http://127.0.0.1:${PORT}${PATH_SUFFIX}"

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"
SERVER_LOG="$RESULTS_DIR/${RUN_TS}_wasmtime_serve.log"

CACHE_MODE="${WASMTIME_CACHE_MODE:-cold}"
CACHE_BASE="$RESULTS_DIR/${RUN_TS}_cache"
mkdir -p "$CACHE_BASE"
cache_dir="$CACHE_BASE/cold"
if [[ "$CACHE_MODE" == "warm" ]]; then
  cache_dir="$CACHE_BASE/warm_shared"
fi
mkdir -p "$cache_dir"

echo "==== wasmtime http-hello run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "component_wasm: $COMP_WASM" | tee -a "$LOG_FILE"
echo "url: $URL" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"
echo "firewall_mode: ${FIREWALL_MODE:-unknown}" | tee -a "$LOG_FILE"
echo "wasmtime_cache_mode: $CACHE_MODE" | tee -a "$LOG_FILE"
echo "wasmtime_cache_dir: $cache_dir" | tee -a "$LOG_FILE"
echo "wasmtime_version: $(wasmtime --version)" | tee -a "$LOG_FILE"

echo "[measure] starting wasmtime serve..." | tee -a "$LOG_FILE"
t0_ns=$(gdate +%s%N)

WASMTIME_CACHE_DIR="$cache_dir" wasmtime serve -Scommon --addr "127.0.0.1:${PORT}" "$COMP_WASM" >"$SERVER_LOG" 2>&1 &
SERVE_PID=$!

cleanup() {
  if kill -0 "$SERVE_PID" 2>/dev/null; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

record_resources() {
  local pid=$1
  local rss_kb cpu_pct
  rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
  cpu_pct=$(ps -o %cpu= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {printf "%.2f", sum+0}')
  echo "[measure] rss_kb=${rss_kb} cpu_pct=${cpu_pct}" | tee -a "$LOG_FILE"
}

echo "[measure] waiting for HTTP 200 from wasmtime..." | tee -a "$LOG_FILE"
retries=0
max_retries=600
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
  echo "[measure] ERROR: wasmtime did not become ready in time" | tee -a "$LOG_FILE"
  exit 1
fi

cold_start_ns=$((t_ready_ns - t0_ns))
cold_start_ms=$(awk "BEGIN { printf \"%.3f\", $cold_start_ns/1000000 }")

echo "[measure] cold_start_ns=${cold_start_ns}" | tee -a "$LOG_FILE"
echo "[measure] cold_start_ms=${cold_start_ms}" | tee -a "$LOG_FILE"

# Warm-up requests (not measured)
WARMUP_REQ="${WARMUP_REQ:-5}"
echo "[measure] warmup_requests=${WARMUP_REQ}" | tee -a "$LOG_FILE"
if (( WARMUP_REQ > 0 )); then
  for _ in $(seq 1 "$WARMUP_REQ"); do
    curl -sS -o /dev/null "$URL" >/dev/null 2>&1 || true
  done
fi

record_resources "$SERVE_PID"

# Latency test
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
