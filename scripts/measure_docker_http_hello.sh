#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/common.sh"

IMAGE_NAME="http-hello-native"
RESULTS_DIR="$ROOT_DIR/results/raw/docker/http-hello"

mkdir -p "$RESULTS_DIR"

# Check gdate
check_gdate || exit 1

# Prepare run timestamp and log early so pre-build steps are recorded
RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

# Optional: perform a fuller "cold" run. Set env var `DOCKER_COLD=1` to
# remove any existing image and build with `--no-cache --pull` so layer
# caches are not reused. Set `DOCKER_PRUNE=1` to run `docker system prune -af`
# before building (destructive; use with care).
echo "DOCKER_COLD=${DOCKER_COLD:-0}" | tee -a "$LOG_FILE"
echo "DOCKER_PRUNE=${DOCKER_PRUNE:-0}" | tee -a "$LOG_FILE"

if [[ "${DOCKER_PRUNE:-0}" == "1" ]]; then
  echo "[measure] DOCKER_PRUNE=1: running 'docker system prune -af' (destructive)" | tee -a "$LOG_FILE"
  docker system prune -af || true
fi

# If DOCKER_COLD is set, remove any existing image so build is truly cold
if [[ "${DOCKER_COLD:-0}" == "1" ]]; then
  echo "[measure] DOCKER_COLD=1: removing existing image '$IMAGE_NAME' (if any)" | tee -a "$LOG_FILE"
  docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true
fi

# Ensure image exists (build if needed). When DOCKER_COLD=1, build with no cache and pull latest base images.
build_opts=()
if [[ "${DOCKER_COLD:-0}" == "1" ]]; then
  build_opts+=(--no-cache --pull)
fi

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "[measure] Docker image '$IMAGE_NAME' not found, building..." | tee -a "$LOG_FILE"
  (cd "$ROOT_DIR/workloads/http-hello" && docker build "${build_opts[@]}" -t "$IMAGE_NAME" .)
fi

PORT=8080
PATH_SUFFIX="${PATH_SUFFIX:-/}"
if [[ "$PATH_SUFFIX" != /* ]]; then
  PATH_SUFFIX="/${PATH_SUFFIX}"
fi
URL="http://127.0.0.1:${PORT}${PATH_SUFFIX}"

echo "==== docker http-hello run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "image: $IMAGE_NAME" | tee -a "$LOG_FILE"
echo "url: $URL" | tee -a "$LOG_FILE"
log_versions "$LOG_FILE"

# Start container
echo "[measure] starting container..." | tee -a "$LOG_FILE"
t0_ns=$(gdate +%s%N)

CONTAINER_ID=$(docker run -d --rm -p "${PORT}:8080" "$IMAGE_NAME")

cleanup() {
  if [[ -n "${CONTAINER_ID:-}" ]]; then
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

to_bytes() {
  local v=$1
  local num unit factor
  num=$(echo "$v" | sed -E 's/([0-9.]+).*/\1/')
  unit=$(echo "$v" | sed -E 's/[0-9.]+([A-Za-z]+).*/\1/')
  case "$unit" in
    B) factor=1 ;;
    KiB|KB) factor=1024 ;;
    MiB|MB) factor=$((1024 * 1024)) ;;
    GiB|GB) factor=$((1024 * 1024 * 1024)) ;;
    TiB|TB) factor=$((1024 * 1024 * 1024 * 1024)) ;;
    *) factor=1 ;;
  esac
  awk -v n="$num" -v f="$factor" 'BEGIN { printf "%d", n*f }'
}

record_docker_resources() {
  local container_id=$1
  local log_file=$2
  local stats mem_used cpu_pct mem_bytes rss_kb
  stats=$(docker stats --no-stream --format "{{.MemUsage}} {{.CPUPerc}}" "$container_id" 2>/dev/null || true)
  mem_used=$(echo "$stats" | awk '{print $1}')
  cpu_pct=$(echo "$stats" | awk '{print $2}')
  cpu_pct=${cpu_pct%\%}
  mem_bytes=$(to_bytes "${mem_used:-0B}")
  rss_kb=$(awk -v b="$mem_bytes" 'BEGIN { printf "%d", b/1024 }')
  echo "[measure] rss_kb=${rss_kb} cpu_pct=${cpu_pct:-0}" | tee -a "$log_file"
}

# Wait for readiness: first HTTP 200
wait_for_http_ready "$URL" "$LOG_FILE" "$t0_ns" 300 || exit 1

# Warm-up requests (not measured)
WARMUP_REQ="${WARMUP_REQ:-5}"
run_warmup_requests "$URL" "$WARMUP_REQ" "$LOG_FILE"

record_docker_resources "$CONTAINER_ID" "$LOG_FILE"

# Latency test
N_REQ=50
measure_latency_sequential "$URL" "$N_REQ" "$LOG_FILE"

THROUGHPUT_REQS="${THROUGHPUT_REQS:-200}"
THROUGHPUT_CONC="${THROUGHPUT_CONC:-10}"
if (( THROUGHPUT_REQS > 0 )); then
  measure_throughput_concurrent "$URL" "$THROUGHPUT_REQS" "$THROUGHPUT_CONC" "$LOG_FILE"
fi

echo "[measure] finished run, logs in: $LOG_FILE"
