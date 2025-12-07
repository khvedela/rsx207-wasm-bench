#!/usr/bin/env python3
import re
import statistics
from pathlib import Path

import matplotlib.pyplot as plt

ROOT_DIR = Path(__file__).resolve().parents[1]

RUNTIMES = {
    "native": ROOT_DIR / "results" / "raw" / "native" / "http-hello",
    "docker": ROOT_DIR / "results" / "raw" / "docker" / "http-hello",
    "wasmcloud_full": ROOT_DIR / "results" / "raw" / "wasmcloud" / "http-hello",
    "wasmcloud_comp": ROOT_DIR / "results" / "raw" / "wasmcloud-component" / "http-hello",
}

OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)

RUN_LOG_PATTERN = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)_run\.log$")
COLD_START_PATTERN = re.compile(r"cold_start_ms=(\d+\.?\d*)")
LATENCY_PATTERN = re.compile(
    r"req=(\d+)\s+http_code=(\d{3})\s+latency_ns=(\d+)\s+latency_ms=(\d+\.?\d*)"
)


def parse_run_log(path: Path):
    m = RUN_LOG_PATTERN.search(path.name)
    if not m:
        return None
    run_id = m.group(1)

    cold_start_ms = None
    latencies_ms = []

    with path.open("r") as f:
        for line in f:
            line = line.strip()

            m_cs = COLD_START_PATTERN.search(line)
            if m_cs:
                cold_start_ms = float(m_cs.group(1))

            m_lat = LATENCY_PATTERN.search(line)
            if m_lat:
                http_code = int(m_lat.group(2))
                latency_ms = float(m_lat.group(4))
                if http_code == 200:
                    latencies_ms.append(latency_ms)

    if cold_start_ms is None or not latencies_ms:
        return None

    return {
        "run_id": run_id,
        "cold_start_ms": cold_start_ms,
        "latencies_ms": latencies_ms,
    }


def load_runtime(runtime: str, dir_path: Path):
    logs = sorted(dir_path.glob("*_run.log"))
    runs = []
    for p in logs:
        parsed = parse_run_log(p)
        if parsed:
            runs.append(parsed)
    return runs


def agg_latencies(latencies):
    return {
        "mean": statistics.mean(latencies),
        "median": statistics.median(latencies),
        "min": min(latencies),
        "max": max(latencies),
    }


def main():
    data = {}
    for rt, path in RUNTIMES.items():
        runs = load_runtime(rt, path)
        if not runs:
            print(f"[WARN] No runs found for runtime '{rt}' in {path}")
            continue
        data[rt] = runs

    if not data:
        print("No data found for any runtime.")
        return

    # Text summary
    print("Summary per runtime:")
    for rt, runs in data.items():
        cs = [r["cold_start_ms"] for r in runs]
        all_lat = [x for r in runs for x in r["latencies_ms"]]
        lat_stats = agg_latencies(all_lat)
        print(
            f"- {rt}: "
            f"cold_start_ms mean={statistics.mean(cs):.3f}, "
            f"min={min(cs):.3f}, max={max(cs):.3f}; "
            f"latency_ms mean={lat_stats['mean']:.3f}, "
            f"p50={lat_stats['median']:.3f}, "
            f"min={lat_stats['min']:.3f}, max={lat_stats['max']:.3f}"
        )

    # Cold start comparison bar chart
    runtimes = []
    cold_means = []
    cold_mins = []
    cold_maxs = []

    for rt, runs in data.items():
        cs = [r["cold_start_ms"] for r in runs]
        runtimes.append(rt)
        cold_means.append(statistics.mean(cs))
        cold_mins.append(min(cs))
        cold_maxs.append(max(cs))

    x = range(len(runtimes))

    plt.figure()
    plt.bar(x, cold_means)
    plt.xticks(x, runtimes)
    plt.ylabel("Cold start (ms)")
    plt.title("HTTP hello cold start – mean per runtime")
    plt.grid(axis="y", alpha=0.3)
    out_cold = OUT_DIR / "http_hello_cold_start_mean_by_runtime.png"
    plt.savefig(out_cold, bbox_inches="tight")
    print(f"Saved cold start comparison to {out_cold}")

    # Latency boxplot per runtime
    latency_data = []
    labels = []
    for rt, runs in data.items():
        all_lat = [x for r in runs for x in r["latencies_ms"]]
        latency_data.append(all_lat)
        labels.append(rt)

    plt.figure()
    plt.boxplot(latency_data, tick_labels=labels, showfliers=True)
    plt.ylabel("Latency (ms)")
    plt.title("HTTP hello per-request latency by runtime")
    plt.grid(axis="y", alpha=0.3)
    out_lat = OUT_DIR / "http_hello_latency_boxplot_by_runtime.png"
    plt.savefig(out_lat, bbox_inches="tight")
    print(f"Saved latency comparison to {out_lat}")


if __name__ == "__main__":
    main()
