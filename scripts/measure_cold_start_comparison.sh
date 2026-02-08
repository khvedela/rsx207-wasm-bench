#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cold Start Comparison: Docker vs Wasmtime
# =============================================================================
# Measures cold starts for fair real-world comparison.
#
# SCENARIOS:
#   Full Cold:    Build from source (no cache) + start runtime
#                 - Docker: docker build --no-cache + docker run
#                 - Wasmtime: wash build (from scratch) + wasmtime serve
#
#   Runtime Cold: Pre-built artifact, fresh process start (typical serverless)
#                 - Docker: docker run (image cached)
#                 - Wasmtime: wasmtime serve (component cached)
#
# Usage:
#   ./measure_cold_start_comparison.sh [N_RUNS]
#
# Environment variables:
#   SKIP_DOCKER=1     - Skip Docker measurements
#   SKIP_WASMTIME=1   - Skip Wasmtime measurements
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

N_RUNS="${1:-10}"

RESULTS_DIR="$ROOT_DIR/results/raw/cold-start-comparison"
mkdir -p "$RESULTS_DIR"

# Ports
DOCKER_PORT=8080
WASMTIME_PORT=8000

# Image/component paths
DOCKER_IMAGE="http-hello-native"
DOCKER_DIR="$ROOT_DIR/workloads/http-hello"
WASM_DIR="$ROOT_DIR/workloads/wasmcloud-http-hello"
WASM_FILE="$WASM_DIR/build/http_hello_world_s.wasm"

# Wasmtime cache behavior (cold = fresh cache per run, warm = shared cache)
WASMTIME_CACHE_MODE="${WASMTIME_CACHE_MODE:-cold}"

# Check prerequisites
check_prerequisites() {
  local missing=()

  if ! command -v gdate >/dev/null 2>&1; then
    missing+=("gdate (brew install coreutils)")
  fi

  if ! command -v docker >/dev/null 2>&1; then
    missing+=("docker")
  fi

  if ! command -v wasmtime >/dev/null 2>&1; then
    missing+=("wasmtime (brew install wasmtime)")
  fi

  if ! command -v wash >/dev/null 2>&1; then
    missing+=("wash (brew install wasmcloud/wasmcloud/wash)")
  fi

  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: Missing prerequisites:" >&2
    printf "  - %s\n" "${missing[@]}" >&2
    exit 1
  fi
}

# Kill any processes using a port
kill_port() {
  local port=$1
  local pids
  pids=$(lsof -ti :"$port" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 0.2
    pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      kill -9 $pids 2>/dev/null || true
    fi
  fi
}

# Wait for HTTP 200
wait_for_http() {
  local url=$1
  local max_retries=${2:-600}
  local retries=0

  while (( retries < max_retries )); do
    if curl -sS -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "200"; then
      return 0
    fi
    retries=$((retries + 1))
    sleep 0.01
  done
  return 1
}

# =============================================================================
# Docker measurements
# =============================================================================

# Docker FULL COLD: Remove image, rebuild with --no-cache, run container
measure_docker_full_cold() {
  local run_num=$1
  local log_file=$2

  echo "[docker-full-cold] Run $run_num" | tee -a "$log_file"

  # Stop any running containers
  containers=$(docker ps -q --filter "publish=$DOCKER_PORT" 2>/dev/null || true)
  if [[ -n "$containers" ]]; then
    docker stop $containers >/dev/null 2>&1 || true
  fi
  kill_port "$DOCKER_PORT"
  sleep 0.3

  # Remove image for truly cold start
  docker image rm -f "$DOCKER_IMAGE" >/dev/null 2>&1 || true

  # Measure: build + run
  t0_ns=$(gdate +%s%N)

  docker build --no-cache -t "$DOCKER_IMAGE" "$DOCKER_DIR" >/dev/null 2>&1

  t_built_ns=$(gdate +%s%N)

  container_id=$(docker run -d --rm -p "${DOCKER_PORT}:8080" "$DOCKER_IMAGE")

  if ! wait_for_http "http://127.0.0.1:${DOCKER_PORT}/" 600; then
    echo "[docker-full-cold] ERROR: container did not become ready" | tee -a "$log_file"
    docker stop "$container_id" >/dev/null 2>&1 || true
    return 1
  fi

  t_ready_ns=$(gdate +%s%N)

  build_ms=$(awk "BEGIN { printf \"%.3f\", ($t_built_ns - $t0_ns)/1000000 }")
  start_ms=$(awk "BEGIN { printf \"%.3f\", ($t_ready_ns - $t_built_ns)/1000000 }")
  total_ms=$(awk "BEGIN { printf \"%.3f\", ($t_ready_ns - $t0_ns)/1000000 }")

  echo "[docker-full-cold] build_ms=$build_ms start_ms=$start_ms total_ms=$total_ms" | tee -a "$log_file"
  echo "docker,full_cold,$run_num,$build_ms,$start_ms,$total_ms" >> "$RESULTS_DIR/cold_start_data.csv"

  docker stop "$container_id" >/dev/null 2>&1 || true
  sleep 0.3
}

# Docker RUNTIME COLD: Image cached, just start container (typical serverless cold start)
measure_docker_runtime_cold() {
  local run_num=$1
  local log_file=$2

  echo "[docker-runtime-cold] Run $run_num" | tee -a "$log_file"

  # Stop any running containers but keep image
  containers=$(docker ps -q --filter "publish=$DOCKER_PORT" 2>/dev/null || true)
  if [[ -n "$containers" ]]; then
    docker stop $containers >/dev/null 2>&1 || true
  fi
  kill_port "$DOCKER_PORT"
  sleep 0.3

  # Ensure image exists (should be cached from full cold run)
  if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    docker build -t "$DOCKER_IMAGE" "$DOCKER_DIR" >/dev/null 2>&1
  fi

  # Measure: container start only
  t0_ns=$(gdate +%s%N)

  container_id=$(docker run -d --rm -p "${DOCKER_PORT}:8080" "$DOCKER_IMAGE")

  if ! wait_for_http "http://127.0.0.1:${DOCKER_PORT}/" 600; then
    echo "[docker-runtime-cold] ERROR: container did not become ready" | tee -a "$log_file"
    docker stop "$container_id" >/dev/null 2>&1 || true
    return 1
  fi

  t_ready_ns=$(gdate +%s%N)

  start_ms=$(awk "BEGIN { printf \"%.3f\", ($t_ready_ns - $t0_ns)/1000000 }")

  echo "[docker-runtime-cold] start_ms=$start_ms" | tee -a "$log_file"
  echo "docker,runtime_cold,$run_num,0,$start_ms,$start_ms" >> "$RESULTS_DIR/cold_start_data.csv"

  docker stop "$container_id" >/dev/null 2>&1 || true
  sleep 0.3
}

# =============================================================================
# Wasmtime measurements
# =============================================================================

# Wasmtime FULL COLD: Rebuild component from scratch, first execution
measure_wasmtime_full_cold() {
  local run_num=$1
  local log_file=$2

  echo "[wasmtime-full-cold] Run $run_num" | tee -a "$log_file"

  kill_port "$WASMTIME_PORT"
  sleep 0.3

  # Remove build artifacts for truly cold build
  rm -rf "$WASM_DIR/build" "$WASM_DIR/target" 2>/dev/null || true

  # Measure: build + serve
  t0_ns=$(gdate +%s%N)

  (cd "$WASM_DIR" && wash build) >/dev/null 2>&1

  t_built_ns=$(gdate +%s%N)

  local cache_dir="$WASMTIME_CACHE_BASE/full_cold_run${run_num}"
  if [[ "$WASMTIME_CACHE_MODE" == "cold" ]]; then
    rm -rf "$cache_dir" 2>/dev/null || true
    mkdir -p "$cache_dir"
  else
    cache_dir="$WASMTIME_CACHE_BASE/shared"
    mkdir -p "$cache_dir"
  fi

  WASMTIME_CACHE_DIR="$cache_dir" wasmtime serve -Scommon --addr "127.0.0.1:${WASMTIME_PORT}" "$WASM_FILE" >/dev/null 2>&1 &
  serve_pid=$!

  if ! wait_for_http "http://127.0.0.1:${WASMTIME_PORT}/" 600; then
    echo "[wasmtime-full-cold] ERROR: wasmtime serve did not become ready" | tee -a "$log_file"
    kill "$serve_pid" 2>/dev/null || true
    return 1
  fi

  t_ready_ns=$(gdate +%s%N)

  build_ms=$(awk "BEGIN { printf \"%.3f\", ($t_built_ns - $t0_ns)/1000000 }")
  start_ms=$(awk "BEGIN { printf \"%.3f\", ($t_ready_ns - $t_built_ns)/1000000 }")
  total_ms=$(awk "BEGIN { printf \"%.3f\", ($t_ready_ns - $t0_ns)/1000000 }")

  echo "[wasmtime-full-cold] build_ms=$build_ms start_ms=$start_ms total_ms=$total_ms" | tee -a "$log_file"
  echo "wasmtime,full_cold,$run_num,$build_ms,$start_ms,$total_ms" >> "$RESULTS_DIR/cold_start_data.csv"

  kill "$serve_pid" 2>/dev/null || true
  sleep 0.3
}

# Wasmtime RUNTIME COLD: Component cached, just serve (typical serverless cold start)
measure_wasmtime_runtime_cold() {
  local run_num=$1
  local log_file=$2

  echo "[wasmtime-runtime-cold] Run $run_num" | tee -a "$log_file"

  kill_port "$WASMTIME_PORT"
  sleep 0.3

  # Ensure component exists (should be cached from full cold run)
  if [[ ! -f "$WASM_FILE" ]]; then
    (cd "$WASM_DIR" && wash build) >/dev/null 2>&1
  fi

  # Measure: serve only
  t0_ns=$(gdate +%s%N)

  local cache_dir="$WASMTIME_CACHE_BASE/runtime_cold_run${run_num}"
  if [[ "$WASMTIME_CACHE_MODE" == "cold" ]]; then
    rm -rf "$cache_dir" 2>/dev/null || true
    mkdir -p "$cache_dir"
  else
    cache_dir="$WASMTIME_CACHE_BASE/shared"
    mkdir -p "$cache_dir"
  fi

  WASMTIME_CACHE_DIR="$cache_dir" wasmtime serve -Scommon --addr "127.0.0.1:${WASMTIME_PORT}" "$WASM_FILE" >/dev/null 2>&1 &
  serve_pid=$!

  if ! wait_for_http "http://127.0.0.1:${WASMTIME_PORT}/" 600; then
    echo "[wasmtime-runtime-cold] ERROR: wasmtime serve did not become ready" | tee -a "$log_file"
    kill "$serve_pid" 2>/dev/null || true
    return 1
  fi

  t_ready_ns=$(gdate +%s%N)

  start_ms=$(awk "BEGIN { printf \"%.3f\", ($t_ready_ns - $t0_ns)/1000000 }")

  echo "[wasmtime-runtime-cold] start_ms=$start_ms" | tee -a "$log_file"
  echo "wasmtime,runtime_cold,$run_num,0,$start_ms,$start_ms" >> "$RESULTS_DIR/cold_start_data.csv"

  kill "$serve_pid" 2>/dev/null || true
  sleep 0.3
}

# =============================================================================
# Main
# =============================================================================
main() {
  check_prerequisites

  RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
  LOG_FILE="$RESULTS_DIR/${RUN_TS}_cold_warm.log"
  WASMTIME_CACHE_BASE="$RESULTS_DIR/${RUN_TS}_wasmtime_cache"
  mkdir -p "$WASMTIME_CACHE_BASE"

  {
    echo "=============================================="
    echo "Cold Start Comparison: Docker vs Wasmtime"
    echo "=============================================="
    echo "Runs per scenario: $N_RUNS"
    echo "Timestamp: $RUN_TS"
    echo "Results: $RESULTS_DIR"
    echo "Wasmtime cache mode: $WASMTIME_CACHE_MODE"
    echo "docker_version: $(docker --version)"
    echo "wasmtime_version: $(wasmtime --version)"
    echo "wash_version: $(wash --version)"
    echo "=============================================="
  } | tee "$LOG_FILE"

  # Initialize CSV
  echo "runtime,type,run,build_ms,start_ms,total_ms" > "$RESULTS_DIR/cold_start_data.csv"

  # --- FULL COLD STARTS (build from source) ---
  echo ""
  echo "=== FULL COLD STARTS (build from source, no cache) ===" | tee -a "$LOG_FILE"

  for i in $(seq 1 "$N_RUNS"); do
    if [[ "${SKIP_DOCKER:-0}" != "1" ]]; then
      measure_docker_full_cold "$i" "$LOG_FILE"
    fi

    if [[ "${SKIP_WASMTIME:-0}" != "1" ]]; then
      measure_wasmtime_full_cold "$i" "$LOG_FILE"
    fi
  done

  # --- RUNTIME COLD STARTS (pre-built, typical serverless) ---
  echo ""
  echo "=== RUNTIME COLD STARTS (pre-built artifact, typical serverless) ===" | tee -a "$LOG_FILE"

  for i in $(seq 1 "$N_RUNS"); do
    if [[ "${SKIP_DOCKER:-0}" != "1" ]]; then
      measure_docker_runtime_cold "$i" "$LOG_FILE"
    fi

    if [[ "${SKIP_WASMTIME:-0}" != "1" ]]; then
      measure_wasmtime_runtime_cold "$i" "$LOG_FILE"
    fi
  done

  echo ""
  echo "=============================================="
  echo "Measurement complete!"
  echo "Data: $RESULTS_DIR/cold_start_data.csv"
  echo "Log: $LOG_FILE"
  echo "=============================================="
  echo ""
  echo "Generate graphs with:"
  echo "  python3 scripts/analyze_cold_start_comparison.py"
}

main
