# WebAssembly Runtime Benchmarking for Edge and Serverless Applications

A comparative evaluation of WebAssembly runtimes, traditional containers, and micro-VMs for edge computing and serverless architectures, with focus on boot time and network service performance.

## Project Overview

This project evaluates the performance characteristics of different lightweight runtime technologies to determine their suitability for latency-sensitive and resource-constrained edge computing scenarios. The primary focus is on measuring:

1. **Boot time** - delay between launching an instance and its readiness to serve requests
2. **Network request-response performance** - end-to-end latency of minimal HTTP/RPC microservices

## Evaluated Runtimes

- **WebAssembly Runtimes**: wasmCloud, Wasmtime, WasmEdge
- **Traditional Containers**: Docker
- **Micro-VMs**: Firecracker
- **Unikernels** (optional)

## Benchmark Workloads

Each runtime executes identical workloads to ensure fair comparison:

- Basic "Hello World" service
- CPU-bound function
- Lightweight network endpoint
- Simple stateful service

## Key Metrics

### Primary Metrics (Priority)
- Cold-start delay
- Warm-start latency
- Network request-response latency

### Secondary Metrics
- Memory usage
- CPU usage
- Throughput
- Scaling limits

## Experimental Conditions

All runtimes are executed behind a configured host firewall to simulate realistic deployment conditions. The impact of standard filtering rules on boot time and request-response latency is explicitly evaluated.

## Project Structure

```
rsx207-wasm-bench/
├── workloads/          # Benchmark workload implementations
├── scripts/            # Automation and measurement scripts
├── results/            # Experimental data and measurements
└── README.md          # This file
```

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

- Docker
- WebAssembly runtimes (wasmCloud, Wasmtime, WasmEdge)
- Firecracker (for micro-VM testing)
- Host firewall configuration tools

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd rsx207-wasm-bench

# Install dependencies
# (specific installation steps to be added)
```

### Running Benchmarks

```bash
# Run all benchmarks
# (commands to be added)

# Run specific runtime benchmark
# (commands to be added)
```

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
