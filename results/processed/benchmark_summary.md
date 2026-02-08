# Benchmark Summary

## Performance Comparison

### Cold Start

| Runtime | Mean | Median | Std Dev | Min | Max | Samples |
|---------|------|--------|---------|-----|-----|---------|
| docker | 192.78 ms | 180.03 ms | 51.27 | 129.69 | 459.23 | 76 |
| native | 150.28 ms | 14.53 ms | 517.04 | 12.54 | 3059.39 | 70 |
| wasmtime | 51.52 ms | 37.39 ms | 24.45 | 33.80 | 133.92 | 62 |

**Speedup vs Docker:**

- native: 1.28x
- wasmtime: 3.74x


### HTTP Latency (p50)

| Runtime | Mean | Median | Std Dev | Min | Max | Samples |
|---------|------|--------|---------|-----|-----|---------|
| docker | 13.53 ms | 12.84 ms | 2.45 | 10.50 | 49.62 | 3800 |
| native | 11.61 ms | 11.22 ms | 1.50 | 9.49 | 36.05 | 2900 |
| wasmtime | 11.71 ms | 11.37 ms | 1.57 | 9.50 | 43.03 | 3100 |

**Speedup vs Docker:**

- native: 1.17x
- wasmtime: 1.16x


### HTTP Throughput

| Runtime | Mean | Median | Std Dev | Min | Max | Samples |
|---------|------|--------|---------|-----|-----|---------|
| docker | 604.51 req/s | 612.24 req/s | 90.34 | 296.90 | 790.60 | 75 |
| native | 694.14 req/s | 720.88 req/s | 87.92 | 462.97 | 871.62 | 53 |
| wasmtime | 687.00 req/s | 702.57 req/s | 70.97 | 331.92 | 781.60 | 62 |

**Speedup vs Docker:**

- native: 1.15x
- wasmtime: 1.14x


### Memory Usage

| Runtime | Mean | Median | Std Dev | Min | Max | Samples |
|---------|------|--------|---------|-----|-----|---------|
| docker | 1.36 MB | 0.87 MB | 0.99 | 0.86 | 4.86 | 75 |
| native | 1.82 MB | 1.83 MB | 0.01 | 1.81 | 1.83 | 53 |
| wasmtime | 22.68 MB | 19.31 MB | 8.91 | 19.14 | 47.27 | 62 |

**Speedup vs Docker:**

- native: 1.35x
- wasmtime: 16.74x


### CPU Hash Performance

| Runtime | Mean | Median | Std Dev | Min | Max | Samples |
|---------|------|--------|---------|-----|-----|---------|
| docker | 386.68 ms | 371.64 ms | 41.08 | 337.65 | 549.47 | 100 |
| native | 161.73 ms | 148.93 ms | 58.10 | 139.66 | 548.99 | 100 |
| wasmedge | 19758.90 ms | 20012.10 ms | 1865.08 | 18158.54 | 31221.51 | 100 |
| wasmtime | 194.43 ms | 165.62 ms | 121.76 | 148.01 | 1419.05 | 120 |

**Speedup vs Docker:**

- native: 2.39x
- wasmedge: 0.02x
- wasmtime: 1.99x

