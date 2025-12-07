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

COPY --from=builder /src/target/release/http-hello /app/http-hello

USER app
EXPOSE 8080

CMD ["./http-hello"]
