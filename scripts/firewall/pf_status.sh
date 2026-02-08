#!/usr/bin/env bash
set -euo pipefail

sudo pfctl -s info
sudo pfctl -sr
