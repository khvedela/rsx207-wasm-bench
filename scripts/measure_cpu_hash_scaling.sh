#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNTIME="${RUNTIME:-${1:-}}"
if [[ -z "${RUNTIME}" ]]; then
  echo "Usage: $0 <native|docker|wasmtime|wasmedge>" >&2
  echo "  or set RUNTIME=native|docker|wasmtime|wasmedge" >&2
  exit 1
fi

if ! command -v gdate >/dev/null 2>&1; then
  echo "ERROR: gdate not found. Install coreutils with:" >&2
  echo "  brew install coreutils" >&2
  exit 1
fi

ITERATIONS="${ITERATIONS:-2000000}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-1 2 4 8}"
N_RUN="${N_RUN:-5}"

RUN_TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
RESULTS_DIR="$ROOT_DIR/results/raw/${RUNTIME}/cpu-hash-scaling"
LOG_FILE="$RESULTS_DIR/${RUN_TS}_run.log"
CACHE_BASE="$RESULTS_DIR/${RUN_TS}_cache"

mkdir -p "$RESULTS_DIR"

IMAGE_NAME="cpu-hash"
WORK_DIR="$ROOT_DIR/workloads/cpu-hash"
BIN="$ROOT_DIR/workloads/cpu-hash/target/release/cpu-hash"
WASM_MOD="$ROOT_DIR/workloads/cpu-hash/target/wasm32-wasip1/release/cpu-hash.wasm"

run_cmd() {
  case "$RUNTIME" in
    native)
      "$BIN" "$ITERATIONS"
      ;;
    docker)
      docker run --rm "$IMAGE_NAME" "$ITERATIONS"
      ;;
    wasmtime)
      if [[ "${WASMTIME_CACHE_MODE:-cold}" == "cold" ]]; then
        local cache_dir="$1"
        WASMTIME_CACHE_DIR="$cache_dir" wasmtime run "$WASM_MOD" "$ITERATIONS"
      else
        wasmtime run "$WASM_MOD" "$ITERATIONS"
      fi
      ;;
    wasmedge)
      wasmedge "$WASM_MOD" "$ITERATIONS"
      ;;
    *)
      echo "ERROR: unknown runtime: $RUNTIME" >&2
      exit 1
      ;;
  esac
}

prepare_runtime() {
  case "$RUNTIME" in
    native)
      if [[ ! -x "$BIN" ]]; then
        echo "ERROR: binary not found or not executable: $BIN" >&2
        echo "Build it first with:" >&2
        echo "  (cd workloads/cpu-hash && cargo build --release)" >&2
        exit 1
      fi
      ;;
    docker)
      if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found. Install Docker Desktop." >&2
        exit 1
      fi

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
      ;;
    wasmtime)
      if [[ ! -f "$WASM_MOD" ]]; then
        echo "ERROR: wasm module not found: $WASM_MOD" >&2
        echo "Build it first with:" >&2
        echo "  (cd workloads/cpu-hash && cargo build --release --target wasm32-wasip1)" >&2
        exit 1
      fi

      if ! command -v wasmtime >/dev/null 2>&1; then
        echo "ERROR: wasmtime not found. Install with:" >&2
        echo "  brew install wasmtime" >&2
        exit 1
      fi

      mkdir -p "$CACHE_BASE"
      if [[ "${WASMTIME_CACHE_MODE:-cold}" == "warm" ]]; then
        export WASMTIME_CACHE_DIR="$CACHE_BASE/warm"
      fi
      ;;
    wasmedge)
      if [[ ! -f "$WASM_MOD" ]]; then
        echo "ERROR: wasm module not found: $WASM_MOD" >&2
        echo "Build it first with:" >&2
        echo "  (cd workloads/cpu-hash && cargo build --release --target wasm32-wasip1)" >&2
        exit 1
      fi

      if ! command -v wasmedge >/dev/null 2>&1; then
        echo "ERROR: wasmedge not found. Install from https://wasmedge.org" >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: unknown runtime: $RUNTIME" >&2
      exit 1
      ;;
  esac
}

echo "==== cpu-hash scaling run at ${RUN_TS} ====" | tee "$LOG_FILE"
echo "runtime: $RUNTIME" | tee -a "$LOG_FILE"
echo "iterations: $ITERATIONS" | tee -a "$LOG_FILE"
echo "concurrency_list: $CONCURRENCY_LIST" | tee -a "$LOG_FILE"
echo "runs_per_conc: $N_RUN" | tee -a "$LOG_FILE"
echo "host_os: $(uname -a)" | tee -a "$LOG_FILE"
if command -v rustc >/dev/null 2>&1; then
  echo "rustc_version: $(rustc --version)" | tee -a "$LOG_FILE"
fi
if command -v docker >/dev/null 2>&1; then
  echo "docker_version: $(docker --version)" | tee -a "$LOG_FILE"
fi
if command -v wasmtime >/dev/null 2>&1; then
  echo "wasmtime_version: $(wasmtime --version)" | tee -a "$LOG_FILE"
fi
if command -v wasmedge >/dev/null 2>&1; then
  echo "wasmedge_version: $(wasmedge --version 2>/dev/null | head -n1)" | tee -a "$LOG_FILE"
fi
if [[ "$RUNTIME" == "wasmtime" ]]; then
  echo "wasmtime_cache_mode: ${WASMTIME_CACHE_MODE:-cold}" | tee -a "$LOG_FILE"
  echo "wasmtime_cache_base: $CACHE_BASE" | tee -a "$LOG_FILE"
fi

prepare_runtime

echo "[measure] scaling test: ${N_RUN} runs per concurrency" | tee -a "$LOG_FILE"

for conc in $CONCURRENCY_LIST; do
  for run in $(seq 1 "$N_RUN"); do
    tmp_dir="$(mktemp -d)"
    t0_ns=$(gdate +%s%N)

    pids=()
    for i in $(seq 1 "$conc"); do
      out_file="$tmp_dir/out_${i}.log"
      cache_dir="$CACHE_BASE/run${run}_conc${conc}_inst${i}"
      if [[ "$RUNTIME" == "wasmtime" && "${WASMTIME_CACHE_MODE:-cold}" == "cold" ]]; then
        mkdir -p "$cache_dir"
        (run_cmd "$cache_dir" >"$out_file" 2>&1) &
      else
        (run_cmd "" >"$out_file" 2>&1) &
      fi
      pids+=("$!")
    done

    failures=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        failures=$((failures + 1))
      fi
    done

    t1_ns=$(gdate +%s%N)
    elapsed_ns=$((t1_ns - t0_ns))
    elapsed_ms=$(awk "BEGIN { printf \"%.3f\", $elapsed_ns/1000000 }")

    total_iters=$((ITERATIONS * conc))
    throughput=$(awk -v iters="$total_iters" -v ms="$elapsed_ms" 'BEGIN { if (ms>0) printf "%.3f", iters/(ms/1000); else print "0" }')

    echo "run=${run} conc=${conc} total_ms=${elapsed_ms} total_iters=${total_iters} throughput_iter_s=${throughput} failures=${failures}" \
      | tee -a "$LOG_FILE"

    rm -rf "$tmp_dir"
  done

done

echo "[measure] finished run, logs in: $LOG_FILE"
