#!/usr/bin/env python3
"""
Analyze performance differences between stateless and stateful HTTP endpoints.
Compares latency for / (stateless) vs /state (stateful counter).
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
    "native": ROOT_DIR / "results" / "raw" / "native" / "http-hello",
    "docker": ROOT_DIR / "results" / "raw" / "docker" / "http-hello",
    "wasmtime": ROOT_DIR / "results" / "raw" / "wasmtime" / "http-hello",
}

OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

# Regex to match latency lines with optional path field
LAT_PATTERN = re.compile(r"req=\d+(?:\s+path=([^\s]+))?\s+.*?latency_ms=([0-9.]+)")


def load_samples_by_path(log_dir: Path):
    """Load latency samples, separated by endpoint path."""
    by_path = defaultdict(list)
    
    for log in sorted(log_dir.glob("*_run.log")):
        with log.open("r") as f:
            for line in f:
                m = LAT_PATTERN.search(line)
                if m:
                    path = m.group(1) if m.group(1) else "/"  # default to / if no path specified
                    latency_ms = float(m.group(2))
                    by_path[path].append(latency_ms)
    
    return dict(by_path)


def calculate_overhead_pct(stateless_latency, stateful_latency):
    """Calculate percentage overhead of stateful vs stateless."""
    if stateless_latency == 0:
        return 0
    return ((stateful_latency - stateless_latency) / stateless_latency) * 100


def print_summary(data):
    """Print text summary comparing stateless vs stateful endpoints."""
    print("\n" + "=" * 80)
    print("STATEFUL VS STATELESS ENDPOINT COMPARISON")
    print("=" * 80)
    
    for rt, path_data in data.items():
        print(f"\n{rt.upper()}:")
        print("-" * 80)
        
        if "/" in path_data and "/state" in path_data:
            stateless = path_data["/"]
            stateful = path_data["/state"]
            
            sl_mean = statistics.mean(stateless)
            sl_median = statistics.median(stateless)
            sl_stdev = statistics.stdev(stateless) if len(stateless) > 1 else 0
            
            st_mean = statistics.mean(stateful)
            st_median = statistics.median(stateful)
            st_stdev = statistics.stdev(stateful) if len(stateful) > 1 else 0
            
            overhead = calculate_overhead_pct(sl_mean, st_mean)
            
            print(f"  Stateless (/):")
            print(f"    Mean:   {sl_mean:7.3f} ± {sl_stdev:6.3f} ms")
            print(f"    Median: {sl_median:7.3f} ms")
            print(f"    Samples: {len(stateless)}")
            
            print(f"  Stateful (/state):")
            print(f"    Mean:   {st_mean:7.3f} ± {st_stdev:6.3f} ms")
            print(f"    Median: {st_median:7.3f} ms")
            print(f"    Samples: {len(stateful)}")
            
            print(f"  State Management Overhead: {overhead:+.1f}%")
        else:
            available = list(path_data.keys())
            print(f"  Paths found: {available}")
            if "/state" not in path_data:
                print(f"  [WARN] No /state endpoint data found. Run with PATH_SUFFIX=/state")


def plot_comparison_boxplot(data, out_path):
    """Generate side-by-side boxplot comparing endpoints."""
    fig, ax = plt.subplots(figsize=(12, 6))
    
    positions = []
    labels = []
    all_data = []
    colors = []
    
    pos = 1
    for rt in sorted(data.keys()):
        path_data = data[rt]
        
        if "/" in path_data:
            all_data.append(path_data["/"])
            positions.append(pos)
            labels.append(f"{rt}\n(stateless)")
            colors.append('lightblue')
            pos += 1
        
        if "/state" in path_data:
            all_data.append(path_data["/state"])
            positions.append(pos)
            labels.append(f"{rt}\n(stateful)")
            colors.append('lightcoral')
            pos += 1
        
        pos += 0.5  # gap between runtimes
    
    bp = ax.boxplot(all_data, positions=positions, widths=0.6, 
                    patch_artist=True, showfliers=True)
    
    for patch, color in zip(bp['boxes'], colors):
        patch.set_facecolor(color)
    
    ax.set_xticks(positions)
    ax.set_xticklabels(labels, rotation=0, ha='center')
    ax.set_ylabel("Latency (ms)", fontsize=12)
    ax.set_title("Stateless vs Stateful Endpoint Latency Comparison", 
                 fontsize=14, fontweight='bold')
    ax.grid(axis='y', alpha=0.3)
    
    # Add legend
    from matplotlib.patches import Patch
    legend_elements = [
        Patch(facecolor='lightblue', label='Stateless (/)'),
        Patch(facecolor='lightcoral', label='Stateful (/state)')
    ]
    ax.legend(handles=legend_elements, loc='upper right')
    
    plt.tight_layout()
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"\nSaved comparison boxplot to {out_path}")
    plt.close()


def plot_overhead_bar_chart(data, out_path):
    """Generate bar chart showing state management overhead."""
    fig, ax = plt.subplots(figsize=(10, 6))
    
    runtimes = []
    overheads = []
    
    for rt in sorted(data.keys()):
        path_data = data[rt]
        if "/" in path_data and "/state" in path_data:
            sl_mean = statistics.mean(path_data["/"])
            st_mean = statistics.mean(path_data["/state"])
            overhead = calculate_overhead_pct(sl_mean, st_mean)
            
            runtimes.append(rt)
            overheads.append(overhead)
    
    if not runtimes:
        print("[WARN] No runtime has both stateless and stateful data for overhead chart")
        return
    
    colors = ['red' if o > 0 else 'green' for o in overheads]
    bars = ax.bar(range(len(runtimes)), overheads, color=colors, 
                  edgecolor='black', linewidth=1.2)
    
    ax.set_xticks(range(len(runtimes)))
    ax.set_xticklabels(runtimes)
    ax.set_ylabel("Overhead (%)", fontsize=12)
    ax.set_title("State Management Overhead by Runtime", 
                 fontsize=14, fontweight='bold')
    ax.axhline(y=0, color='black', linestyle='-', linewidth=0.8)
    ax.grid(axis='y', alpha=0.3)
    
    # Add value labels
    for bar, overhead in zip(bars, overheads):
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
                f'{overhead:+.1f}%',
                ha='center', va='bottom' if height >= 0 else 'top', 
                fontsize=10, fontweight='bold')
    
    plt.tight_layout()
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"Saved overhead bar chart to {out_path}")
    plt.close()


def main():
    data = {}
    
    for rt, path in RUNTIMES.items():
        path_data = load_samples_by_path(path)
        if path_data:
            data[rt] = path_data
        else:
            print(f"[WARN] No http-hello samples for {rt} in {path}")
    
    if not data:
        print("ERROR: No http-hello data found.")
        print("\nMake sure to run benchmarks for both endpoints:")
        print("  ./scripts/measure_native_http_hello.sh  # stateless")
        print("  PATH_SUFFIX=/state ./scripts/measure_native_http_hello.sh  # stateful")
        sys.exit(1)
    
    # Check if we have stateful data
    has_stateful = any("/state" in path_data for path_data in data.values())
    if not has_stateful:
        print("[WARN] No /state endpoint data found in any runtime.")
        print("Run benchmarks with PATH_SUFFIX=/state to collect stateful data:")
        print("  PATH_SUFFIX=/state ./scripts/measure_native_http_hello.sh")
        print("  PATH_SUFFIX=/state ./scripts/measure_docker_http_hello.sh")
        print("  PATH_SUFFIX=/state ./scripts/measure_wasmtime_http_hello.sh")
    
    # Print summary
    print_summary(data)
    
    # Generate plots
    plot_comparison_boxplot(data, OUT_DIR / "http_hello_stateful_comparison_boxplot.png")
    plot_overhead_bar_chart(data, OUT_DIR / "http_hello_state_overhead.png")
    
    print("\n" + "=" * 80)
    print("Analysis complete! Check results/processed/ for plots.")
    print("=" * 80)


if __name__ == "__main__":
    main()
