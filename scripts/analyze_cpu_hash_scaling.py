#!/usr/bin/env python3
import re
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt

ROOT_DIR = Path(__file__).resolve().parents[1]

RUNTIMES = {
    "native": ROOT_DIR / "results" / "raw" / "native" / "cpu-hash-scaling",
    "docker": ROOT_DIR / "results" / "raw" / "docker" / "cpu-hash-scaling",
    "wasmtime": ROOT_DIR / "results" / "raw" / "wasm" / "cpu-hash-scaling",
    "wasmedge": ROOT_DIR / "results" / "raw" / "wasmedge" / "cpu-hash-scaling",
}

OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

RUN_LOG_PATTERN = re.compile(r".*_run\.log$")
SCALE_LINE_PATTERN = re.compile(r"conc=(\d+).*throughput_iter_s=([0-9.]+)")


def load_samples(path: Path):
    samples = defaultdict(list)
    for log in sorted(path.glob("*_run.log")):
        if not RUN_LOG_PATTERN.match(log.name):
            continue
        with log.open("r") as f:
            for line in f:
                m = SCALE_LINE_PATTERN.search(line)
                if m:
                    conc = int(m.group(1))
                    throughput = float(m.group(2))
                    samples[conc].append(throughput)
    return samples


def main():
    data = {}
    for rt, path in RUNTIMES.items():
        samples = load_samples(path)
        if samples:
            data[rt] = samples
        else:
            print(f"[WARN] No cpu-hash scaling samples for {rt} in {path}")

    if not data:
        print("No cpu-hash scaling data found.")
        return

    print("CPU-hash scaling summary (throughput_iter_s):")
    for rt, conc_map in data.items():
        concs = sorted(conc_map.keys())
        for conc in concs:
            vals = conc_map[conc]
            print(
                f"- {rt} conc={conc}: mean={statistics.mean(vals):.3f} "
                f"min={min(vals):.3f} max={max(vals):.3f} n={len(vals)}"
            )

    plt.figure()
    for rt, conc_map in data.items():
        concs = sorted(conc_map.keys())
        means = [statistics.mean(conc_map[c]) for c in concs]
        plt.plot(concs, means, marker="o", label=rt)

    plt.xlabel("Concurrency (instances)")
    plt.ylabel("Throughput (iterations/sec)")
    plt.title("CPU-hash scaling throughput by runtime")
    plt.grid(axis="y", alpha=0.3)
    plt.legend()

    out_plot = OUT_DIR / "cpu_hash_scaling_throughput.png"
    plt.savefig(out_plot, bbox_inches="tight")
    print(f"Saved scaling plot to {out_plot}")


if __name__ == "__main__":
    main()
