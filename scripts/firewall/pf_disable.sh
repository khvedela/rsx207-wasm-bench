#!/usr/bin/env bash
set -euo pipefail

echo "[pf] Disabling PF"
sudo pfctl -d
