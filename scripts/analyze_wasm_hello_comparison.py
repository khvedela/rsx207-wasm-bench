#!/usr/bin/env python3
import re
import statistics
from pathlib import Path

import matplotlib.pyplot as plt

ROOT_DIR = Path(__file__).resolve().parents[1]

RUNTIMES = {
    "wasmtime": ROOT_DIR / "results" / "raw" / "wasm" / "hello-wasm",
    "wasmedge": ROOT_DIR / "results" / "raw" / "wasmedge" / "hello-wasm",
}

OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

RUN_LOG_PATTERN = re.compile(r".*_run\.log$")
ELAPSED_MS_PATTERN = re.compile(r"elapsed_ms=([0-9.]+)")


def load_samples(path: Path):
    samples = []
    for log in sorted(path.glob("*_run.log")):
        if not RUN_LOG_PATTERN.match(log.name):
            continue
        with log.open("r") as f:
            for line in f:
                m = ELAPSED_MS_PATTERN.search(line)
                if m:
                    samples.append(float(m.group(1)))
    return samples


def main():
    data = {}
    for rt, path in RUNTIMES.items():
        samples = load_samples(path)
        if samples:
            data[rt] = samples
        else:
            print(f"[WARN] No hello-wasm samples for {rt} in {path}")

    if not data:
        print("No hello-wasm data found.")
        return

    print("hello-wasm summary (elapsed_ms):")
    for rt, samples in data.items():
        print(
            f"- {rt}: mean={statistics.mean(samples):.3f} ms, "
            f"p50={statistics.median(samples):.3f} ms, "
            f"min={min(samples):.3f}, max={max(samples):.3f}, n={len(samples)}"
        )

    labels = list(data.keys())
    series = [data[k] for k in labels]

    plt.figure()
    plt.boxplot(series, tick_labels=labels, showfliers=True)
    plt.ylabel("Execution time (ms)")
    plt.title("hello-wasm execution time by runtime")
    plt.grid(axis="y", alpha=0.3)
    out_box = OUT_DIR / "hello_wasm_elapsed_ms_boxplot.png"
    plt.savefig(out_box, bbox_inches="tight")
    print(f"Saved boxplot to {out_box}")

    means = [statistics.mean(s) for s in series]
    x = range(len(labels))

    plt.figure()
    plt.bar(x, means)
    plt.xticks(x, labels)
    plt.ylabel("Execution time (ms)")
    plt.title("hello-wasm mean execution time by runtime")
    plt.grid(axis="y", alpha=0.3)
    out_bar = OUT_DIR / "hello_wasm_elapsed_ms_bar.png"
    plt.savefig(out_bar, bbox_inches="tight")
    print(f"Saved bar chart to {out_bar}")


if __name__ == "__main__":
    main()
