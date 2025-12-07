#!/usr/bin/env python3
import re
import statistics
from pathlib import Path

import matplotlib.pyplot as plt


ROOT_DIR = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT_DIR / "results" / "raw" / "native" / "http-hello"
OUT_DIR = ROOT_DIR / "results" / "processed"
OUT_DIR.mkdir(parents=True, exist_ok=True)


RUN_LOG_PATTERN = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)_run\.log$")

COLD_START_PATTERN = re.compile(r"cold_start_ms=(\d+\.?\d*)")
LATENCY_PATTERN = re.compile(
    r"req=(\d+)\s+http_code=(\d{3})\s+latency_ns=(\d+)\s+latency_ms=(\d+\.?\d*)"
)


def parse_run_log(path: Path):
    """
    Parse a single *_run.log file.

    Returns:
        {
            "run_id": str,
            "cold_start_ms": float,
            "latencies_ms": [float, ...],
        }
    """
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
                req_idx = int(m_lat.group(1))
                http_code = int(m_lat.group(2))
                latency_ms = float(m_lat.group(4))
                if http_code == 200:
                    latencies_ms.append(latency_ms)

    if cold_start_ms is None:
        print(f"[WARN] No cold_start_ms found in {path}")
        return None

    if not latencies_ms:
        print(f"[WARN] No latency lines found in {path}")
        return None

    return {
        "run_id": run_id,
        "cold_start_ms": cold_start_ms,
        "latencies_ms": latencies_ms,
    }


def main():
    run_logs = sorted(RAW_DIR.glob("*_run.log"))
    if not run_logs:
        print(f"No run logs found in {RAW_DIR}")
        return

    runs = []
    for p in run_logs:
        parsed = parse_run_log(p)
        if parsed:
            runs.append(parsed)

    if not runs:
        print("No valid runs parsed.")
        return

    # ---- Print text summary ----
    print("Parsed runs:")
    for i, r in enumerate(runs, start=1):
        lat = r["latencies_ms"]
        print(
            f"Run {i:02d} ({r['run_id']}): "
            f"cold_start_ms={r['cold_start_ms']:.3f}, "
            f"latency_ms mean={statistics.mean(lat):.3f}, "
            f"p50={statistics.median(lat):.3f}, "
            f"min={min(lat):.3f}, max={max(lat):.3f}"
        )

    # ---- Cold start plot ----
    cold_starts = [r["cold_start_ms"] for r in runs]
    run_indices = list(range(1, len(runs) + 1))

    plt.figure()
    plt.plot(run_indices, cold_starts, marker="o")
    plt.xlabel("Run index")
    plt.ylabel("Cold start (ms)")
    plt.title("Native http-hello cold start per run")
    plt.grid(True)
    cold_start_png = OUT_DIR / "native_http_hello_cold_start_ms.png"
    plt.savefig(cold_start_png, bbox_inches="tight")
    print(f"Saved cold start plot to {cold_start_png}")

    # ---- Latency distribution plot (all runs combined) ----
    all_latencies = []
    for r in runs:
        all_latencies.extend(r["latencies_ms"])

    plt.figure()
    plt.boxplot(all_latencies, vert=True, showfliers=True)
    plt.ylabel("Latency (ms)")
    plt.title("Native http-hello request latency (all runs)")
    plt.grid(True, axis="y")
    latency_box_png = OUT_DIR / "native_http_hello_latency_boxplot_ms.png"
    plt.savefig(latency_box_png, bbox_inches="tight")
    print(f"Saved latency boxplot to {latency_box_png}")

    # ---- Optional: per-run latency scatter ----
    plt.figure()
    for i, r in enumerate(runs, start=1):
        x = [i] * len(r["latencies_ms"])
        plt.scatter(x, r["latencies_ms"], s=10, alpha=0.6)
    plt.xlabel("Run index")
    plt.ylabel("Latency (ms)")
    plt.title("Native http-hello per-run latency scatter")
    plt.grid(True, axis="y")
    latency_scatter_png = OUT_DIR / "native_http_hello_latency_scatter_ms.png"
    plt.savefig(latency_scatter_png, bbox_inches="tight")
    print(f"Saved latency scatter to {latency_scatter_png}")


if __name__ == "__main__":
    main()
