#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE_NAME="http-hello-native"
RESULTS_DIR="$ROOT_DIR/results/raw/docker/http-hello"

mkdir -p "$RESULTS_DIR"

# Check gdate
if ! command -v gdate >/dev/null 2>&1; then
  echo "ERROR: gdate not found. Install coreutils with:" >&2
  echo "  brew install coreutils" >&2
  exit 1
fi

# Ensure image exists (build if needed)
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "[measure] Docker image '$IMAGE_NAME' not found, building..."
  (cd "$ROOT_DIR/workloads/http-hello" && docker build -t "$IMAGE_NAME" .)
fi

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

PORT=8080
URL="http://127.0.0.1:${PORT}/"

echo "==== docker http-hello run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "image: $IMAGE_NAME" | tee -a "$LOG_FILE"
echo "url: $URL" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"

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

# Wait for readiness: first HTTP 200
echo "[measure] waiting for HTTP 200 from container..." | tee -a "$LOG_FILE"
retries=0
max_retries=300  # ~3s
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
  echo "[measure] ERROR: container did not become ready in time" | tee -a "$LOG_FILE"
  exit 1
fi

cold_start_ns=$((t_ready_ns - t0_ns))
cold_start_ms=$(awk "BEGIN { printf \"%.3f\", $cold_start_ns/1000000 }")

echo "[measure] cold_start_ns=${cold_start_ns}" | tee -a "$LOG_FILE"
echo "[measure] cold_start_ms=${cold_start_ms}" | tee -a "$LOG_FILE"

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

echo "[measure] finished run, logs in: $LOG_FILE"
