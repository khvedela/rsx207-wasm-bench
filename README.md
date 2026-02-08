# WebAssembly Runtime Benchmarking for Edge and Serverless Applications

A comparative evaluation of WebAssembly runtimes, traditional containers, and micro-VMs for edge computing and serverless architectures, with focus on boot time and network service performance.

## Project Overview

This project evaluates the performance characteristics of different lightweight runtime technologies to determine their suitability for latency-sensitive and resource-constrained edge computing scenarios. The primary focus is on measuring:

1. **Boot time** - delay between launching an instance and its readiness to serve requests
2. **Network request-response performance** - end-to-end latency of minimal HTTP/RPC microservices

## Evaluated Runtimes

- **Native Rust binary** (baseline)
- **WebAssembly runtimes**: wasmCloud (component + host), Wasmtime (component server), WasmEdge (standalone runtime)
- **Traditional containers**: Docker (Docker Desktop on macOS)
- **Out of scope on macOS**: Firecracker / micro-VMs and unikernels (documented as future work)

## Benchmark Workloads

Each runtime executes identical workloads to ensure fair comparison:

- Basic HTTP "hello" endpoint (`/`)
- CPU-bound function (SHA-256 iterations)
- Lightweight network endpoint (HTTP)
- Simple stateful endpoint (`/state` counter)

Note: WasmEdge is used for standalone WASI module benchmarks (hello/cpu-hash). HTTP component benchmarks are covered by Wasmtime/wasmCloud on macOS due to WASI HTTP support gaps.

## Key Metrics

### Primary Metrics (Priority)
- Cold-start delay
- Warm-start latency
- Network request-response latency
- **Scaling performance** (concurrent instance throughput and efficiency)

### Secondary Metrics
- Memory usage
- CPU usage
- Throughput
- **Scaling limits** (maximum concurrent instances before degradation)
- Resource efficiency (requests/sec per MB)
- **Scaling efficiency** (actual speedup / ideal speedup)

## Definitions

- **Cold start**: time from process launch to first successful HTTP 200 response.
- **Runtime cold start**: cold start with pre-built artifacts (image/module/component) already cached on disk.
- **Warm start latency**: per-request latency on a running instance after a short warm-up (warm-up requests are not recorded).

## Experimental Conditions

All runtimes are executed behind a configured host firewall to simulate realistic deployment conditions. On macOS, this uses `pf` with a consistent baseline ruleset. The impact of filtering rules on boot time and request-response latency is explicitly evaluated.

## Project Structure

```
rsx207-wasm-bench/
├── workloads/          # Benchmark workload implementations
├── scripts/            # Automation and measurement scripts
│   ├── lib/           # Shared bash functions (common.sh, validation.sh)
│   ├── measure_*.sh   # Measurement scripts for each runtime
│   ├── analyze_*.py   # Analysis scripts with statistical tests
│   └── generate_summary.py  # Generate comprehensive reports
├── results/            # Experimental data and measurements
│   ├── raw/           # Raw log files by runtime
│   └── processed/     # Generated plots and summaries
└── README.md          # This file
```

## New Features & Improvements

### Scaling Performance Tests
- **HTTP Scaling**: Test concurrent HTTP server instances (measure_http_hello_scaling.sh)
- **CPU Scaling**: Already implemented for CPU-bound workloads (measure_cpu_hash_scaling.sh)
- **Metrics**: Throughput vs concurrency, scaling efficiency, memory per instance
- **Configurable**: Set CONCURRENCY_LIST="1 2 4 8 16" and N_RUN=5

### Enhanced Statistical Analysis
- **Confidence intervals**: 95% CI using t-distribution
- **Significance testing**: Mann-Whitney U tests for pairwise comparisons
- **Sample validation**: Warnings for insufficient sample sizes
- **Improved plots**: Error bars, p-values, color-coded significance

### Code Refactoring
- **Common library**: Shared bash functions in scripts/lib/common.sh
- **Reduced duplication**: ~80% less code duplication in measurement scripts
- **Better error handling**: Validation library with prerequisite checks

### New Analysis Scripts
- **analyze_http_hello_scaling.py**: HTTP scaling performance analysis
- **analyze_http_hello_stateful.py**: Compare stateless vs stateful endpoints
- **generate_summary.py**: Generate markdown/LaTeX comparison tables

## Development Tasks

### Task 1: Requirements Definition and Experimental Design
- Finalize runtime selection and versions
- Define precise benchmark service specifications
- Specify host environment and firewall configuration
- Establish measurement methodology for reproducibility

### Task 2: Implementation of Benchmark Workloads and Automation
- Implement minimal network service for each runtime
- Develop automation tools for deployment, start, stop, and testing
- Create scripts for boot-time measurements
- Implement network request measurement tools
- Integrate firewall configuration

### Task 3: Experimental Campaign and Data Collection
- Conduct systematic experiments across all runtimes
- Perform multiple repetitions for statistical validity
- Collect cold-start, warm-start, and request-response data
- Validate, timestamp, and store structured data

### Task 4: Analysis, Interpretation, and Documentation
- Compare runtimes across all measured metrics
- Generate graphs and tables
- Interpret results in context of edge/serverless architectures
- Prepare final report

## Getting Started

### Prerequisites

- Docker Desktop
- Rust toolchain with `wasm32-wasip1` target: `rustup target add wasm32-wasip1`
- wasmCloud CLI (`wash`)
- Wasmtime (>=25.0.0 for `wasmtime serve`)
- WasmEdge (optional, macOS supported)
- `coreutils` (for `gdate` nanosecond timestamps on macOS)
- Host firewall tools (`pfctl` on macOS)

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd rsx207-wasm-bench

# Install core CLI tools (macOS/Homebrew)
brew install coreutils wasmtime wasmcloud/wasmcloud/wash
# Optional: WasmEdge (see https://wasmedge.org for install instructions)
```

### Running Benchmarks

```bash
# Run the full suite (default configuration)
./scripts/run_all_benchmarks.sh

# Build workloads
cd workloads/http-hello && cargo build --release
cdHTTP Scaling tests (NEW!)
RUNTIME=native ./scripts/measure_http_hello_scaling.sh
RUNTIME=docker ./scripts/measure_http_hello_scaling.sh
RUNTIME=wasmtime ./scripts/measure_http_hello_scaling.sh

# Customize scaling parameters
RUNTIME=native CONCURRENCY_LIST="1 2 4 8 16" N_RUN=10 ./scripts/measure_http_hello_scaling.sh

# Generate plots
python3 scripts/analyze_http_hello_all.py
python3 scripts/analyze_cold_start_comparison.py
python3 scripts/analyze_cpu_hash_comparison.py
python3 scripts/analyze_cpu_hash_scaling.py
python3 scripts/analyze_wasm_hello_comparison.py

# NEW Analysis scripts
python3 scripts/analyze_http_hello_scaling.py      # HTTP scaling performance
python3 scripts/analyze_http_hello_stateful.py     # Stateless vs stateful comparison
python3 scripts/generate_summary.py                # Comprehensive summary report
```

### Quick Start: Run Everything

```bash
# Full benchmark suite with default settings
./scripts/run_all_benchmarks.sh

# Enable HTTP scaling tests (disabled by default for faster runs)
HTTP_SCALING=1 ./scripts/run_all_benchmarks.sh

# Quick test with reduced iterations
HTTP_RUNS=2 HTTP_SCALING=1 HTTP_SCALING_N_RUN=3 ./scripts/run_all_benchmarks.sh

# Custom scaling configuration
HTTP_SCALING=1 \
HTTP_SCALING_CONCURRENCY="1 2 4" \
HTTP_SCALING_N_RUN=5 \
HTTP_SCALING_RUNTIMES="native docker wasmtime" \
./scripts/run_all_benchmarks.sh
```

### Configuration Variables

#### HTTP Scaling Options
- `HTTP_SCALING=1` - Enable HTTP scaling tests (default: 1)
- `HTTP_SCALING_RUNTIMES="native docker wasmtime"` - Runtimes to test

#### General Options
- `WARMUP_REQ=5` - Warm-up requests before measurements
- `THROUGHPUT_REQS=200` - Requests for throughput tests
- `THROUGHPUT_CONC=10` - Concurrent connections for throughput tests
- `HTTP_SCALING_CONCURRENCY="1 2 4 8"` - Concurrency levels to test
- `HTTP_SCALING_N_RUN=5` - Number of repetitions per concurrency levelcripts/measure_native_http_hello.sh
./scripts/measure_docker_http_hello.sh
./scripts/measure_wasmcloud_http_hello.sh
./scripts/measure_wasmtime_http_hello.sh

# WASM module benchmarks
./scripts/measure_wasm_hello.sh
./scripts/measure_wasm_cpu_hash.sh
./scripts/measure_wasmedge_hello.sh
./scripts/measure_wasmedge_cpu_hash.sh

# CPU-hash (native and Docker)
./scripts/measure_native_cpu_hash.sh
./scripts/measure_docker_cpu_hash.sh

# CPU-hash scaling (run with RUNTIME=... and optional CONCURRENCY_LIST/N_RUN)
RUNTIME=native ./scripts/measure_cpu_hash_scaling.sh
RUNTIME=docker ./scripts/measure_cpu_hash_scaling.sh
RUNTIME=wasmtime ./scripts/measure_cpu_hash_scaling.sh
RUNTIME=wasmedge ./scripts/measure_cpu_hash_scaling.sh

# Cold-start comparison (Docker vs Wasmtime)
./scripts/measure_cold_start_comparison.sh

# Generate plots
python3 scripts/analyze_http_hello_all.py
python3 scripts/analyze_cold_start_comparison.py
python3 scripts/analyze_cpu_hash_comparison.py
python3 scripts/analyze_cpu_hash_scaling.py
python3 scripts/analyze_wasm_hello_comparison.py
```

Notes:
- Set `WARMUP_REQ` to control warm-up requests (default: 5).
- Set `WASMTIME_CACHE_MODE=warm` to reuse Wasmtime cache across runs (default: cold).
- Use `PATH_SUFFIX=/state` on HTTP scripts to benchmark the stateful endpoint.
- Set `FIREWALL_MODE=on` or `off` to annotate logs when toggling PF.
- Set `THROUGHPUT_REQS` and `THROUGHPUT_CONC` to control throughput measurement load.
- wasmCloud memory/CPU is recorded as the sum of wasmCloud + NATS + wadm + HTTP provider/listener PIDs (from `wash up`).
- For the full suite script, see `scripts/run_all_benchmarks.sh` (set `FIREWALL`, `HTTP_SCENARIOS`, `HTTP_RUNS`, `CLEAN_BUILD`, `DOCKER_PRUNE`).

Full suite options (environment variables for `scripts/run_all_benchmarks.sh`):
- `FIREWALL=off|on|both`
- `HTTP_SCENARIOS="cold warm"` and `HTTP_RUNS=3`
- `CPU_HASH_SCENARIOS="cold warm"` and `HELLO_WASM_SCENARIOS="cold warm"`
- `CLEAR_CACHE_BETWEEN_RUNS=1` (default) and `STRICT_CACHE_CLEAR=1` (force cold semantics)
- `CLEAN_BUILD=1`, `DOCKER_PRUNE=1`, `CLEAR_WASH=1`

Plot outputs for a full run are still written to `results/processed/` and also copied into a timestamped subfolder (e.g. `results/processed/2026-01-07T19-40-01Z/`).

## Firewall Scripts (macOS)

These scripts require `sudo` and apply a minimal PF ruleset that blocks inbound traffic except loopback:

- `scripts/firewall/pf_enable.sh`
- `scripts/firewall/pf_disable.sh`
- `scripts/firewall/pf_status.sh`

## Project Timeline

- **Requirements & Design**: Oct 30 - Nov 21, 2025
- **Implementation & Automation**: Nov 22, 2025 - Jan 9, 2026
- **Experiments & Data Collection**: Jan 10 - Feb 13, 2026
- **Analysis & Documentation**: Feb 14 - Mar 1, 2026

### Key Milestones

- Nov 12: Base Specs v1 (Email)
- Nov 19: Updated Specs + Plan + Gantt
- Nov 21: First Formal Meeting
- Dec 4: Base Spec Oral + Plan (Moodle)
- Dec 12: Mid-Term Draft to Tutor
- Jan 9, 2026: Mid-Term Report + Presentation
- Jan 22, 2026: Second Formal Meeting
- Jan 29, 2026: Working Session
- Feb 9-13, 2026: Work Sessions
- Feb 23, 2026: Final Presentation
- Mar 1, 2026: Final Deliverables (Report + Video)

## Expected Outcomes

A comprehensive comparative analysis that:

- Characterizes benefits and limitations of each runtime environment
- Clarifies when WebAssembly-based approaches provide practical performance advantages
- Provides quantitative evidence for runtime selection in edge/serverless scenarios
- Evaluates the impact of security constraints (firewalling) on performance

## Future Work

- Firecracker / micro-VM and unikernel benchmarks (require a Linux host with KVM)
- Direct containerd measurements (bypassing Docker Desktop)
- Automated instance-density experiments across runtimes

## Project Information

- **Course**: UE RSX207, Conservatoire national des arts et métiers
- **Student**: D. Khvedelidze
- **Supervisors**: N. Modina, S. Secci
- **Academic Year**: 2025-26

## License

MIT License

Copyright (c) 2025 D. Khvedelidze

This project is part of a Master's degree research project at Conservatoire national des arts et métiers (CNAM), UE RSX207.

## Contributing

This is an academic research project. For questions or collaboration inquiries, please contact the supervisors.

## References

[To be added during the project]
