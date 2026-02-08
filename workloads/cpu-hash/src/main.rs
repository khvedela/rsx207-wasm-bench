use sha2::{Digest, Sha256};
use std::env;
use std::time::Instant;

/// CPU-bound workload:
/// - Take N iterations from CLI (default: 2_000_000)
/// - Hash a small buffer in a tight loop
fn main() {
    let args: Vec<String> = env::args().collect();
    let iterations: u64 = if args.len() > 1 {
        args[1].parse().unwrap_or(2_000_000)
    } else {
        2_000_000
    };

    const BUFFER_SIZE: usize = 32;
    let prefix: &[u8] = b"cpu-hash-benchmark"; // length != 32, so don't assume

    // Fixed 32-byte buffer, prefix + zero padding
    let mut data = [0u8; BUFFER_SIZE];
    let prefix_len = prefix.len();
    assert!(prefix_len <= BUFFER_SIZE - 8, "prefix too long for buffer");
    data[..prefix_len].copy_from_slice(prefix);

    let start = Instant::now();

    let mut hasher = Sha256::new();
    for i in 0..iterations {
        // Put the counter in the last 8 bytes
        let counter_bytes = i.to_le_bytes(); // 8 bytes
        let offset = BUFFER_SIZE - counter_bytes.len(); // 32 - 8 = 24
        data[offset..].copy_from_slice(&counter_bytes);

        hasher.update(&data);
    }

    let digest = hasher.finalize();
    let elapsed = start.elapsed();

    println!(
        "iterations={} digest={:x} elapsed_ms={:.3}",
        iterations,
        digest,
        elapsed.as_secs_f64() * 1000.0
    );
}
