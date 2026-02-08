#!/usr/bin/env python3
"""
Analyze HTTP hello-world scaling performance across runtimes.
Generates throughput vs concurrency plots and scaling efficiency metrics.
"""

import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

ROOT_DIR = Path(__file__).resolve().parents[1]

RUNTIMES = {
    "native": ROOT_DIR / "results" / "raw" / "native" / "http-hello-scaling",
    "docker": ROOT_DIR / "results" / "raw" / "docker" / "http-hello-scaling",
    "wasmtime": ROOT_DIR / "results" / "raw" / "wasmtime" / "http-hello-scaling",
}

OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

# Regex patterns for log parsing
RUN_LOG_PATTERN = re.compile(r".*_run\.log$")
SCALE_LINE_PATTERN = re.compile(
    r"run=(\d+)\s+conc=(\d+)\s+total_requests=(\d+)\s+elapsed_ms=([0-9.]+)\s+"
    r"throughput_rps=([0-9.]+).*total_rss_kb=(\d+).*avg_rss_kb=(\d+)"
)
INSTANCE_LINE_PATTERN = re.compile(
    r"instance=(\d+)\s+rps=([0-9.]+).*avg_lat_ns=([0-9.]+).*"
    r"p50_lat_ns=([0-9.]+).*p95_lat_ns=([0-9.]+).*p99_lat_ns=([0-9.]+)"
)


def load_samples(path: Path):
    """Load scaling benchmark samples from log files."""
    samples = defaultdict(lambda: defaultdict(list))
    
    for log in sorted(path.glob("*_run.log")):
        if not RUN_LOG_PATTERN.match(log.name):
            continue
        
        with log.open("r") as f:
            for line in f:
                m = SCALE_LINE_PATTERN.search(line)
                if m:
                    conc = int(m.group(2))
                    throughput_rps = float(m.group(5))
                    total_rss_kb = int(m.group(6))
                    avg_rss_kb = int(m.group(7))
                    
                    samples[conc]["throughput_rps"].append(throughput_rps)
                    samples[conc]["total_rss_kb"].append(total_rss_kb)
                    samples[conc]["avg_rss_kb"].append(avg_rss_kb)
    
    return dict(samples)


def calculate_scaling_efficiency(data, runtime):
    """Calculate scaling efficiency: actual_speedup / ideal_speedup."""
    conc_map = data[runtime]
    concs = sorted(conc_map.keys())
    
    if not concs or 1 not in concs:
        return {}
    
    baseline_throughput = statistics.mean(conc_map[1]["throughput_rps"])
    
    efficiency = {}
    for conc in concs:
        actual_throughput = statistics.mean(conc_map[conc]["throughput_rps"])
        actual_speedup = actual_throughput / baseline_throughput
        ideal_speedup = conc
        eff = (actual_speedup / ideal_speedup) * 100
        efficiency[conc] = {
            "actual_speedup": actual_speedup,
            "ideal_speedup": ideal_speedup,
            "efficiency_pct": eff
        }
    
    return efficiency


def print_summary(data):
    """Print text summary of scaling results."""
    print("\n" + "=" * 80)
    print("HTTP HELLO-WORLD SCALING SUMMARY")
    print("=" * 80)
    
    for rt, conc_map in data.items():
        print(f"\n{rt.upper()}:")
        print("-" * 80)
        
        concs = sorted(conc_map.keys())
        for conc in concs:
            tp_vals = conc_map[conc]["throughput_rps"]
            rss_vals = conc_map[conc]["avg_rss_kb"]
            
            if not tp_vals:
                continue
            
            tp_mean = statistics.mean(tp_vals)
            tp_stdev = statistics.stdev(tp_vals) if len(tp_vals) > 1 else 0
            rss_mean = statistics.mean(rss_vals)
            
            print(f"  Concurrency {conc:2d}: "
                  f"throughput={tp_mean:8.1f} ± {tp_stdev:6.1f} req/s  "
                  f"avg_memory={rss_mean/1024:7.1f} MB  "
                  f"samples={len(tp_vals)}")
        
        # Calculate and print scaling efficiency
        efficiency = calculate_scaling_efficiency(data, rt)
        if efficiency:
            print(f"\n  Scaling Efficiency:")
            for conc in sorted(efficiency.keys()):
                eff_data = efficiency[conc]
                print(f"    {conc}x: {eff_data['actual_speedup']:.2f}x speedup "
                      f"(efficiency: {eff_data['efficiency_pct']:.1f}%)")


def plot_throughput_vs_concurrency(data, out_path):
    """Generate line plot of throughput vs concurrency."""
    plt.figure(figsize=(10, 6))
    
    for rt, conc_map in data.items():
        concs = sorted(conc_map.keys())
        means = [statistics.mean(conc_map[c]["throughput_rps"]) for c in concs]
        stdevs = [statistics.stdev(conc_map[c]["throughput_rps"]) if len(conc_map[c]["throughput_rps"]) > 1 else 0 
                  for c in concs]
        
        plt.errorbar(concs, means, yerr=stdevs, marker='o', label=rt, 
                    linewidth=2, markersize=8, capsize=5)
    
    plt.xlabel("Concurrent Instances", fontsize=12)
    plt.ylabel("Aggregate Throughput (req/s)", fontsize=12)
    plt.title("HTTP Scaling: Throughput vs Concurrency", fontsize=14, fontweight='bold')
    plt.grid(axis='both', alpha=0.3)
    plt.legend(fontsize=10)
    plt.tight_layout()
    
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"Saved throughput plot to {out_path}")
    plt.close()


def plot_scaling_efficiency(data, out_path):
    """Generate bar chart comparing scaling efficiency across runtimes."""
    fig, ax = plt.subplots(figsize=(10, 6))
    
    runtimes = list(data.keys())
    efficiency_data = {rt: calculate_scaling_efficiency(data, rt) for rt in runtimes}
    
    # Get all concurrency levels
    all_concs = set()
    for eff_map in efficiency_data.values():
        all_concs.update(eff_map.keys())
    concs = sorted(all_concs)
    
    x = np.arange(len(concs))
    width = 0.8 / len(runtimes)
    
    for idx, rt in enumerate(runtimes):
        eff_map = efficiency_data[rt]
        efficiencies = [eff_map.get(c, {}).get("efficiency_pct", 0) for c in concs]
        
        offset = (idx - len(runtimes)/2 + 0.5) * width
        ax.bar(x + offset, efficiencies, width, label=rt)
    
    ax.set_xlabel("Concurrent Instances", fontsize=12)
    ax.set_ylabel("Scaling Efficiency (%)", fontsize=12)
    ax.set_title("HTTP Scaling Efficiency Comparison", fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([f"{c}x" for c in concs])
    ax.axhline(y=100, color='r', linestyle='--', alpha=0.3, label='Ideal (100%)')
    ax.legend(fontsize=10)
    ax.grid(axis='y', alpha=0.3)
    plt.tight_layout()
    
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"Saved efficiency plot to {out_path}")
    plt.close()


def plot_memory_scaling(data, out_path):
    """Generate plot showing memory usage per instance."""
    plt.figure(figsize=(10, 6))
    
    for rt, conc_map in data.items():
        concs = sorted(conc_map.keys())
        means = [statistics.mean(conc_map[c]["avg_rss_kb"]) / 1024 for c in concs]  # Convert to MB
        
        plt.plot(concs, means, marker='s', label=rt, linewidth=2, markersize=8)
    
    plt.xlabel("Concurrent Instances", fontsize=12)
    plt.ylabel("Average Memory per Instance (MB)", fontsize=12)
    plt.title("HTTP Scaling: Memory Usage per Instance", fontsize=14, fontweight='bold')
    plt.grid(axis='both', alpha=0.3)
    plt.legend(fontsize=10)
    plt.tight_layout()
    
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"Saved memory plot to {out_path}")
    plt.close()


def plot_total_memory_scaling(data, out_path):
    """Generate stacked area chart showing total memory consumption."""
    fig, ax = plt.subplots(figsize=(10, 6))
    
    for rt, conc_map in data.items():
        concs = sorted(conc_map.keys())
        total_mem_mb = [statistics.mean(conc_map[c]["total_rss_kb"]) / 1024 for c in concs]
        
        ax.plot(concs, total_mem_mb, marker='o', label=rt, linewidth=2, markersize=8)
    
    ax.set_xlabel("Concurrent Instances", fontsize=12)
    ax.set_ylabel("Total Memory Consumption (MB)", fontsize=12)
    ax.set_title("HTTP Scaling: Total System Memory Usage", fontsize=14, fontweight='bold')
    ax.grid(axis='both', alpha=0.3)
    ax.legend(fontsize=10)
    plt.tight_layout()
    
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"Saved total memory plot to {out_path}")
    plt.close()


def main():
    data = {}
    
    for rt, path in RUNTIMES.items():
        samples = load_samples(path)
        if samples:
            data[rt] = samples
        else:
            print(f"[WARN] No http-hello scaling samples for {rt} in {path}")
    
    if not data:
        print("ERROR: No http-hello scaling data found.")
        print("\nRun the scaling benchmark first:")
        print("  RUNTIME=native ./scripts/measure_http_hello_scaling.sh")
        print("  RUNTIME=docker ./scripts/measure_http_hello_scaling.sh")
        print("  RUNTIME=wasmtime ./scripts/measure_http_hello_scaling.sh")
        sys.exit(1)
    
    # Print text summary
    print_summary(data)
    
    # Generate plots
    plot_throughput_vs_concurrency(data, OUT_DIR / "http_hello_scaling_throughput.png")
    plot_scaling_efficiency(data, OUT_DIR / "http_hello_scaling_efficiency.png")
    plot_memory_scaling(data, OUT_DIR / "http_hello_scaling_memory_per_instance.png")
    plot_total_memory_scaling(data, OUT_DIR / "http_hello_scaling_total_memory.png")
    
    print("\n" + "=" * 80)
    print("Analysis complete! Check results/processed/ for plots.")
    print("=" * 80)


if __name__ == "__main__":
    main()
