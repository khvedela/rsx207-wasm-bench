# Stage 1: build the binary
FROM rust:1.84 AS builder

WORKDIR /src

# Copy manifest first (better for caching)
COPY Cargo.toml Cargo.lock ./
COPY src ./src

RUN cargo build --release

# Stage 2: minimal runtime image
FROM debian:bookworm-slim

RUN useradd -m app
WORKDIR /app

COPY --from=builder /src/target/release/cpu-hash /app/cpu-hash

USER app

# Default: 2_000_000 iterations, but we override via cmd args from the script
ENTRYPOINT ["./cpu-hash"]
