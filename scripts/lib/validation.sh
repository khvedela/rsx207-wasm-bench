#!/usr/bin/env bash
# Validation and prerequisite checking functions

check_binary() {
  local binary=$1
  local install_cmd=$2
  
  if ! command -v "$binary" >/dev/null 2>&1; then
    echo "ERROR: $binary not found" >&2
    if [[ -n "$install_cmd" ]]; then
      echo "  Install with: $install_cmd" >&2
    fi
    return 1
  fi
  return 0
}

check_file_exists() {
  local file=$1
  local build_cmd=$2
  
  if [[ ! -f "$file" ]]; then
    echo "ERROR: Required file not found: $file" >&2
    if [[ -n "$build_cmd" ]]; then
      echo "  Build with: $build_cmd" >&2
    fi
    return 1
  fi
  return 0
}

check_prerequisites() {
  local errors=0
  
  # Always required
  check_binary gdate "brew install coreutils" || errors=$((errors + 1))
  check_binary curl "pre-installed on macOS" || errors=$((errors + 1))
  
  # Optional but recommended
  if ! check_binary bombardier "brew install bombardier"; then
    echo "  [WARN] bombardier not found - HTTP scaling tests will not work" >&2
  fi
  
  return $errors
}

validate_port_available() {
  local port=$1
  
  if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "ERROR: Port $port is already in use" >&2
    echo "  Process using port: $(lsof -Pi :$port -sTCP:LISTEN -t)" >&2
    return 1
  fi
  return 0
}

validate_sample_count() {
  local count=$1
  local min_recommended=${2:-5}
  local context=${3:-"this measurement"}
  
  if (( count == 0 )); then
    echo "ERROR: No samples found for $context" >&2
    return 2
  elif (( count < min_recommended )); then
    echo "WARNING: Only $count samples for $context (recommend >= $min_recommended for statistical validity)" >&2
    return 1
  fi
  return 0
}

dry_run_check() {
  local script_name=$1
  shift
  local required_bins=("$@")
  
  echo "[DRY RUN] Checking prerequisites for $script_name..."
  
  local errors=0
  for bin in "${required_bins[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "  ✗ $bin: NOT FOUND" >&2
      errors=$((errors + 1))
    else
      echo "  ✓ $bin: found ($(command -v "$bin"))"
    fi
  done
  
  if (( errors > 0 )); then
    echo "[DRY RUN] FAILED: $errors missing dependencies" >&2
    return 1
  fi
  
  echo "[DRY RUN] PASSED: All prerequisites met"
  return 0
}

detect_outliers_iqr() {
  # Read values from stdin, one per line
  # Prints outliers to stdout
  awk '
    {
      values[NR] = $1
    }
    END {
      # Sort values
      n = asort(values)
      
      # Calculate quartiles
      q1_idx = int(n * 0.25)
      q3_idx = int(n * 0.75)
      q1 = values[q1_idx]
      q3 = values[q3_idx]
      iqr = q3 - q1
      
      # Define outlier thresholds
      lower = q1 - 1.5 * iqr
      upper = q3 + 1.5 * iqr
      
      # Print outliers
      for (i = 1; i <= n; i++) {
        if (values[i] < lower || values[i] > upper) {
          print values[i]
        }
      }
    }
  '
}

check_disk_space() {
  local required_mb=${1:-1000}
  local target_dir=${2:-.}
  
  local available_mb=$(df -m "$target_dir" | tail -1 | awk '{print $4}')
  
  if (( available_mb < required_mb )); then
    echo "ERROR: Insufficient disk space" >&2
    echo "  Required: ${required_mb} MB, Available: ${available_mb} MB" >&2
    return 1
  fi
  
  return 0
}

validate_numeric_param() {
  local param_name=$1
  local param_value=$2
  local min_val=${3:-0}
  local max_val=${4:-999999999}
  
  if ! [[ "$param_value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $param_name must be a number, got: $param_value" >&2
    return 1
  fi
  
  if (( param_value < min_val || param_value > max_val )); then
    echo "ERROR: $param_name must be between $min_val and $max_val, got: $param_value" >&2
    return 1
  fi
  
  return 0
}
