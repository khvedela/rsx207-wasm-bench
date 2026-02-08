#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[notice] wasmCloud component-only benchmark is deprecated on macOS."
echo "[notice] Use the full wasmCloud benchmark instead:"
echo "[notice]   $ROOT_DIR/scripts/measure_wasmcloud_http_hello.sh"
echo "[notice] Running it now..."

exec "$ROOT_DIR/scripts/measure_wasmcloud_http_hello.sh"
