#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/results/processed"
mkdir -p "$LOG_DIR"

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
LOG_FILE="$LOG_DIR/${RUN_TS}_run_all.log"
PLOT_RUN_DIR="$LOG_DIR/${RUN_TS}"

exec 3>>"$LOG_FILE"

LOG_TO_STDOUT="${LOG_TO_STDOUT:-1}"
LAST_CMD_STATUS=0

log() {
  local line
  line=$(printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*")
  printf "%s" "$line" >&3
  if [[ "$LOG_TO_STDOUT" == "1" ]]; then
    printf "%s" "$line"
  fi
}

run_cmd() {
  log "RUN: $*"
  if "$@" >>"$LOG_FILE" 2>&1; then
    LAST_CMD_STATUS=0
    return 0
  fi
  LAST_CMD_STATUS=$?
  if [[ "${CONTINUE_ON_ERROR:-0}" == "1" ]]; then
    log "WARN: command failed, continuing"
    return 0
  fi
  return "$LAST_CMD_STATUS"
}

run_in_dir() {
  local dir="$1"
  shift
  log "RUN (cd $dir): $*"
  if (cd "$dir" && "$@") >>"$LOG_FILE" 2>&1; then
    LAST_CMD_STATUS=0
    return 0
  fi
  LAST_CMD_STATUS=$?
  if [[ "${CONTINUE_ON_ERROR:-0}" == "1" ]]; then
    log "WARN: command failed, continuing"
    return 0
  fi
  return "$LAST_CMD_STATUS"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

HTTP_RUNS="${HTTP_RUNS:-3}"
HTTP_SCENARIOS="${HTTP_SCENARIOS:-cold warm}"
CPU_HASH_SCENARIOS="${CPU_HASH_SCENARIOS:-cold warm}"
HELLO_WASM_SCENARIOS="${HELLO_WASM_SCENARIOS:-cold warm}"
COLD_START_RUNS="${COLD_START_RUNS:-3}"

# HTTP Scaling settings
HTTP_SCALING="${HTTP_SCALING:-1}"
HTTP_SCALING_RUNTIMES="${HTTP_SCALING_RUNTIMES:-native docker wasmtime}"
HTTP_SCALING_CONCURRENCY="${HTTP_SCALING_CONCURRENCY:-1 2 4 8}"
HTTP_SCALING_N_RUN="${HTTP_SCALING_N_RUN:-5}"

INCLUDE_STATE="${INCLUDE_STATE:-1}"
GENERATE_PLOTS="${GENERATE_PLOTS:-1}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"
SUDO_KEEPALIVE_PID=""

FIREWALL="${FIREWALL:-both}" # off|on|both
WARMUP_REQ="${WARMUP_REQ:-5}"
THROUGHPUT_REQS="${THROUGHPUT_REQS:-200}"
THROUGHPUT_CONC="${THROUGHPUT_CONC:-10}"
MAX_RETRIES="${MAX_RETRIES:-6000}"

CLEAN_BUILD="${CLEAN_BUILD:-0}"
DOCKER_PRUNE="${DOCKER_PRUNE:-0}"
CLEAR_WASH="${CLEAR_WASH:-1}"
CLEAR_CACHE_BETWEEN_RUNS="${CLEAR_CACHE_BETWEEN_RUNS:-1}"
STRICT_CACHE_CLEAR="${STRICT_CACHE_CLEAR:-0}"

UI_ENABLED=0
USE_COLOR=0
UI_DRAWN=0
UI_LINES=0
INNER_WIDTH=0
BAR_WIDTH=0

RUN_START_EPOCH=0
STEP_TOTAL=0
STEP_INDEX=0
STEPS_DONE=0
STEPS_FAILED=0
CURRENT_RUNTIME="IDLE"
CURRENT_DESC="waiting to start"
CURRENT_CACHE="--"
CURRENT_DOCKER_COLD="--"
LAST_STATUS="--"
LAST_DURATION="--"

C_RESET=""
C_BOLD=""
C_DIM=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_MAGENTA=""
C_CYAN=""
C_WHITE=""

count_items() {
  local items="$1"
  if [[ -z "$items" ]]; then
    echo 0
    return
  fi
  set -- $items
  echo $#
}

format_hms() {
  local total="$1"
  local h=$((total / 3600))
  local m=$(((total % 3600) / 60))
  local s=$((total % 60))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

format_duration_short() {
  local total="$1"
  if (( total < 60 )); then
    printf "%ss" "$total"
  elif (( total < 3600 )); then
    local m=$((total / 60))
    local s=$((total % 60))
    printf "%dm%02ds" "$m" "$s"
  else
    local h=$((total / 3600))
    local m=$(((total % 3600) / 60))
    printf "%dh%02dm" "$h" "$m"
  fi
}

truncate_text() {
  local text="$1"
  local max="$2"
  if (( ${#text} > max )); then
    if (( max > 3 )); then
      printf "%s" "${text:0:max-3}..."
    else
      printf "%s" "${text:0:max}"
    fi
    return
  fi
  printf "%s" "$text"
}

ui_setup_colors() {
  if [[ "$USE_COLOR" != "1" ]]; then
    return
  fi
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
  C_WHITE=$'\033[37m'
}

colorize_line() {
  local line="$1"
  if [[ "$USE_COLOR" != "1" ]]; then
    printf "%s" "$line"
    return
  fi
  line=${line//NATIVE/${C_GREEN}NATIVE${C_RESET}}
  line=${line//DOCKER/${C_YELLOW}DOCKER${C_RESET}}
  line=${line//WASMCLOUD/${C_CYAN}WASMCLOUD${C_RESET}}
  line=${line//WASMTIME/${C_BLUE}WASMTIME${C_RESET}}
  line=${line//WASMEDGE/${C_MAGENTA}WASMEDGE${C_RESET}}
  line=${line//BUILD/${C_DIM}BUILD${C_RESET}}
  line=${line//PLOTS/${C_WHITE}PLOTS${C_RESET}}
  line=${line//COMPARE/${C_WHITE}COMPARE${C_RESET}}
  line=${line//IDLE/${C_DIM}IDLE${C_RESET}}
  line=${line//OK/${C_GREEN}OK${C_RESET}}
  line=${line//FAIL/${C_RED}FAIL${C_RESET}}
  printf "%s" "$line"
}

ui_render() {
  if [[ "$UI_ENABLED" != "1" ]]; then
    return
  fi

  local total="$STEP_TOTAL"
  if (( total <= 0 )); then
    total=1
  fi

  local step="$STEP_INDEX"
  if (( step < 0 )); then
    step=0
  fi
  if (( step > total )); then
    step="$total"
  fi

  local percent=$((step * 100 / total))
  local filled=$((step * BAR_WIDTH / total))
  if (( filled < 0 )); then
    filled=0
  fi
  if (( filled > BAR_WIDTH )); then
    filled=$BAR_WIDTH
  fi
  local empty=$((BAR_WIDTH - filled))

  local filled_bar
  local empty_bar
  filled_bar=$(printf "%*s" "$filled" "" | tr ' ' '#')
  empty_bar=$(printf "%*s" "$empty" "" | tr ' ' '.')

  local elapsed=$(( $(date +%s) - RUN_START_EPOCH ))
  local elapsed_fmt
  elapsed_fmt=$(format_hms "$elapsed")

  local avg_fmt="--"
  local eta_fmt="--"
  if (( STEPS_DONE > 0 )); then
    local avg=$((elapsed / STEPS_DONE))
    avg_fmt=$(format_duration_short "$avg")
    local remaining=$((total - step))
    if (( remaining < 0 )); then
      remaining=0
    fi
    local eta=$((avg * remaining))
    eta_fmt=$(format_duration_short "$eta")
  fi

  local line1="RSX207 Bench  Step ${step}/${total}  [${filled_bar}${empty_bar}] ${percent}%  ETA ${eta_fmt}"
  local line2="Current: ${CURRENT_RUNTIME} ${CURRENT_DESC}"
  local line3="Last: ${LAST_STATUS} ${LAST_DURATION}  Avg/step: ${avg_fmt}  Total: ${elapsed_fmt}"
  local line4="Warmup: ${WARMUP_REQ}  Throughput: ${THROUGHPUT_REQS}@${THROUGHPUT_CONC}  Cache: ${CURRENT_CACHE}  Docker cold: ${CURRENT_DOCKER_COLD}"
  local line5="Log: ${LOG_FILE}"
  local line6="Plots: ${PLOT_RUN_DIR}"

  line1=$(truncate_text "$line1" "$INNER_WIDTH")
  line2=$(truncate_text "$line2" "$INNER_WIDTH")
  line3=$(truncate_text "$line3" "$INNER_WIDTH")
  line4=$(truncate_text "$line4" "$INNER_WIDTH")
  line5=$(truncate_text "$line5" "$INNER_WIDTH")
  line6=$(truncate_text "$line6" "$INNER_WIDTH")

  local border
  border="+$(printf "%$((INNER_WIDTH + 2))s" "" | tr ' ' '-')+"

  if (( UI_DRAWN == 1 )); then
    printf "\033[%dA" "$UI_LINES"
  fi

  printf "%s\n" "$border"
  printf "%s\n" "$(colorize_line "| $(printf "%-${INNER_WIDTH}s" "$line1") |")"
  printf "%s\n" "$(colorize_line "| $(printf "%-${INNER_WIDTH}s" "$line2") |")"
  printf "%s\n" "$(colorize_line "| $(printf "%-${INNER_WIDTH}s" "$line3") |")"
  printf "%s\n" "$(colorize_line "| $(printf "%-${INNER_WIDTH}s" "$line4") |")"
  printf "%s\n" "$(colorize_line "| $(printf "%-${INNER_WIDTH}s" "$line5") |")"
  printf "%s\n" "$(colorize_line "| $(printf "%-${INNER_WIDTH}s" "$line6") |")"
  printf "%s\n" "$border"

  UI_DRAWN=1
}

ui_init() {
  if [[ -t 1 ]]; then
    UI_ENABLED=1
  fi
  if [[ -n "${NO_COLOR:-}" ]]; then
    USE_COLOR=0
  elif [[ "$UI_ENABLED" == "1" ]]; then
    USE_COLOR=1
  fi
  ui_setup_colors

  if [[ "$UI_ENABLED" != "1" ]]; then
    return
  fi

  LOG_TO_STDOUT=0

  local cols=80
  if command -v tput >/dev/null 2>&1; then
    cols=$(tput cols 2>/dev/null || echo 80)
  fi
  if (( cols < 70 )); then
    cols=70
  fi
  if (( cols > 110 )); then
    cols=110
  fi

  INNER_WIDTH=$((cols - 4))
  BAR_WIDTH=24
  if (( BAR_WIDTH > INNER_WIDTH - 30 )); then
    BAR_WIDTH=$((INNER_WIDTH - 30))
  fi
  if (( BAR_WIDTH < 10 )); then
    BAR_WIDTH=10
  fi

  UI_LINES=8

  printf "%s\n" "${C_BOLD}RSX207 Bench${C_RESET}  ${RUN_TS}"
  printf "%s\n" "$(colorize_line "Legend: NATIVE DOCKER WASMCLOUD WASMTIME WASMEDGE")"
  printf "%s\n" "Config: firewall=${FIREWALL} runs=${HTTP_RUNS} scenarios=${HTTP_SCENARIOS}"
  printf "%s\n" "Log: ${LOG_FILE}"
  printf "%s\n" "Plots: ${PLOT_RUN_DIR}"
  printf "\n"

  printf "\033[?25l"
  ui_render
}

ui_cleanup() {
  if [[ "$UI_ENABLED" == "1" ]]; then
    printf "\033[?25h"
  fi
}

step_run() {
  local runtime="$1"
  local desc="$2"
  local cache="$3"
  local docker_cold="$4"
  shift 4

  STEP_INDEX=$((STEP_INDEX + 1))
  CURRENT_RUNTIME="$runtime"
  CURRENT_DESC="$desc"
  CURRENT_CACHE="$cache"
  CURRENT_DOCKER_COLD="$docker_cold"
  ui_render

  local start
  local end
  start=$(date +%s)
  run_cmd "$@"
  local rc=$?
  end=$(date +%s)

  LAST_DURATION=$(format_duration_short $((end - start)))
  if (( LAST_CMD_STATUS == 0 )); then
    LAST_STATUS="OK"
  else
    LAST_STATUS="FAIL"
    STEPS_FAILED=$((STEPS_FAILED + 1))
  fi
  STEPS_DONE=$STEP_INDEX
  ui_render

  return "$rc"
}

step_run_in_dir() {
  local runtime="$1"
  local desc="$2"
  local cache="$3"
  local docker_cold="$4"
  local dir="$5"
  shift 5

  STEP_INDEX=$((STEP_INDEX + 1))
  CURRENT_RUNTIME="$runtime"
  CURRENT_DESC="$desc"
  CURRENT_CACHE="$cache"
  CURRENT_DOCKER_COLD="$docker_cold"
  ui_render

  local start
  local end
  start=$(date +%s)
  run_in_dir "$dir" "$@"
  local rc=$?
  end=$(date +%s)

  LAST_DURATION=$(format_duration_short $((end - start)))
  if (( LAST_CMD_STATUS == 0 )); then
    LAST_STATUS="OK"
  else
    LAST_STATUS="FAIL"
    STEPS_FAILED=$((STEPS_FAILED + 1))
  fi
  STEPS_DONE=$STEP_INDEX
  ui_render

  return "$rc"
}

calc_step_total() {
  local total=0

  if [[ "$CLEAN_BUILD" == "1" ]]; then
    total=$((total + 4))
  fi

  total=$((total + 5))

  local http_runtimes=1
  if [[ "$HAS_DOCKER" == "1" ]]; then
    http_runtimes=$((http_runtimes + 1))
  fi
  if [[ "$HAS_WASH" == "1" ]]; then
    http_runtimes=$((http_runtimes + 1))
  fi
  if [[ "$HAS_WASMTIME" == "1" ]]; then
    http_runtimes=$((http_runtimes + 1))
  fi

  local paths=1
  if [[ "$INCLUDE_STATE" == "1" ]]; then
    paths=2
  fi

  local scenarios=1
  local firewall_modes=1
  if [[ "$FIREWALL" == "on" ]]; then
    scenarios=1
    firewall_modes=1
  else
    scenarios=$(count_items "$HTTP_SCENARIOS")
    firewall_modes=1
    if [[ "$FIREWALL" == "both" ]]; then
      firewall_modes=2
    fi
  fi

  total=$((total + scenarios * firewall_modes * paths * http_runtimes * HTTP_RUNS))

  local cpu_runtimes=1
  if [[ "$HAS_DOCKER" == "1" ]]; then
    cpu_runtimes=$((cpu_runtimes + 1))
  fi
  if [[ "$HAS_WASMTIME" == "1" ]]; then
    cpu_runtimes=$((cpu_runtimes + 1))
  fi
  if [[ "$HAS_WASMEDGE" == "1" ]]; then
    cpu_runtimes=$((cpu_runtimes + 1))
  fi

  local cpu_scenarios
  cpu_scenarios=$(count_items "$CPU_HASH_SCENARIOS")
  total=$((total + cpu_scenarios * cpu_runtimes))

  local hello_runtimes=0
  if [[ "$HAS_WASMTIME" == "1" ]]; then
    hello_runtimes=$((hello_runtimes + 1))
  fi
  if [[ "$HAS_WASMEDGE" == "1" ]]; then
    hello_runtimes=$((hello_runtimes + 1))
  fi

  local hello_scenarios
  hello_scenarios=$(count_items "$HELLO_WASM_SCENARIOS")
  total=$((total + hello_scenarios * hello_runtimes))

  if [[ "$HAS_DOCKER" == "1" && "$HAS_WASMTIME" == "1" ]]; then
    total=$((total + 1))
  fi

  if [[ "$GENERATE_PLOTS" == "1" ]]; then
    total=$((total + 4))
  fi

  printf "%s" "$total"
}

HAS_DOCKER=0
HAS_WASH=0
HAS_WASMTIME=0
HAS_WASMEDGE=0

if have_cmd docker; then
  HAS_DOCKER=1
fi
if have_cmd wash; then
  HAS_WASH=1
fi
if have_cmd wasmtime; then
  HAS_WASMTIME=1
fi
if have_cmd wasmedge; then
  HAS_WASMEDGE=1
fi

log "Starting full benchmark run"
log "Log file: $LOG_FILE"
log "Config: HTTP_RUNS=$HTTP_RUNS HTTP_SCENARIOS='$HTTP_SCENARIOS' CPU_HASH_SCENARIOS='$CPU_HASH_SCENARIOS' HELLO_WASM_SCENARIOS='$HELLO_WASM_SCENARIOS'"
log "Config: FIREWALL=$FIREWALL WARMUP_REQ=$WARMUP_REQ THROUGHPUT_REQS=$THROUGHPUT_REQS THROUGHPUT_CONC=$THROUGHPUT_CONC MAX_RETRIES=$MAX_RETRIES"
log "Config: CLEAN_BUILD=$CLEAN_BUILD DOCKER_PRUNE=$DOCKER_PRUNE CLEAR_WASH=$CLEAR_WASH CLEAR_CACHE_BETWEEN_RUNS=$CLEAR_CACHE_BETWEEN_RUNS STRICT_CACHE_CLEAR=$STRICT_CACHE_CLEAR CONTINUE_ON_ERROR=$CONTINUE_ON_ERROR"

if [[ "$FIREWALL" == "on" || "$FIREWALL" == "both" ]]; then
  if have_cmd sudo; then
    printf "Preparing firewall controls (sudo required)...\n"
    log "Priming sudo for firewall control"
    sudo -v
    (while true; do sudo -n true; sleep 60; done) &
    SUDO_KEEPALIVE_PID=$!
  fi
fi

STEP_TOTAL=$(calc_step_total)
RUN_START_EPOCH=$(date +%s)
ui_init

if [[ "$CLEAN_BUILD" == "1" ]]; then
  log "Cleaning build artifacts"
  step_run_in_dir "BUILD" "Clean http-hello" "--" "--" "$ROOT_DIR/workloads/http-hello" cargo clean
  step_run_in_dir "BUILD" "Clean cpu-hash" "--" "--" "$ROOT_DIR/workloads/cpu-hash" cargo clean
  step_run_in_dir "BUILD" "Clean hello-wasm" "--" "--" "$ROOT_DIR/workloads/hello-wasm" cargo clean
  step_run_in_dir "BUILD" "Clean wasmcloud-http-hello" "--" "--" "$ROOT_DIR/workloads/wasmcloud-http-hello" rm -rf target build
fi

log "Building workloads"
step_run_in_dir "BUILD" "Build http-hello (release)" "--" "--" "$ROOT_DIR/workloads/http-hello" cargo build --release
step_run_in_dir "BUILD" "Build cpu-hash (release)" "--" "--" "$ROOT_DIR/workloads/cpu-hash" cargo build --release
step_run_in_dir "BUILD" "Build hello-wasm (wasip1)" "--" "--" "$ROOT_DIR/workloads/hello-wasm" cargo build --release --target wasm32-wasip1
step_run_in_dir "BUILD" "Build cpu-hash (wasip1)" "--" "--" "$ROOT_DIR/workloads/cpu-hash" cargo build --release --target wasm32-wasip1
step_run_in_dir "BUILD" "Build wasmcloud-http-hello" "--" "--" "$ROOT_DIR/workloads/wasmcloud-http-hello" wash build

enable_firewall() {
  if [[ "$FIREWALL" == "on" || "$FIREWALL" == "both" ]]; then
    run_cmd "$ROOT_DIR/scripts/firewall/pf_enable.sh"
  fi
}

disable_firewall() {
  if [[ "$FIREWALL" == "on" || "$FIREWALL" == "both" ]]; then
    run_cmd "$ROOT_DIR/scripts/firewall/pf_disable.sh"
  fi
}

cleanup_on_exit() {
  if [[ "$FIREWALL" == "on" || "$FIREWALL" == "both" ]]; then
    "$ROOT_DIR/scripts/firewall/pf_disable.sh" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  ui_cleanup
}
trap cleanup_on_exit EXIT

wash_down_all() {
  local purge_mode="$1"
  local host_ids=""

  if [[ "$HAS_WASH" != "1" ]]; then
    return 0
  fi

  if have_cmd python3; then
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
    run_cmd wash down --purge-jetstream "$purge_mode" || true
    return 0
  fi

  for host_id in $host_ids; do
    run_cmd wash down --host-id "$host_id" --purge-jetstream "$purge_mode" || true
  done
}

reset_wasmcloud() {
  local mode="$1"
  if [[ "$CLEAR_WASH" != "1" ]]; then
    return 0
  fi
  if [[ "$mode" == "cold" || "$STRICT_CACHE_CLEAR" == "1" ]]; then
    wash_down_all wadm
  else
    wash_down_all none
  fi
}

reset_docker() {
  local mode="$1"
  if [[ "$CLEAR_CACHE_BETWEEN_RUNS" != "1" ]]; then
    return 0
  fi
  if [[ "$mode" == "cold" || "$STRICT_CACHE_CLEAR" == "1" ]]; then
    if [[ "$DOCKER_PRUNE" == "1" ]]; then
      run_cmd docker system prune -af || true
    fi
  fi
}

run_http_suite() {
  local scenario="$1"
  local firewall_mode="$2"
  local path_suffix="$3"
  local docker_cold="$4"
  local wasmtime_cache_mode="$5"
  local docker_cold_label="no"

  if [[ "$docker_cold" == "1" ]]; then
    docker_cold_label="yes"
  fi

  log "HTTP suite: scenario=$scenario firewall=$firewall_mode path=$path_suffix docker_cold=$docker_cold wasmtime_cache=$wasmtime_cache_mode"

  for i in $(seq 1 "$HTTP_RUNS"); do
    local desc="HTTP ${scenario} firewall=${firewall_mode} path=${path_suffix} run ${i}/${HTTP_RUNS}"
    step_run "NATIVE" "$desc" "--" "--" env \
      FIREWALL_MODE="$firewall_mode" PATH_SUFFIX="$path_suffix" WARMUP_REQ="$WARMUP_REQ" \
      THROUGHPUT_REQS="$THROUGHPUT_REQS" THROUGHPUT_CONC="$THROUGHPUT_CONC" \
      "$ROOT_DIR/scripts/measure_native_http_hello.sh"
  done

  if [[ "$HAS_DOCKER" == "1" ]]; then
    for i in $(seq 1 "$HTTP_RUNS"); do
      reset_docker "$scenario"
      local desc="HTTP ${scenario} firewall=${firewall_mode} path=${path_suffix} run ${i}/${HTTP_RUNS}"
      step_run "DOCKER" "$desc" "--" "$docker_cold_label" env \
        FIREWALL_MODE="$firewall_mode" PATH_SUFFIX="$path_suffix" WARMUP_REQ="$WARMUP_REQ" \
        THROUGHPUT_REQS="$THROUGHPUT_REQS" THROUGHPUT_CONC="$THROUGHPUT_CONC" \
        DOCKER_COLD="$docker_cold" DOCKER_PRUNE="$DOCKER_PRUNE" \
        "$ROOT_DIR/scripts/measure_docker_http_hello.sh"
    done
  else
    log "SKIP: docker not available"
  fi

  if [[ "$HAS_WASH" == "1" ]]; then
    for i in $(seq 1 "$HTTP_RUNS"); do
      reset_wasmcloud "$scenario"
      local desc="HTTP ${scenario} firewall=${firewall_mode} path=${path_suffix} run ${i}/${HTTP_RUNS}"
      step_run "WASMCLOUD" "$desc" "--" "--" env \
        FIREWALL_MODE="$firewall_mode" PATH_SUFFIX="$path_suffix" WARMUP_REQ="$WARMUP_REQ" \
        THROUGHPUT_REQS="$THROUGHPUT_REQS" THROUGHPUT_CONC="$THROUGHPUT_CONC" \
        MAX_RETRIES="$MAX_RETRIES" \
        "$ROOT_DIR/scripts/measure_wasmcloud_http_hello.sh"
    done
  else
    log "SKIP: wash not available"
  fi

  if [[ "$HAS_WASMTIME" == "1" ]]; then
    for i in $(seq 1 "$HTTP_RUNS"); do
      local desc="HTTP ${scenario} firewall=${firewall_mode} path=${path_suffix} run ${i}/${HTTP_RUNS}"
      step_run "WASMTIME" "$desc" "$wasmtime_cache_mode" "--" env \
        FIREWALL_MODE="$firewall_mode" PATH_SUFFIX="$path_suffix" WARMUP_REQ="$WARMUP_REQ" \
        THROUGHPUT_REQS="$THROUGHPUT_REQS" THROUGHPUT_CONC="$THROUGHPUT_CONC" \
        WASMTIME_CACHE_MODE="$wasmtime_cache_mode" \
        "$ROOT_DIR/scripts/measure_wasmtime_http_hello.sh"
    done
  else
    log "SKIP: wasmtime not available"
  fi
}

run_cpu_hash_suite() {
  local scenario="$1"
  local wasmtime_cache_mode="$2"

  log "CPU-hash suite: scenario=$scenario wasmtime_cache=$wasmtime_cache_mode"

  step_run "NATIVE" "CPU hash ${scenario}" "--" "--" "$ROOT_DIR/scripts/measure_native_cpu_hash.sh"

  if [[ "$HAS_DOCKER" == "1" ]]; then
    reset_docker "$scenario"
    local docker_cold=0
    local docker_cold_label="no"
    if [[ "$scenario" == "cold" ]]; then
      docker_cold=1
      docker_cold_label="yes"
    fi
    step_run "DOCKER" "CPU hash ${scenario}" "--" "$docker_cold_label" env \
      DOCKER_COLD="$docker_cold" DOCKER_PRUNE="$DOCKER_PRUNE" \
      "$ROOT_DIR/scripts/measure_docker_cpu_hash.sh"
  else
    log "SKIP: docker not available"
  fi

  if [[ "$HAS_WASMTIME" == "1" ]]; then
    step_run "WASMTIME" "CPU hash ${scenario}" "$wasmtime_cache_mode" "--" env \
      WASMTIME_CACHE_MODE="$wasmtime_cache_mode" \
      "$ROOT_DIR/scripts/measure_wasm_cpu_hash.sh"
  else
    log "SKIP: wasmtime not available"
  fi

  if [[ "$HAS_WASMEDGE" == "1" ]]; then
    step_run "WASMEDGE" "CPU hash ${scenario}" "--" "--" "$ROOT_DIR/scripts/measure_wasmedge_cpu_hash.sh"
  else
    log "SKIP: wasmedge not available"
  fi
}

run_hello_wasm_suite() {
  local scenario="$1"
  local wasmtime_cache_mode="$2"

  log "hello-wasm suite: scenario=$scenario wasmtime_cache=$wasmtime_cache_mode"

  if [[ "$HAS_WASMTIME" == "1" ]]; then
    step_run "WASMTIME" "WASM hello ${scenario}" "$wasmtime_cache_mode" "--" env \
      WASMTIME_CACHE_MODE="$wasmtime_cache_mode" \
      "$ROOT_DIR/scripts/measure_wasm_hello.sh"
  else
    log "SKIP: wasmtime not available"
  fi

  if [[ "$HAS_WASMEDGE" == "1" ]]; then
    step_run "WASMEDGE" "WASM hello ${scenario}" "--" "--" "$ROOT_DIR/scripts/measure_wasmedge_hello.sh"
  else
    log "SKIP: wasmedge not available"
  fi
}

if [[ "$FIREWALL" == "on" ]]; then
  enable_firewall
  run_http_suite "default" "on" "/" 0 "warm"
  if [[ "$INCLUDE_STATE" == "1" ]]; then
    run_http_suite "default" "on" "/state" 0 "warm"
  fi
  disable_firewall
else
  for scenario in $HTTP_SCENARIOS; do
    docker_cold=0
    wasmtime_cache="warm"
    if [[ "$scenario" == "cold" || "$STRICT_CACHE_CLEAR" == "1" ]]; then
      docker_cold=1
      wasmtime_cache="cold"
    fi
    if [[ "$FIREWALL" == "both" ]]; then
      run_http_suite "$scenario" "off" "/" "$docker_cold" "$wasmtime_cache"
      enable_firewall
      run_http_suite "$scenario" "on" "/" "$docker_cold" "$wasmtime_cache"
      disable_firewall
    else
      run_http_suite "$scenario" "off" "/" "$docker_cold" "$wasmtime_cache"
    fi
    if [[ "$INCLUDE_STATE" == "1" ]]; then
      if [[ "$FIREWALL" == "both" ]]; then
        run_http_suite "$scenario" "off" "/state" "$docker_cold" "$wasmtime_cache"
        enable_firewall
        run_http_suite "$scenario" "on" "/state" "$docker_cold" "$wasmtime_cache"
        disable_firewall
      else
        run_http_suite "$scenario" "off" "/state" "$docker_cold" "$wasmtime_cache"
      fi
    fi
  done
fi

for scenario in $CPU_HASH_SCENARIOS; do
  wasmtime_cache="warm"
  if [[ "$scenario" == "cold" ]]; then
    wasmtime_cache="cold"
  fi
  run_cpu_hash_suite "$scenario" "$wasmtime_cache"
done

for scenario in $HELLO_WASM_SCENARIOS; do
  wasmtime_cache="warm"
  if [[ "$scenario" == "cold" ]]; then
    wasmtime_cache="cold"
  fi
  run_hello_wasm_suite "$scenario" "$wasmtime_cache"
done

if [[ "$HAS_DOCKER" == "1" && "$HAS_WASMTIME" == "1" ]]; then
  log "Cold-start comparison (Docker vs Wasmtime)"
  step_run "COMPARE" "Cold-start comparison (Docker vs Wasmtime)" "cold" "--" env \
    WASMTIME_CACHE_MODE="cold" \
    "$ROOT_DIR/scripts/measure_cold_start_comparison.sh" "$COLD_START_RUNS"
else
  log "SKIP: cold-start comparison requires docker and wasmtime"
fi

# HTTP Scaling tests
if [[ "$HTTP_SCALING" == "1" ]]; then
  log "Running HTTP scaling tests"
  for runtime in $HTTP_SCALING_RUNTIMES; do
    if [[ "$runtime" == "native" ]]; then
      step_run "NATIVE" "HTTP scaling test" "--" "--" env \
        RUNTIME="native" \
        CONCURRENCY_LIST="$HTTP_SCALING_CONCURRENCY" \
        N_RUN="$HTTP_SCALING_N_RUN" \
        "$ROOT_DIR/scripts/measure_http_hello_scaling.sh"
    elif [[ "$runtime" == "docker" && "$HAS_DOCKER" == "1" ]]; then
      step_run "DOCKER" "HTTP scaling test" "--" "--" env \
        RUNTIME="docker" \
        CONCURRENCY_LIST="$HTTP_SCALING_CONCURRENCY" \
        N_RUN="$HTTP_SCALING_N_RUN" \
        "$ROOT_DIR/scripts/measure_http_hello_scaling.sh"
    elif [[ "$runtime" == "wasmtime" && "$HAS_WASMTIME" == "1" ]]; then
      step_run "WASMTIME" "HTTP scaling test" "warm" "--" env \
        RUNTIME="wasmtime" \
        CONCURRENCY_LIST="$HTTP_SCALING_CONCURRENCY" \
        N_RUN="$HTTP_SCALING_N_RUN" \
        "$ROOT_DIR/scripts/measure_http_hello_scaling.sh"
    else
      log "SKIP: $runtime not available or not recognized for HTTP scaling"
    fi
  done
else
  log "SKIP: HTTP scaling tests disabled (set HTTP_SCALING=1 to enable)"
fi

if [[ "$GENERATE_PLOTS" == "1" ]]; then
  log "Generating plots"
  PLOT_MARKER="$LOG_DIR/${RUN_TS}_plots.marker"
  touch "$PLOT_MARKER"
  step_run "PLOTS" "Plot HTTP comparison" "--" "--" python3 "$ROOT_DIR/scripts/analyze_http_hello_all.py"
  step_run "PLOTS" "Plot CPU hash comparison" "--" "--" python3 "$ROOT_DIR/scripts/analyze_cpu_hash_comparison.py"
  step_run "PLOTS" "Plot WASM hello comparison" "--" "--" python3 "$ROOT_DIR/scripts/analyze_wasm_hello_comparison.py"
  step_run "PLOTS" "Plot cold-start comparison" "--" "--" python3 "$ROOT_DIR/scripts/analyze_cold_start_comparison.py"
  
  # Generate HTTP scaling plots if we ran scaling tests
  if [[ "$HTTP_SCALING" == "1" ]]; then
    step_run "PLOTS" "Plot HTTP scaling" "--" "--" python3 "$ROOT_DIR/scripts/analyze_http_hello_scaling.py"
  fi
  
  # Generate summary reports
  step_run "PLOTS" "Generate summary reports" "--" "--" python3 "$ROOT_DIR/scripts/generate_summary.py"
  
  mkdir -p "$PLOT_RUN_DIR"
  while IFS= read -r -d '' file; do
    cp "$file" "$PLOT_RUN_DIR/" >>"$LOG_FILE" 2>&1 || true
  done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*.png" -newer "$PLOT_MARKER" -print0)
  rm -f "$PLOT_MARKER"
  log "Plots copied to: $PLOT_RUN_DIR"
fi

log "Run completed"

if [[ "$UI_ENABLED" == "1" ]]; then
  CURRENT_RUNTIME="IDLE"
  CURRENT_DESC="completed"
  CURRENT_CACHE="--"
  CURRENT_DOCKER_COLD="--"
  ui_render
  printf "\n"
  printf "%s\n" "Summary: ${STEPS_DONE} steps, ${STEPS_FAILED} failed, total $(format_hms $(( $(date +%s) - RUN_START_EPOCH )))"
  printf "%s\n" "Log: ${LOG_FILE}"
  printf "%s\n" "Plots: ${PLOT_RUN_DIR}"
fi
