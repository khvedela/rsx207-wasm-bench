#!/usr/bin/env bash
# Common functions for benchmark measurement scripts

# Check if gdate is available (required for nanosecond timestamps)
check_gdate() {
  if ! command -v gdate >/dev/null 2>&1; then
    echo "ERROR: gdate not found. Install coreutils with:" >&2
    echo "  brew install coreutils" >&2
    return 1
  fi
  return 0
}

# Log system and toolchain versions
log_versions() {
  local log_file=$1
  echo "host_os: $(uname -a)" | tee -a "$log_file"
  echo "firewall_mode: ${FIREWALL_MODE:-unknown}" | tee -a "$log_file"
  
  if command -v rustc >/dev/null 2>&1; then
    echo "rustc_version: $(rustc --version)" | tee -a "$log_file"
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "docker_version: $(docker --version)" | tee -a "$log_file"
  fi
  if command -v wasmtime >/dev/null 2>&1; then
    echo "wasmtime_version: $(wasmtime --version)" | tee -a "$log_file"
  fi
  if command -v wasmedge >/dev/null 2>&1; then
    echo "wasmedge_version: $(wasmedge --version 2>/dev/null | head -n1)" | tee -a "$log_file"
  fi
  if command -v wash >/dev/null 2>&1; then
    echo "wash_version: $(wash --version 2>/dev/null | head -n1)" | tee -a "$log_file"
  fi
}

# Record process resource usage (RSS, CPU%)
# Args: PID [LOG_FILE]
record_resources() {
  local pid=$1
  local log_file=${2:-/dev/stdout}
  local rss_kb cpu_pct
  
  rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
  cpu_pct=$(ps -o %cpu= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {printf "%.2f", sum+0}')
  
  if [[ "$log_file" == "/dev/stdout" ]]; then
    echo "[measure] rss_kb=${rss_kb} cpu_pct=${cpu_pct}"
  else
    echo "[measure] rss_kb=${rss_kb} cpu_pct=${cpu_pct}" | tee -a "$log_file"
  fi
}

# Wait for HTTP endpoint to return 200
# Args: URL LOG_FILE START_TIME_NS
# Returns: Sets global COLD_START_NS and COLD_START_MS
wait_for_http_ready() {
  local url=$1
  local log_file=$2
  local t0_ns=$3
  local max_retries=${4:-200}
  
  echo "[measure] waiting for HTTP 200 from ${url}..." | tee -a "$log_file"
  
  local retries=0
  local ready=0
  local t_ready_ns
  
  while (( retries < max_retries )); do
    local http_code=$(curl -sS -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      t_ready_ns=$(gdate +%s%N)
      ready=1
      break
    fi
    retries=$((retries + 1))
    sleep 0.01
  done
  
  if (( ready == 0 )); then
    echo "[measure] ERROR: server did not become ready in time" | tee -a "$log_file"
    return 1
  fi
  
  COLD_START_NS=$((t_ready_ns - t0_ns))
  COLD_START_MS=$(awk "BEGIN { printf \"%.3f\", $COLD_START_NS/1000000 }")
  
  echo "[measure] cold_start_ns=${COLD_START_NS}" | tee -a "$log_file"
  echo "[measure] cold_start_ms=${COLD_START_MS}" | tee -a "$log_file"
  
  return 0
}

# Run warmup requests (not measured)
# Args: URL N_REQUESTS LOG_FILE
run_warmup_requests() {
  local url=$1
  local n_req=${2:-5}
  local log_file=$3
  
  echo "[measure] warmup_requests=${n_req}" | tee -a "$log_file"
  
  if (( n_req > 0 )); then
    for _ in $(seq 1 "$n_req"); do
      curl -sS -o /dev/null "$url" >/dev/null 2>&1 || true
    done
  fi
}

# Measure latency with sequential requests
# Args: URL N_REQUESTS LOG_FILE [PATH_FOR_LOGGING]
measure_latency_sequential() {
  local url=$1
  local n_req=$2
  local log_file=$3
  local path_label=${4:-""}
  
  echo "[measure] running ${n_req} sequential requests..." | tee -a "$log_file"
  
  for i in $(seq 1 "$n_req"); do
    local req_start_ns=$(gdate +%s%N)
    local body=$(curl -sS -w "%{http_code}" "$url" 2>/dev/null)
    local req_end_ns=$(gdate +%s%N)
    
    local http_code="${body: -3}"
    local latency_ns=$((req_end_ns - req_start_ns))
    local latency_ms=$(awk "BEGIN { printf \"%.3f\", $latency_ns/1000000 }")
    
    if [[ -n "$path_label" ]]; then
      echo "req=${i} path=${path_label} http_code=${http_code} latency_ns=${latency_ns} latency_ms=${latency_ms}" \
        | tee -a "$log_file"
    else
      echo "req=${i} http_code=${http_code} latency_ns=${latency_ns} latency_ms=${latency_ms}" \
        | tee -a "$log_file"
    fi
  done
}

# Measure throughput with concurrent requests
# Args: URL N_REQUESTS CONCURRENCY LOG_FILE
# Returns: Sets global THROUGHPUT_RPS
measure_throughput_concurrent() {
  local url=$1
  local n_req=$2
  local conc=$3
  local log_file=$4
  
  echo "[measure] throughput_reqs=${n_req} throughput_conc=${conc}" | tee -a "$log_file"
  
  local t_tp_start_ns=$(gdate +%s%N)
  seq 1 "$n_req" | xargs -P "$conc" -I {} \
    curl -sS -o /dev/null "$url" >/dev/null 2>&1 || true
  local t_tp_end_ns=$(gdate +%s%N)
  
  local tp_ns=$((t_tp_end_ns - t_tp_start_ns))
  local tp_s=$(awk -v ns="$tp_ns" 'BEGIN { printf "%.6f", ns/1000000000 }')
  THROUGHPUT_RPS=$(awk -v n="$n_req" -v ns="$tp_ns" 'BEGIN { if (ns>0) printf "%.3f", n/(ns/1000000000); else print "0" }')
  
  echo "[measure] throughput_total_s=${tp_s} throughput_rps=${THROUGHPUT_RPS}" | tee -a "$log_file"
}

# Find available port starting from base
# Args: BASE_PORT
# Returns: First available port
find_available_port() {
  local base_port=$1
  local port=$base_port
  
  while (( port < base_port + 100 )); do
    if ! lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
  done
  
  echo "ERROR: No available ports found in range ${base_port}-$((base_port + 100))" >&2
  return 1
}

# Kill process and wait
# Args: PID
cleanup_process() {
  local pid=$1
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

# Validate sample size is adequate
# Args: SAMPLE_SIZE MIN_REQUIRED
validate_sample_size() {
  local sample_size=$1
  local min_required=${2:-3}
  
  if (( sample_size < min_required )); then
    echo "WARNING: Sample size ($sample_size) is less than minimum recommended ($min_required)" >&2
    return 1
  fi
  return 0
}

# Record continuous resource usage to CSV
# Args: PID OUTPUT_FILE INTERVAL_SEC
# Background process - returns immediately
record_resources_continuous() {
  local pid=$1
  local output_file=$2
  local interval=${3:-0.5}
  
  (
    echo "timestamp_ms,rss_kb,cpu_pct" > "$output_file"
    while kill -0 "$pid" 2>/dev/null; do
      local ts_ms=$(gdate +%s%3N)
      local rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
      local cpu_pct=$(ps -o %cpu= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {printf "%.2f", sum+0}')
      echo "${ts_ms},${rss_kb},${cpu_pct}" >> "$output_file"
      sleep "$interval"
    done
  ) &
  
  echo $!
}
