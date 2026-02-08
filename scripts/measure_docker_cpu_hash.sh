#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE_NAME="cpu-hash"
WORK_DIR="$ROOT_DIR/workloads/cpu-hash"
RESULTS_DIR="$ROOT_DIR/results/raw/docker/cpu-hash"

mkdir -p "$RESULTS_DIR"

if ! command -v gdate >/dev/null 2>&1; then
  echo "ERROR: gdate not found. Install coreutils with:" >&2
  echo "  brew install coreutils" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found. Install Docker Desktop." >&2
  exit 1
fi

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"

echo "DOCKER_COLD=${DOCKER_COLD:-0}" | tee -a "$LOG_FILE"
echo "DOCKER_PRUNE=${DOCKER_PRUNE:-0}" | tee -a "$LOG_FILE"

if [[ "${DOCKER_PRUNE:-0}" == "1" ]]; then
  echo "[measure] DOCKER_PRUNE=1: running 'docker system prune -af' (destructive)" | tee -a "$LOG_FILE"
  docker system prune -af || true
fi

if [[ "${DOCKER_COLD:-0}" == "1" ]]; then
  echo "[measure] DOCKER_COLD=1: removing existing image '$IMAGE_NAME' (if any)" | tee -a "$LOG_FILE"
  docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true
fi

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "[measure] Docker image '$IMAGE_NAME' not found, building..." | tee -a "$LOG_FILE"
  if [[ "${DOCKER_COLD:-0}" == "1" ]]; then
    (cd "$WORK_DIR" && docker build --no-cache --pull -t "$IMAGE_NAME" .)
  else
    (cd "$WORK_DIR" && docker build -t "$IMAGE_NAME" .)
  fi
fi

ITERATIONS="${ITERATIONS:-2000000}"

echo "==== docker cpu-hash run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "image: $IMAGE_NAME" | tee -a "$LOG_FILE"
echo "iterations: $ITERATIONS" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"
echo "docker_version: $(docker --version)" | tee -a "$LOG_FILE"

N_RUN=20
echo "[measure] running ${N_RUN} executions..." | tee -a "$LOG_FILE"

for i in $(seq 1 "$N_RUN"); do
  t0_ns=$(gdate +%s%N)
  out=$(docker run --rm "$IMAGE_NAME" "$ITERATIONS" 2>&1)
  t1_ns=$(gdate +%s%N)

  elapsed_ns=$((t1_ns - t0_ns))
  elapsed_ms=$(awk "BEGIN { printf \"%.3f\", $elapsed_ns/1000000 }")

  internal_ms=$(echo "$out" | sed -n 's/.*elapsed_ms=\([0-9.]\+\).*/\1/p')

  echo "run=${i} outer_ms=${elapsed_ms} inner_ms=${internal_ms:-NA} out=\"${out}\"" \
    | tee -a "$LOG_FILE"
done

echo "[measure] finished run, logs in: $LOG_FILE"
