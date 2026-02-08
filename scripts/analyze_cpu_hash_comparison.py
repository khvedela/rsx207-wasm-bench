#!/usr/bin/env python3
import re
import statistics
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

# Try to import scipy for statistical tests, gracefully handle if not available
try:
    from scipy import stats as scipy_stats
    SCIPY_AVAILABLE = True
except ImportError:
    SCIPY_AVAILABLE = False
    print("[WARN] scipy not available. Statistical significance tests will be skipped.")
    print("  Install with: pip install scipy")

ROOT_DIR = Path(__file__).resolve().parents[1]

RUNTIMES = {
    "native": ROOT_DIR / "results" / "raw" / "native" / "cpu-hash",
    "docker": ROOT_DIR / "results" / "raw" / "docker" / "cpu-hash",
    "wasmtime": ROOT_DIR / "results" / "raw" / "wasm" / "cpu-hash",
    "wasmedge": ROOT_DIR / "results" / "raw" / "wasmedge" / "cpu-hash",
}

OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

RUN_LOG_PATTERN = re.compile(r".*_run\.log$")
OUTER_MS_PATTERN = re.compile(r"outer_ms=([0-9.]+)")


def load_samples(path: Path):
    samples = []
    for log in sorted(path.glob("*_run.log")):
        if not RUN_LOG_PATTERN.match(log.name):
            continue
        with log.open("r") as f:
            for line in f:
                m = OUTER_MS_PATTERN.search(line)
                if m:
                    samples.append(float(m.group(1)))
    return samples


def compute_confidence_interval(samples, confidence=0.95):
    """Compute confidence interval for the mean using t-distribution."""
    if not SCIPY_AVAILABLE or len(samples) < 2:
        return None, None
    
    mean = np.mean(samples)
    n = len(samples)
    std_err = scipy_stats.sem(samples)
    margin = std_err * scipy_stats.t.ppf((1 + confidence) / 2, n - 1)
    
    return mean - margin, mean + margin


def compare_runtimes_statistically(data):
    """Perform pairwise statistical tests between runtimes."""
    if not SCIPY_AVAILABLE:
        return
    
    print("\n" + "=" * 80)
    print("STATISTICAL SIGNIFICANCE TESTS (Mann-Whitney U)")
    print("=" * 80)
    
    runtimes = list(data.keys())
    for i, rt1 in enumerate(runtimes):
        for rt2 in runtimes[i+1:]:
            samples1 = data[rt1]
            samples2 = data[rt2]
            
            if len(samples1) < 3 or len(samples2) < 3:
                print(f"\n{rt1} vs {rt2}: SKIPPED (insufficient samples)")
                continue
            
            # Mann-Whitney U test (non-parametric, doesn't assume normality)
            statistic, p_value = scipy_stats.mannwhitneyu(
                samples1, samples2, alternative='two-sided'
            )
            
            mean1 = statistics.mean(samples1)
            mean2 = statistics.mean(samples2)
            diff_pct = ((mean2 - mean1) / mean1) * 100
            
            significance = "***" if p_value < 0.001 else "**" if p_value < 0.01 else "*" if p_value < 0.05 else "ns"
            
            print(f"\n{rt1} vs {rt2}:")
            print(f"  Mean: {mean1:.3f} ms vs {mean2:.3f} ms (diff: {diff_pct:+.1f}%)")
            print(f"  p-value: {p_value:.6f} {significance}")
            if p_value < 0.05:
                print(f"  Result: Statistically significant difference")
            else:
                print(f"  Result: No significant difference")


def main():
    data = {}
    for rt, path in RUNTIMES.items():
        samples = load_samples(path)
        if samples:
            data[rt] = samples
            if len(samples) < 3:
                print(f"[WARN] Only {len(samples)} samples for {rt}. Recommend at least 5 for statistical validity.")
        else:
            print(f"[WARN] No cpu-hash samples for {rt} in {path}")

    if not data:
        print("No cpu-hash data found.")
        return

    print("\n" + "=" * 80)
    print("CPU-HASH SUMMARY (execution time)")
    print("=" * 80)
    for rt, samples in data.items():
        mean_val = statistics.mean(samples)
        median_val = statistics.median(samples)
        stdev_val = statistics.stdev(samples) if len(samples) > 1 else 0
        
        ci_low, ci_high = compute_confidence_interval(samples)
        ci_str = f", 95% CI=[{ci_low:.3f}, {ci_high:.3f}]" if ci_low is not None else ""
        
        print(
            f"- {rt:10s}: mean={mean_val:7.3f} ± {stdev_val:6.3f} ms, "
            f"median={median_val:7.3f} ms, "
            f"range=[{min(samples):.3f}, {max(samples):.3f}], "
            f"n={len(samples)}{ci_str}"
        )
    
    # Statistical comparisons
    compare_runtimes_statistically(data)

    labels = list(data.keys())
    series = [data[k] for k in labels]

    # Boxplot with enhanced styling
    fig, ax = plt.subplots(figsize=(10, 6))
    bp = ax.boxplot(series, tick_labels=labels, showfliers=True, patch_artist=True)
    
    # Color the boxes
    colors = ['lightblue', 'lightgreen', 'lightyellow', 'lightcoral']
    for patch, color in zip(bp['boxes'], colors):
        patch.set_facecolor(color)
    
    ax.set_ylabel("Execution time (ms)", fontsize=12)
    ax.set_title("CPU-hash execution time by runtime", fontsize=14, fontweight='bold')
    ax.grid(axis="y", alpha=0.3)
    
    out_box = OUT_DIR / "cpu_hash_outer_ms_boxplot.png"
    plt.savefig(out_box, dpi=300, bbox_inches="tight")
    print(f"\nSaved boxplot to {out_box}")
    plt.close()

    # Bar chart with error bars and confidence intervals
    means = [statistics.mean(s) for s in series]
    stdevs = [statistics.stdev(s) if len(s) > 1 else 0 for s in series]
    x = range(len(labels))

    fig, ax = plt.subplots(figsize=(10, 6))
    bars = ax.bar(x, means, yerr=stdevs, capsize=5, color=colors, 
                   edgecolor='black', linewidth=1.2)
    
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("Execution time (ms)", fontsize=12)
    ax.set_title("CPU-hash mean execution time by runtime (±1 std dev)", 
                 fontsize=14, fontweight='bold')
    ax.grid(axis="y", alpha=0.3)
    
    # Add value labels on bars
    for i, (mean, bar) in enumerate(zip(means, bars)):
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
                f'{mean:.1f}',
                ha='center', va='bottom', fontsize=10)
    
    out_bar = OUT_DIR / "cpu_hash_outer_ms_bar.png"
    plt.savefig(out_bar, dpi=300, bbox_inches="tight")
    print(f"Saved bar chart to {out_bar}")
    plt.close()
    
    print("\n" + "=" * 80)


if __name__ == "__main__":
    main()



def main():
    data = {}
    for rt, path in RUNTIMES.items():
        samples = load_samples(path)
        if samples:
            data[rt] = samples
            if len(samples) < 3:
                print(f"[WARN] Only {len(samples)} samples for {rt}. Recommend at least 5 for statistical validity.")
        else:
            print(f"[WARN] No cpu-hash samples for {rt} in {path}")

    if not data:
        print("No cpu-hash data found.")
        return

    print("\n" + "=" * 80)
    print("CPU-HASH SUMMARY (execution time)")
    print("=" * 80)
    for rt, samples in data.items():
        mean_val = statistics.mean(samples)
        median_val = statistics.median(samples)
        stdev_val = statistics.stdev(samples) if len(samples) > 1 else 0
        
        ci_low, ci_high = compute_confidence_interval(samples)
        ci_str = f", 95% CI=[{ci_low:.3f}, {ci_high:.3f}]" if ci_low is not None else ""
        
        print(
            f"- {rt:10s}: mean={mean_val:7.3f} ± {stdev_val:6.3f} ms, "
            f"median={median_val:7.3f} ms, "
            f"range=[{min(samples):.3f}, {max(samples):.3f}], "
            f"n={len(samples)}{ci_str}"
        )
    
    # Statistical comparisons
    compare_runtimes_statistically(data)

    labels = list(data.keys())
    series = [data[k] for k in labels]

    plt.figure()
    plt.boxplot(series, tick_labels=labels, showfliers=True)
    plt.ylabel("Execution time (ms)")
    plt.title("CPU-hash execution time by runtime")
    plt.grid(axis="y", alpha=0.3)
    out_box = OUT_DIR / "cpu_hash_outer_ms_boxplot.png"
    plt.savefig(out_box, bbox_inches="tight")
    print(f"Saved boxplot to {out_box}")

    means = [statistics.mean(s) for s in series]
    x = range(len(labels))

    plt.figure()
    plt.bar(x, means)
    plt.xticks(x, labels)
    plt.ylabel("Execution time (ms)")
    plt.title("CPU-hash mean execution time by runtime")
    plt.grid(axis="y", alpha=0.3)
    out_bar = OUT_DIR / "cpu_hash_outer_ms_bar.png"
    plt.savefig(out_bar, bbox_inches="tight")
    print(f"Saved bar chart to {out_bar}")


if __name__ == "__main__":
    main()
