#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="$SCRIPT_DIR/pf_rules.conf"

if [[ ! -f "$RULES_FILE" ]]; then
  echo "ERROR: PF rules file not found: $RULES_FILE" >&2
  exit 1
fi

echo "[pf] Loading rules from $RULES_FILE"
sudo pfctl -f "$RULES_FILE"
sudo pfctl -E
sudo pfctl -sr
