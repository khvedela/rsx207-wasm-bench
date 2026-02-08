#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/common.sh"

RUNTIME="${RUNTIME:-${1:-}}"
if [[ -z "${RUNTIME}" ]]; then
  echo "Usage: $0 <native|docker|wasmtime|wasmcloud-component>" >&2
  echo "  or set RUNTIME=native|docker|wasmtime|wasmcloud-component" >&2
  exit 1
fi

check_gdate || exit 1

CONCURRENCY_LIST="${CONCURRENCY_LIST:-1 2 4 8}"
N_RUN="${N_RUN:-5}"
BASE_PORT=8000
REQUESTS_PER_INSTANCE="${REQUESTS_PER_INSTANCE:-200}"
BOMBARDIER_CONC="${BOMBARDIER_CONC:-10}"

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
RESULTS_DIR="$ROOT_DIR/results/raw/${RUNTIME}/http-hello-scaling"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"
MEMORY_CSV="$RESULTS_DIR/${RUN_TS}_memory.csv"

mkdir -p "$RESULTS_DIR"

IMAGE_NAME="http-hello-native"
WORK_DIR="$ROOT_DIR/workloads/http-hello"
BIN="$ROOT_DIR/workloads/http-hello/target/release/http-hello"
WASM_MOD="$ROOT_DIR/workloads/http-hello/target/release/http-hello.wasm"
WASMCLOUD_DIR="$ROOT_DIR/workloads/wasmcloud-http-hello"

# Check bombardier availability
if ! command -v bombardier >/dev/null 2>&1; then
  echo "ERROR: bombardier not found. Install with:" >&2
  echo "  brew install bombardier" >&2
  echo "  or: go install github.com/codesenberg/bombardier@latest" >&2
  exit 1
fi

start_server_instance() {
  local port=$1
  local instance_num=$2
  local log_file=$3
  
  case "$RUNTIME" in
    native)
      PORT=$port "$BIN" >"${log_file}" 2>&1 &
      echo $!
      ;;
    docker)
      local container_id=$(docker run -d --rm -p "${port}:8080" "$IMAGE_NAME" 2>&1)
      echo "$container_id"
      ;;
    wasmtime)
      wasmtime serve -Scommon --addr "127.0.0.1:${port}" "$WASM_MOD" >"${log_file}" 2>&1 &
      echo $!
      ;;
    wasmcloud-component)
      # wasmCloud requires a full WADM manifest with different ports
      echo "ERROR: wasmcloud-component scaling not yet supported (requires dynamic port configuration)" >&2
      return 1
      ;;
    *)
      echo "ERROR: unknown runtime: $RUNTIME" >&2
      return 1
      ;;
  esac
}

stop_server_instance() {
  local id=$1
  
  case "$RUNTIME" in
    native|wasmtime)
      cleanup_process "$id"
      ;;
    docker)
      docker stop "$id" >/dev/null 2>&1 || true
      ;;
    *)
      ;;
  esac
}

get_server_pids() {
  local id=$1
  
  case "$RUNTIME" in
    native|wasmtime)
      echo "$id"
      ;;
    docker)
      # Get PID from container
      docker inspect -f '{{.State.Pid}}' "$id" 2>/dev/null || echo "0"
      ;;
    *)
      echo "0"
      ;;
  esac
}

prepare_runtime() {
  case "$RUNTIME" in
    native)
      if [[ ! -x "$BIN" ]]; then
        echo "ERROR: binary not found or not executable: $BIN" >&2
        echo "Build it first with:" >&2
        echo "  (cd workloads/http-hello && cargo build --release)" >&2
        exit 1
      fi
      ;;
    docker)
      if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found. Install Docker Desktop." >&2
        exit 1
      fi

      echo "DOCKER_COLD=${DOCKER_COLD:-0}" | tee -a "$LOG_FILE"

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
      ;;
    wasmtime)
      if [[ ! -f "$WASM_MOD" ]]; then
        echo "ERROR: wasm component not found: $WASM_MOD" >&2
        echo "Build it first with:" >&2
        echo "  (cd workloads/http-hello && cargo build --release)" >&2
        exit 1
      fi

      if ! command -v wasmtime >/dev/null 2>&1; then
        echo "ERROR: wasmtime not found. Install with:" >&2
        echo "  brew install wasmtime" >&2
        exit 1
      fi
      ;;
    wasmcloud-component)
      echo "ERROR: wasmcloud-component scaling not yet fully supported" >&2
      echo "  wasmCloud requires WADM manifest configuration for multi-instance deployment" >&2
      exit 1
      ;;
    *)
      echo "ERROR: unknown runtime: $RUNTIME" >&2
      exit 1
      ;;
  esac
}

echo "==== http-hello scaling run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "runtime: $RUNTIME" | tee -a "$LOG_FILE"
echo "concurrency_list: $CONCURRENCY_LIST" | tee -a "$LOG_FILE"
echo "runs_per_conc: $N_RUN" | tee -a "$LOG_FILE"
echo "base_port: $BASE_PORT" | tee -a "$LOG_FILE"
echo "requests_per_instance: $REQUESTS_PER_INSTANCE" | tee -a "$LOG_FILE"
echo "bombardier_concurrency: $BOMBARDIER_CONC" | tee -a "$LOG_FILE"

log_versions "$LOG_FILE"

prepare_runtime

echo "[measure] scaling test: ${N_RUN} runs per concurrency" | tee -a "$LOG_FILE"

# Initialize memory CSV
echo "run,concurrency,instance,timestamp_ms,rss_kb,cpu_pct" > "$MEMORY_CSV"

for conc in $CONCURRENCY_LIST; do
  for run in $(seq 1 "$N_RUN"); do
    echo "[measure] === Run ${run}/${N_RUN}, Concurrency ${conc} ===" | tee -a "$LOG_FILE"
    
    tmp_dir="$(mktemp -d)"
    server_ids=()
    server_pids=()
    ports=()
    memory_monitor_pids=()
    
    # Start all server instances
    for i in $(seq 1 "$conc"); do
      port=$((BASE_PORT + i - 1))
      ports+=("$port")
      log_file="$tmp_dir/server_${i}.log"
      
      echo "[measure] Starting instance ${i}/${conc} on port ${port}..." | tee -a "$LOG_FILE"
      server_id=$(start_server_instance "$port" "$i" "$log_file")
      server_ids+=("$server_id")
      
      # Get actual PID for monitoring
      server_pid=$(get_server_pids "$server_id")
      server_pids+=("$server_pid")
      
      # Wait for server to be ready
      url="http://127.0.0.1:${port}/"
      retries=0
      max_retries=200
      ready=0
      
      while (( retries < max_retries )); do
        http_code=$(curl -sS -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
          ready=1
          break
        fi
        retries=$((retries + 1))
        sleep 0.01
      done
      
      if (( ready == 0 )); then
        echo "[measure] ERROR: instance ${i} on port ${port} did not become ready" | tee -a "$LOG_FILE"
        # Cleanup and exit
        for sid in "${server_ids[@]}"; do
          stop_server_instance "$sid"
        done
        rm -rf "$tmp_dir"
        exit 1
      fi
      
      echo "[measure] Instance ${i} ready on port ${port}" | tee -a "$LOG_FILE"
      
      # Start continuous memory monitoring for this instance
      if [[ "$server_pid" != "0" ]]; then
        (
          while kill -0 "$server_pid" 2>/dev/null; do
            ts_ms=$(gdate +%s%3N)
            rss_kb=$(ps -o rss= -p "$server_pid" 2>/dev/null | awk '{print $1+0}')
            cpu_pct=$(ps -o %cpu= -p "$server_pid" 2>/dev/null | awk '{printf "%.2f", $1+0}')
            echo "${run},${conc},${i},${ts_ms},${rss_kb},${cpu_pct}" >> "$MEMORY_CSV"
            sleep 0.5
          done
        ) &
        memory_monitor_pids+=($!)
      fi
    done
    
    # All instances ready, run load test
    echo "[measure] All ${conc} instances ready, starting load test..." | tee -a "$LOG_FILE"
    
    # Warm up all instances
    for port in "${ports[@]}"; do
      for _ in {1..5}; do
        curl -sS -o /dev/null "http://127.0.0.1:${port}/" >/dev/null 2>&1 || true
      done
    done
    
    # Run bombardier against all instances in parallel
    t0_ns=$(gdate +%s%N)
    bombardier_pids=()
    
    for i in $(seq 1 "$conc"); do
      port="${ports[$((i-1))]}"
      result_file="$tmp_dir/bombardier_${i}.json"
      
      bombardier \
        -c "$BOMBARDIER_CONC" \
        -n "$REQUESTS_PER_INSTANCE" \
        -l \
        -o json \
        -p r \
        "http://127.0.0.1:${port}/" > "$result_file" 2>&1 &
      
      bombardier_pids+=($!)
    done
    
    # Wait for all bombardier instances to complete
    failures=0
    for pid in "${bombardier_pids[@]}"; do
      if ! wait "$pid"; then
        failures=$((failures + 1))
      fi
    done
    
    t1_ns=$(gdate +%s%N)
    elapsed_ns=$((t1_ns - t0_ns))
    elapsed_ms=$(awk "BEGIN { printf \"%.3f\", $elapsed_ns/1000000 }")
    elapsed_s=$(awk "BEGIN { printf \"%.6f\", $elapsed_ns/1000000000 }")
    
    # Calculate aggregate metrics
    total_requests=$((REQUESTS_PER_INSTANCE * conc))
    throughput_rps=$(awk -v req="$total_requests" -v s="$elapsed_s" 'BEGIN { if (s>0) printf "%.3f", req/s; else print "0" }')
    
    # Record final resource usage
    total_rss_kb=0
    for pid in "${server_pids[@]}"; do
      if [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
        rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1+0}')
        total_rss_kb=$((total_rss_kb + rss_kb))
      fi
    done
    
    avg_rss_kb=$((total_rss_kb / conc))
    
    echo "run=${run} conc=${conc} total_requests=${total_requests} elapsed_ms=${elapsed_ms} throughput_rps=${throughput_rps} total_rss_kb=${total_rss_kb} avg_rss_kb=${avg_rss_kb} failures=${failures}" \
      | tee -a "$LOG_FILE"
    
    # Parse bombardier results for detailed metrics
    for i in $(seq 1 "$conc"); do
      result_file="$tmp_dir/bombardier_${i}.json"
      if [[ -f "$result_file" ]]; then
        # Extract key metrics from JSON (using grep/awk for portability)
        rps=$(grep -o '"rps":[0-9.]*' "$result_file" | head -1 | cut -d: -f2)
        avg_lat=$(grep -o '"mean":[0-9]*' "$result_file" | head -1 | cut -d: -f2)
        p50_lat=$(grep -o '"percentiles":{"50":[0-9]*' "$result_file" | cut -d: -f3)
        p95_lat=$(grep -o '"95":[0-9]*' "$result_file" | head -1 | cut -d: -f2)
        p99_lat=$(grep -o '"99":[0-9]*' "$result_file" | head -1 | cut -d: -f2)
        
        echo "instance=${i} rps=${rps:-0} avg_lat_ns=${avg_lat:-0} p50_lat_ns=${p50_lat:-0} p95_lat_ns=${p95_lat:-0} p99_lat_ns=${p99_lat:-0}" \
          | tee -a "$LOG_FILE"
      fi
    done
    
    # Stop memory monitors
    for mpid in "${memory_monitor_pids[@]}"; do
      kill "$mpid" 2>/dev/null || true
    done
    
    # Stop all servers
    for server_id in "${server_ids[@]}"; do
      stop_server_instance "$server_id"
    done
    
    # Cleanup temp directory
    rm -rf "$tmp_dir"
    
    # Brief pause between runs
    sleep 2
  done
done

echo "[measure] finished run, logs in: $LOG_FILE"
echo "[measure] memory data in: $MEMORY_CSV"
