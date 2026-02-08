#!/usr/bin/env python3
"""
Cold Start Comparison Analysis: Docker vs Wasmtime

Generates comparison graphs from cold_start_data.csv produced by
measure_cold_start_comparison.sh

Scenarios:
  - Full Cold: Build from source (no cache) + start runtime
  - Runtime Cold: Pre-built artifact, fresh process start (typical serverless)

Usage:
    python3 scripts/analyze_cold_start_comparison.py
"""

import csv
import statistics
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT_DIR / "results" / "raw" / "cold-start-comparison"
OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

CSV_FILE = DATA_DIR / "cold_start_data.csv"


def load_data():
    """Load cold start data from CSV."""
    if not CSV_FILE.exists():
        print(f"ERROR: Data file not found: {CSV_FILE}")
        print("Run the measurement script first:")
        print("  ./scripts/measure_cold_start_comparison.sh")
        return None

    data = {
        "docker_full_cold": [],
        "docker_runtime_cold": [],
        "wasmtime_full_cold": [],
        "wasmtime_runtime_cold": [],
    }

    with open(CSV_FILE, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            runtime = row["runtime"]
            start_type = row["type"]
            key = f"{runtime}_{start_type}"

            if key in data:
                entry = {
                    "run": int(row["run"]),
                    "build_ms": float(row["build_ms"]),
                    "start_ms": float(row["start_ms"]),
                    "total_ms": float(row["total_ms"]),
                }
                data[key].append(entry)

    return data


def compute_stats(values):
    """Compute statistics for a list of values."""
    if not values:
        return {}
    return {
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0,
        "min": min(values),
        "max": max(values),
        "count": len(values),
    }


def print_summary(data):
    """Print text summary of results."""
    print("\n" + "=" * 70)
    print("Cold Start Comparison: Docker vs Wasmtime")
    print("=" * 70)

    labels = {
        "docker_full_cold": "Docker (Full Cold - build from source)",
        "docker_runtime_cold": "Docker (Runtime Cold - pre-built image)",
        "wasmtime_full_cold": "Wasmtime (Full Cold - build from source)",
        "wasmtime_runtime_cold": "Wasmtime (Runtime Cold - pre-built component)",
    }

    for key in ["docker_full_cold", "docker_runtime_cold", "wasmtime_full_cold", "wasmtime_runtime_cold"]:
        entries = data.get(key, [])
        if not entries:
            continue

        total_times = [e["total_ms"] for e in entries]
        stats = compute_stats(total_times)

        print(f"\n{labels[key]}:")
        print(f"  Total time to first HTTP 200:")
        print(f"    Mean:   {stats['mean']:>10.2f} ms")
        print(f"    Median: {stats['median']:>10.2f} ms")
        print(f"    Stdev:  {stats['stdev']:>10.2f} ms")
        print(f"    Min:    {stats['min']:>10.2f} ms")
        print(f"    Max:    {stats['max']:>10.2f} ms")

        if "full_cold" in key:
            build_times = [e["build_ms"] for e in entries]
            start_times = [e["start_ms"] for e in entries]
            print(f"  Breakdown:")
            print(f"    Build:  {statistics.mean(build_times):>10.2f} ms (mean)")
            print(f"    Start:  {statistics.mean(start_times):>10.2f} ms (mean)")

    # Comparisons
    print("\n" + "-" * 70)
    print("COMPARISONS:")

    comparisons = [
        ("docker_full_cold", "wasmtime_full_cold", "Full Cold (build from source)"),
        ("docker_runtime_cold", "wasmtime_runtime_cold", "Runtime Cold (serverless cold start)"),
        ("docker_full_cold", "docker_runtime_cold", "Docker: Full Cold vs Runtime Cold"),
        ("wasmtime_full_cold", "wasmtime_runtime_cold", "Wasmtime: Full Cold vs Runtime Cold"),
    ]

    for key1, key2, desc in comparisons:
        if data.get(key1) and data.get(key2):
            mean1 = statistics.mean([e["total_ms"] for e in data[key1]])
            mean2 = statistics.mean([e["total_ms"] for e in data[key2]])

            if mean1 > mean2:
                ratio = mean1 / mean2
                winner = key2.replace("_", " ").title()
                print(f"  {desc}: {winner} is {ratio:.1f}x faster")
            else:
                ratio = mean2 / mean1
                winner = key1.replace("_", " ").title()
                print(f"  {desc}: {winner} is {ratio:.1f}x faster")

    print("=" * 70 + "\n")


def plot_grouped_bar(data):
    """Create grouped bar chart comparing all 4 scenarios."""
    fig, ax = plt.subplots(figsize=(12, 7))

    scenarios = ["Full Cold\n(build from source)", "Runtime Cold\n(serverless cold start)"]
    docker_means = []
    docker_stds = []
    wasmtime_means = []
    wasmtime_stds = []

    for start_type in ["full_cold", "runtime_cold"]:
        docker_key = f"docker_{start_type}"
        wasmtime_key = f"wasmtime_{start_type}"

        docker_times = [e["total_ms"] for e in data.get(docker_key, [])]
        wasmtime_times = [e["total_ms"] for e in data.get(wasmtime_key, [])]

        docker_means.append(statistics.mean(docker_times) if docker_times else 0)
        docker_stds.append(statistics.stdev(docker_times) if len(docker_times) > 1 else 0)
        wasmtime_means.append(statistics.mean(wasmtime_times) if wasmtime_times else 0)
        wasmtime_stds.append(statistics.stdev(wasmtime_times) if len(wasmtime_times) > 1 else 0)

    x = np.arange(len(scenarios))
    width = 0.35

    bars1 = ax.bar(
        x - width / 2,
        docker_means,
        width,
        yerr=docker_stds,
        label="Docker",
        color="#2496ED",
        capsize=5,
        edgecolor="black",
        linewidth=1.2,
    )
    bars2 = ax.bar(
        x + width / 2,
        wasmtime_means,
        width,
        yerr=wasmtime_stds,
        label="Wasmtime",
        color="#FF6B35",
        capsize=5,
        edgecolor="black",
        linewidth=1.2,
    )

    # Add value labels
    for bars, means in [(bars1, docker_means), (bars2, wasmtime_means)]:
        for bar, mean in zip(bars, means):
            height = bar.get_height()
            ax.annotate(
                f"{mean:.0f} ms",
                xy=(bar.get_x() + bar.get_width() / 2, height),
                xytext=(0, 5),
                textcoords="offset points",
                ha="center",
                va="bottom",
                fontsize=11,
                fontweight="bold",
            )

    ax.set_ylabel("Time to First HTTP 200 (ms)", fontsize=12)
    ax.set_title("Cold Start Comparison: Docker vs Wasmtime", fontsize=14, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(scenarios, fontsize=12)
    ax.legend(loc="upper right", fontsize=11)
    ax.grid(axis="y", alpha=0.3)

    # Add sample size
    n_samples = len(data.get("docker_full_cold", []))
    ax.text(
        0.02,
        0.98,
        f"n = {n_samples} runs per scenario",
        transform=ax.transAxes,
        fontsize=10,
        verticalalignment="top",
        style="italic",
    )

    plt.tight_layout()
    out_path = OUT_DIR / "cold_warm_comparison_bar.png"
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"Saved: {out_path}")
    plt.close()


def plot_stacked_breakdown(data):
    """Create stacked bar showing build vs start time breakdown."""
    fig, ax = plt.subplots(figsize=(12, 7))

    scenarios = ["Docker\nFull Cold", "Docker\nRuntime Cold", "Wasmtime\nFull Cold", "Wasmtime\nRuntime Cold"]
    keys = ["docker_full_cold", "docker_runtime_cold", "wasmtime_full_cold", "wasmtime_runtime_cold"]

    build_means = []
    start_means = []

    for key in keys:
        entries = data.get(key, [])
        if entries:
            build_means.append(statistics.mean([e["build_ms"] for e in entries]))
            start_means.append(statistics.mean([e["start_ms"] for e in entries]))
        else:
            build_means.append(0)
            start_means.append(0)

    x = np.arange(len(scenarios))
    width = 0.6

    colors_build = ["#1a5276", "#2980b9", "#c0392b", "#e74c3c"]
    colors_start = ["#2ecc71", "#27ae60", "#f39c12", "#f1c40f"]

    # Use consistent colors
    color_build = "#E63946"
    color_start = "#457B9D"

    bars1 = ax.bar(x, build_means, width, label="Build Time", color=color_build, edgecolor="black")
    bars2 = ax.bar(x, start_means, width, bottom=build_means, label="Runtime Start", color=color_start, edgecolor="black")

    # Add total labels
    for i, (b, s) in enumerate(zip(build_means, start_means)):
        total = b + s
        ax.annotate(
            f"{total:.0f} ms",
            xy=(i, total),
            xytext=(0, 5),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=11,
            fontweight="bold",
        )

    ax.set_ylabel("Time (ms)", fontsize=12)
    ax.set_title("Cold Start Breakdown: Build vs Runtime Start", fontsize=14, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(scenarios, fontsize=11)
    ax.legend(loc="upper right", fontsize=11)
    ax.grid(axis="y", alpha=0.3)

    plt.tight_layout()
    out_path = OUT_DIR / "cold_warm_breakdown_stacked.png"
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"Saved: {out_path}")
    plt.close()


def plot_boxplot(data):
    """Create boxplot showing distribution of all scenarios."""
    fig, ax = plt.subplots(figsize=(12, 7))

    labels = ["Docker\nFull Cold", "Docker\nRuntime Cold", "Wasmtime\nFull Cold", "Wasmtime\nRuntime Cold"]
    keys = ["docker_full_cold", "docker_runtime_cold", "wasmtime_full_cold", "wasmtime_runtime_cold"]
    colors = ["#2496ED", "#85C1E9", "#FF6B35", "#FFAB91"]

    plot_data = []
    for key in keys:
        entries = data.get(key, [])
        times = [e["total_ms"] for e in entries] if entries else [0]
        plot_data.append(times)

    bp = ax.boxplot(
        plot_data,
        patch_artist=True,
        tick_labels=labels,
        showmeans=True,
        meanprops={"marker": "D", "markerfacecolor": "red", "markeredgecolor": "red", "markersize": 8},
    )

    for patch, color in zip(bp["boxes"], colors):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    ax.set_ylabel("Time to First HTTP 200 (ms)", fontsize=12)
    ax.set_title("Cold Start Distribution: Docker vs Wasmtime", fontsize=14, fontweight="bold")
    ax.grid(axis="y", alpha=0.3)

    mean_patch = mpatches.Patch(color="red", label="Mean (diamond)")
    ax.legend(handles=[mean_patch], loc="upper right")

    plt.tight_layout()
    out_path = OUT_DIR / "cold_warm_comparison_boxplot.png"
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"Saved: {out_path}")
    plt.close()


def plot_speedup_chart(data):
    """Create chart showing speedup factors."""
    fig, ax = plt.subplots(figsize=(10, 6))

    comparisons = []
    speedups = []
    colors = []

    # Full cold start comparison
    if data.get("docker_full_cold") and data.get("wasmtime_full_cold"):
        docker_full = statistics.mean([e["total_ms"] for e in data["docker_full_cold"]])
        wasmtime_full = statistics.mean([e["total_ms"] for e in data["wasmtime_full_cold"]])
        if wasmtime_full < docker_full:
            speedup = docker_full / wasmtime_full
            comparisons.append("Full Cold\n(Wasmtime wins)")
            speedups.append(speedup)
            colors.append("#FF6B35")  # Orange - Wasmtime wins
        else:
            speedup = wasmtime_full / docker_full
            comparisons.append("Full Cold\n(Docker wins)")
            speedups.append(speedup)
            colors.append("#2496ED")  # Blue - Docker wins

    # Runtime cold start comparison (the important one for serverless)
    if data.get("docker_runtime_cold") and data.get("wasmtime_runtime_cold"):
        docker_runtime = statistics.mean([e["total_ms"] for e in data["docker_runtime_cold"]])
        wasmtime_runtime = statistics.mean([e["total_ms"] for e in data["wasmtime_runtime_cold"]])
        if wasmtime_runtime < docker_runtime:
            speedup = docker_runtime / wasmtime_runtime
            comparisons.append("Runtime Cold\n(Wasmtime wins)")
            speedups.append(speedup)
            colors.append("#FF6B35")  # Orange - Wasmtime wins
        else:
            speedup = wasmtime_runtime / docker_runtime
            comparisons.append("Runtime Cold\n(Docker wins)")
            speedups.append(speedup)
            colors.append("#2496ED")  # Blue - Docker wins

    x = np.arange(len(comparisons))
    bars = ax.bar(x, speedups, color=colors, edgecolor="black", linewidth=1.2)

    # Add value labels
    for bar, speedup in zip(bars, speedups):
        height = bar.get_height()
        ax.annotate(
            f"{speedup:.1f}x faster",
            xy=(bar.get_x() + bar.get_width() / 2, height),
            xytext=(0, 5),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=12,
            fontweight="bold",
        )

    ax.axhline(y=1, color="gray", linestyle="--", alpha=0.5)
    ax.set_ylabel("Speedup Factor", fontsize=12)
    ax.set_title("Performance Advantage: Who Wins?", fontsize=14, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(comparisons, fontsize=11)
    ax.set_ylim(0, max(speedups) * 1.2 if speedups else 2)
    ax.grid(axis="y", alpha=0.3)

    plt.tight_layout()
    out_path = OUT_DIR / "cold_warm_speedup.png"
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"Saved: {out_path}")
    plt.close()


def main():
    data = load_data()
    if data is None:
        return

    has_data = any(data.get(k) for k in data)
    if not has_data:
        print("No data found for any scenario.")
        return

    print_summary(data)

    # Generate all plots
    plot_grouped_bar(data)
    plot_stacked_breakdown(data)
    plot_boxplot(data)
    plot_speedup_chart(data)

    print(f"\nAll graphs saved to: {OUT_DIR}")


if __name__ == "__main__":
    main()
