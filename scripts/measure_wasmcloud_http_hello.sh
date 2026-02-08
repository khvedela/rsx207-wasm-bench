#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMP_DIR="$ROOT_DIR/workloads/wasmcloud-http-hello"
APP_MANIFEST="$COMP_DIR/local.wadm.yaml"
RESULTS_DIR="$ROOT_DIR/results/raw/wasmcloud/http-hello"

mkdir -p "$RESULTS_DIR"

if [[ ! -d "$COMP_DIR" ]]; then
  echo "ERROR: wasmcloud-http-hello component dir not found: $COMP_DIR" >&2
  echo "Create it with:" >&2
  echo "  (cd workloads && wash new component wasmcloud-http-hello --template-name hello-world-rust)" >&2
  exit 1
fi

if [[ ! -f "$APP_MANIFEST" ]]; then
  echo "ERROR: app manifest not found: $APP_MANIFEST" >&2
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
WASH_UP_LOG="$RESULTS_DIR/${RUN_TS}_wash_up.log"
WASMCLOUD_LOG_COPY="$RESULTS_DIR/${RUN_TS}_wasmcloud.log"
WADM_LOG_COPY="$RESULTS_DIR/${RUN_TS}_wadm.log"
NATS_LOG_COPY="$RESULTS_DIR/${RUN_TS}_nats.log"

PORT=8000
PATH_SUFFIX="${PATH_SUFFIX:-/}"
if [[ "$PATH_SUFFIX" != /* ]]; then
  PATH_SUFFIX="/${PATH_SUFFIX}"
fi
URL="http://127.0.0.1:${PORT}${PATH_SUFFIX}"

echo "==== wasmCloud http-hello run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "component_dir: $COMP_DIR" | tee -a "$LOG_FILE"
echo "url: $URL" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"
echo "firewall_mode: ${FIREWALL_MODE:-unknown}" | tee -a "$LOG_FILE"
echo "wash_version: $(wash --version)" | tee -a "$LOG_FILE"

wash_down_all() {
  local purge_mode="${1:-none}"
  local host_ids=""

  if ! command -v wash >/dev/null 2>&1; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    host_ids=$(wash get hosts -o json 2>/dev/null | python3 - <<'PY' || true
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

hosts = data.get("hosts") or []
print(" ".join([h.get("id", "") for h in hosts if h.get("id")]))
PY
    )
  fi

  if [[ -z "$host_ids" ]]; then
    wash down --purge-jetstream "$purge_mode" >/dev/null 2>&1 || true
    return 0
  fi

  for host_id in $host_ids; do
    wash down --host-id "$host_id" --purge-jetstream "$purge_mode" >/dev/null 2>&1 || true
  done
}

cleanup() {
  local wasmcloud_log_src="${HOME}/.wash/downloads/wasmcloud.log"
  local wadm_log_src="${HOME}/.wash/downloads/wadm.log"
  local nats_log_src="${HOME}/.wash/downloads/nats.log"

  if [[ -f "$wasmcloud_log_src" ]]; then
    cp "$wasmcloud_log_src" "$WASMCLOUD_LOG_COPY"
  fi
  if [[ -f "$wadm_log_src" ]]; then
    cp "$wadm_log_src" "$WADM_LOG_COPY"
  fi
  if [[ -f "$nats_log_src" ]]; then
    cp "$nats_log_src" "$NATS_LOG_COPY"
  fi

  wash_down_all "${WASMCLOUD_PURGE_ON_EXIT:-none}"
}
trap cleanup EXIT

# Start wash up (detached) and deploy the manifest
echo "[measure] starting wash up..." | tee -a "$LOG_FILE"
t0_ns=$(gdate +%s%N)

if ! (cd "$ROOT_DIR" && wash up --detached --wadm-manifest "$APP_MANIFEST") >"$WASH_UP_LOG" 2>&1; then
  echo "[measure] ERROR: wash up failed" | tee -a "$LOG_FILE"
  tail -n 80 "$WASH_UP_LOG" | tee -a "$LOG_FILE"
  exit 1
fi

deploy_retries=0
deploy_max_retries=40
deployed=0
while (( deploy_retries < deploy_max_retries )); do
  if wash app deploy "$APP_MANIFEST" --replace >>"$LOG_FILE" 2>&1; then
    deployed=1
    break
  fi
  deploy_retries=$((deploy_retries + 1))
  sleep 0.5
done

if (( deployed == 0 )); then
  echo "[measure] ERROR: failed to deploy app manifest after retries" | tee -a "$LOG_FILE"
  exit 1
fi

collect_pids() {
  local pids=()
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "wasmcloud" 2>/dev/null || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "nats-server" 2>/dev/null || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "wadm" 2>/dev/null || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "http-server-provider" 2>/dev/null || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "ghcr_io_w" 2>/dev/null || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)

  printf "%s\n" "${pids[@]}" | awk '!seen[$0]++' | tr '\n' ' '
}

record_resources() {
  local pids pid_list rss_kb cpu_pct
  pids=$(collect_pids)
  pid_list=$(echo "$pids" | tr ' ' ',')

  if [[ -z "$pid_list" ]]; then
    echo "[measure] rss_kb=0 cpu_pct=0.00" | tee -a "$LOG_FILE"
    return 0
  fi

  rss_kb=$(ps -o rss= -p "$pid_list" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
  cpu_pct=$(ps -o %cpu= -p "$pid_list" 2>/dev/null | awk '{sum+=$1} END {printf "%.2f", sum+0}')
  echo "[measure] rss_kb=${rss_kb} cpu_pct=${cpu_pct}" | tee -a "$LOG_FILE"
}

dump_diagnostics() {
  echo "[measure] diagnostics: wash app status" | tee -a "$LOG_FILE"
  wash app status rust-hello-world >>"$LOG_FILE" 2>&1 || true
  echo "[measure] diagnostics: wash get inventory" | tee -a "$LOG_FILE"
  wash get inventory >>"$LOG_FILE" 2>&1 || true
  echo "[measure] diagnostics: lsof port $PORT" | tee -a "$LOG_FILE"
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >>"$LOG_FILE" 2>&1 || true
  echo "[measure] diagnostics: tail wasmcloud log" | tee -a "$LOG_FILE"
  tail -n 60 "${HOME}/.wash/downloads/wasmcloud.log" >>"$LOG_FILE" 2>&1 || true
  echo "[measure] diagnostics: tail wadm log" | tee -a "$LOG_FILE"
  tail -n 60 "${HOME}/.wash/downloads/wadm.log" >>"$LOG_FILE" 2>&1 || true
  echo "[measure] diagnostics: tail nats log" | tee -a "$LOG_FILE"
  tail -n 60 "${HOME}/.wash/downloads/nats.log" >>"$LOG_FILE" 2>&1 || true
}

# Wait for readiness: first HTTP 200
echo "[measure] waiting for HTTP 200 from wasmCloud app..." | tee -a "$LOG_FILE"
retries=0
max_retries="${MAX_RETRIES:-2000}"  # ~20 seconds by default
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
  echo "[measure] last wash up output:" | tee -a "$LOG_FILE"
  tail -n 60 "$WASH_UP_LOG" | tee -a "$LOG_FILE"
  dump_diagnostics
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

record_resources

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
