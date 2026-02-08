#!/usr/bin/env python3
"""
Generate comprehensive summary report of all benchmark results.
Creates markdown tables, LaTeX tables, and executive summary.
"""

import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List

ROOT_DIR = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

# Define all benchmarks and their data locations
BENCHMARKS = {
    "cold_start": {
        "name": "Cold Start",
        "unit": "ms",
        "runtimes": {
            "native": ROOT_DIR / "results" / "raw" / "native" / "http-hello",
            "docker": ROOT_DIR / "results" / "raw" / "docker" / "http-hello",
            "wasmtime": ROOT_DIR / "results" / "raw" / "wasmtime" / "http-hello",
        },
        "pattern": re.compile(r"cold_start_ms=([0-9.]+)"),
    },
    "http_latency": {
        "name": "HTTP Latency (p50)",
        "unit": "ms",
        "runtimes": {
            "native": ROOT_DIR / "results" / "raw" / "native" / "http-hello",
            "docker": ROOT_DIR / "results" / "raw" / "docker" / "http-hello",
            "wasmtime": ROOT_DIR / "results" / "raw" / "wasmtime" / "http-hello",
        },
        "pattern": re.compile(r"latency_ms=([0-9.]+)"),
    },
    "http_throughput": {
        "name": "HTTP Throughput",
        "unit": "req/s",
        "runtimes": {
            "native": ROOT_DIR / "results" / "raw" / "native" / "http-hello",
            "docker": ROOT_DIR / "results" / "raw" / "docker" / "http-hello",
            "wasmtime": ROOT_DIR / "results" / "raw" / "wasmtime" / "http-hello",
        },
        "pattern": re.compile(r"throughput_rps=([0-9.]+)"),
    },
    "memory_usage": {
        "name": "Memory Usage",
        "unit": "MB",
        "runtimes": {
            "native": ROOT_DIR / "results" / "raw" / "native" / "http-hello",
            "docker": ROOT_DIR / "results" / "raw" / "docker" / "http-hello",
            "wasmtime": ROOT_DIR / "results" / "raw" / "wasmtime" / "http-hello",
        },
        "pattern": re.compile(r"rss_kb=([0-9.]+)"),
        "convert": lambda x: x / 1024,  # KB to MB
    },
    "cpu_hash": {
        "name": "CPU Hash Performance",
        "unit": "ms",
        "runtimes": {
            "native": ROOT_DIR / "results" / "raw" / "native" / "cpu-hash",
            "docker": ROOT_DIR / "results" / "raw" / "docker" / "cpu-hash",
            "wasmtime": ROOT_DIR / "results" / "raw" / "wasm" / "cpu-hash",
            "wasmedge": ROOT_DIR / "results" / "raw" / "wasmedge" / "cpu-hash",
        },
        "pattern": re.compile(r"outer_ms=([0-9.]+)"),
    },
}


def load_samples(log_dir: Path, pattern: re.Pattern, convert_func=None):
    """Load samples from log files matching the pattern."""
    samples = []
    
    if not log_dir.exists():
        return samples
    
    for log in sorted(log_dir.glob("*_run.log")):
        with log.open("r") as f:
            for line in f:
                m = pattern.search(line)
                if m:
                    value = float(m.group(1))
                    if convert_func:
                        value = convert_func(value)
                    samples.append(value)
    
    return samples


def calculate_percentile(samples: List[float], percentile: int) -> float:
    """Calculate the specified percentile."""
    if not samples:
        return 0.0
    sorted_samples = sorted(samples)
    index = int(len(sorted_samples) * percentile / 100)
    return sorted_samples[min(index, len(sorted_samples) - 1)]


def generate_markdown_table(results: Dict) -> str:
    """Generate markdown comparison table."""
    lines = []
    lines.append("# Benchmark Summary\n")
    lines.append("## Performance Comparison\n")
    
    for benchmark_key, benchmark_info in BENCHMARKS.items():
        if benchmark_key not in results:
            continue
        
        bench_results = results[benchmark_key]
        if not bench_results:
            continue
        
        lines.append(f"### {benchmark_info['name']}\n")
        lines.append(f"| Runtime | Mean | Median | Std Dev | Min | Max | Samples |")
        lines.append(f"|---------|------|--------|---------|-----|-----|---------|")
        
        for rt in sorted(bench_results.keys()):
            samples = bench_results[rt]
            if not samples:
                continue
            
            mean_val = statistics.mean(samples)
            median_val = statistics.median(samples)
            stdev_val = statistics.stdev(samples) if len(samples) > 1 else 0
            min_val = min(samples)
            max_val = max(samples)
            n = len(samples)
            unit = benchmark_info['unit']
            
            lines.append(
                f"| {rt} | {mean_val:.2f} {unit} | {median_val:.2f} {unit} | "
                f"{stdev_val:.2f} | {min_val:.2f} | {max_val:.2f} | {n} |"
            )
        
        # Calculate speedup relative to Docker
        if "docker" in bench_results and len(bench_results["docker"]) > 0:
            docker_mean = statistics.mean(bench_results["docker"])
            lines.append(f"\n**Speedup vs Docker:**\n")
            for rt in sorted(bench_results.keys()):
                if rt == "docker" or not bench_results[rt]:
                    continue
                rt_mean = statistics.mean(bench_results[rt])
                # For latency/time metrics, lower is better
                if unit in ["ms", "s"]:
                    speedup = docker_mean / rt_mean
                else:  # For throughput, higher is better
                    speedup = rt_mean / docker_mean
                lines.append(f"- {rt}: {speedup:.2f}x")
        
        lines.append("\n")
    
    return "\n".join(lines)


def generate_latex_table(results: Dict) -> str:
    """Generate LaTeX table for report."""
    lines = []
    lines.append("\\begin{table}[h]")
    lines.append("\\centering")
    lines.append("\\caption{Benchmark Results Summary}")
    lines.append("\\label{tab:benchmark_summary}")
    
    for benchmark_key, benchmark_info in BENCHMARKS.items():
        if benchmark_key not in results:
            continue
        
        bench_results = results[benchmark_key]
        if not bench_results:
            continue
        
        runtimes = sorted(bench_results.keys())
        lines.append("\\begin{tabular}{l" + "r" * 4 + "}")
        lines.append("\\hline")
        lines.append(f"\\multicolumn{{5}}{{c}}{{\\textbf{{{benchmark_info['name']}}}}} \\\\")
        lines.append("\\hline")
        lines.append(f"Runtime & Mean & Median & Std Dev & Min \\\\")
        lines.append("\\hline")
        
        for rt in runtimes:
            samples = bench_results[rt]
            if not samples:
                continue
            
            mean_val = statistics.mean(samples)
            median_val = statistics.median(samples)
            stdev_val = statistics.stdev(samples) if len(samples) > 1 else 0
            min_val = min(samples)
            unit = benchmark_info['unit']
            
            lines.append(
                f"{rt} & {mean_val:.2f} & {median_val:.2f} & "
                f"{stdev_val:.2f} & {min_val:.2f} \\\\"
            )
        
        lines.append("\\hline")
        lines.append("\\end{tabular}")
        lines.append("\\vspace{1em}\n")
    
    lines.append("\\end{table}")
    
    return "\n".join(lines)


def generate_executive_summary(results: Dict) -> str:
    """Generate concise executive summary."""
    lines = []
    lines.append("=" * 80)
    lines.append("WASM BENCHMARK EXECUTIVE SUMMARY")
    lines.append("=" * 80)
    lines.append("")
    
    # Key findings
    lines.append("KEY FINDINGS:")
    lines.append("-" * 80)
    
    # Cold start comparison
    if "cold_start" in results:
        cold_start = results["cold_start"]
        if "native" in cold_start and "docker" in cold_start and "wasmtime" in cold_start:
            native_cs = statistics.mean(cold_start["native"])
            docker_cs = statistics.mean(cold_start["docker"])
            wasm_cs = statistics.mean(cold_start["wasmtime"])
            
            lines.append(f"\n1. Cold Start Performance:")
            lines.append(f"   - Native:   {native_cs:6.2f} ms (fastest)")
            lines.append(f"   - Docker:   {docker_cs:6.2f} ms ({docker_cs/native_cs:.2f}x slower)")
            lines.append(f"   - Wasmtime: {wasm_cs:6.2f} ms ({wasm_cs/native_cs:.2f}x slower)")
    
    # HTTP throughput
    if "http_throughput" in results:
        throughput = results["http_throughput"]
        if throughput:
            lines.append(f"\n2. HTTP Throughput:")
            for rt in sorted(throughput.keys()):
                if throughput[rt]:
                    mean_tp = statistics.mean(throughput[rt])
                    lines.append(f"   - {rt:10s}: {mean_tp:8.1f} req/s")
    
    # Memory efficiency
    if "memory_usage" in results:
        memory = results["memory_usage"]
        if memory:
            lines.append(f"\n3. Memory Usage:")
            for rt in sorted(memory.keys()):
                if memory[rt]:
                    mean_mem = statistics.mean(memory[rt])
                    lines.append(f"   - {rt:10s}: {mean_mem:6.1f} MB")
    
    # CPU performance
    if "cpu_hash" in results:
        cpu = results["cpu_hash"]
        if cpu and "native" in cpu:
            native_cpu = statistics.mean(cpu["native"])
            lines.append(f"\n4. CPU-Bound Performance (relative to native):")
            for rt in sorted(cpu.keys()):
                if cpu[rt] and rt != "native":
                    rt_cpu = statistics.mean(cpu[rt])
                    overhead = ((rt_cpu / native_cpu) - 1) * 100
                    lines.append(f"   - {rt:10s}: {overhead:+5.1f}% overhead")
    
    lines.append("\n" + "=" * 80)
    
    return "\n".join(lines)


def main():
    print("Collecting benchmark results...")
    
    results = {}
    
    for benchmark_key, benchmark_info in BENCHMARKS.items():
        results[benchmark_key] = {}
        
        for rt, log_dir in benchmark_info["runtimes"].items():
            convert_func = benchmark_info.get("convert", None)
            samples = load_samples(log_dir, benchmark_info["pattern"], convert_func)
            
            if samples:
                results[benchmark_key][rt] = samples
                print(f"  {benchmark_key} / {rt}: {len(samples)} samples")
    
    # Generate outputs
    print("\nGenerating summary reports...")
    
    # Markdown summary
    markdown = generate_markdown_table(results)
    markdown_path = OUT_DIR / "benchmark_summary.md"
    markdown_path.write_text(markdown)
    print(f"  ✓ Markdown summary: {markdown_path}")
    
    # LaTeX table
    latex = generate_latex_table(results)
    latex_path = OUT_DIR / "benchmark_summary.tex"
    latex_path.write_text(latex)
    print(f"  ✓ LaTeX table: {latex_path}")
    
    # Executive summary (to stdout and file)
    exec_summary = generate_executive_summary(results)
    exec_path = OUT_DIR / "executive_summary.txt"
    exec_path.write_text(exec_summary)
    print(f"  ✓ Executive summary: {exec_path}")
    
    print("\n" + exec_summary)
    
    print("\n" + "=" * 80)
    print("Summary generation complete!")
    print("=" * 80)


if __name__ == "__main__":
    main()
