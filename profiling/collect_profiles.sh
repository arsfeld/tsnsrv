#!/usr/bin/env bash
# Collect pprof profiles for different service counts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
RESULTS_DIR="${SCRIPT_DIR}/results"
BINARY="${PROJECT_ROOT}/tsnsrv"

# Service counts to profile
SERVICE_COUNTS=(10 20 30 40 50)

# Duration to run before profiling (let it stabilize)
WARMUP_SECONDS=30

# CPU profile duration
CPU_PROFILE_SECONDS=30

# Prometheus/pprof address
PPROF_ADDR="localhost:9099"

echo "Building tsnsrv..."
cd "${PROJECT_ROOT}"
go build -o "${BINARY}" ./cmd/tsnsrv

echo ""
echo "Starting profiling runs..."
echo "======================================"

for count in "${SERVICE_COUNTS[@]}"; do
  config_file="${CONFIGS_DIR}/config_${count}_services.yaml"
  result_dir="${RESULTS_DIR}/${count}_services"

  echo ""
  echo "Profiling ${count} services..."
  echo "Config: ${config_file}"
  echo "Results: ${result_dir}"

  if [ ! -f "${config_file}" ]; then
    echo "ERROR: Config file not found: ${config_file}"
    echo "Run generate_configs.sh first"
    exit 1
  fi

  mkdir -p "${result_dir}"

  # Clean up state directory
  rm -rf /tmp/tsnsrv-profile
  mkdir -p /tmp/tsnsrv-profile

  # Note: We need a valid Tailscale auth key to actually run the services
  # For now, we'll document what would be collected

  echo "  Starting tsnsrv with ${count} services..."

  # Check if we have auth key
  if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "  WARNING: TS_AUTHKEY not set. Cannot actually run services."
    echo "  To run this profiling:"
    echo "    1. Set TS_AUTHKEY environment variable with a valid Tailscale auth key"
    echo "    2. Or use authkeyPath in config file"
    echo ""
    echo "  Profiles that would be collected:"
    echo "    - ${result_dir}/cpu.prof (30s CPU profile)"
    echo "    - ${result_dir}/heap.prof (memory allocation profile)"
    echo "    - ${result_dir}/goroutine.prof (goroutine count and stacks)"
    echo "    - ${result_dir}/allocs.prof (memory allocation counts)"
    echo "    - ${result_dir}/mutex.prof (mutex contention profile)"
    echo "    - ${result_dir}/block.prof (blocking profile)"
    echo ""
    continue
  fi

  # Start tsnsrv in background
  "${BINARY}" -config "${config_file}" > "${result_dir}/tsnsrv.log" 2>&1 &
  TSNSRV_PID=$!
  echo "  Started tsnsrv (PID: ${TSNSRV_PID})"

  # Wait for warmup
  echo "  Warming up for ${WARMUP_SECONDS} seconds..."
  sleep "${WARMUP_SECONDS}"

  # Check if process is still running
  if ! kill -0 "${TSNSRV_PID}" 2>/dev/null; then
    echo "  ERROR: tsnsrv process died during warmup"
    echo "  Check log: ${result_dir}/tsnsrv.log"
    continue
  fi

  echo "  Collecting profiles..."

  # CPU profile (takes 30 seconds)
  echo "    - CPU profile (${CPU_PROFILE_SECONDS}s)..."
  curl -s "http://${PPROF_ADDR}/debug/pprof/profile?seconds=${CPU_PROFILE_SECONDS}" \
    > "${result_dir}/cpu.prof" || true

  # Heap profile
  echo "    - Heap profile..."
  curl -s "http://${PPROF_ADDR}/debug/pprof/heap" \
    > "${result_dir}/heap.prof" || true

  # Goroutine profile
  echo "    - Goroutine profile..."
  curl -s "http://${PPROF_ADDR}/debug/pprof/goroutine" \
    > "${result_dir}/goroutine.prof" || true

  # Allocations profile
  echo "    - Allocations profile..."
  curl -s "http://${PPROF_ADDR}/debug/pprof/allocs" \
    > "${result_dir}/allocs.prof" || true

  # Mutex profile
  echo "    - Mutex profile..."
  curl -s "http://${PPROF_ADDR}/debug/pprof/mutex" \
    > "${result_dir}/mutex.prof" || true

  # Block profile
  echo "    - Block profile..."
  curl -s "http://${PPROF_ADDR}/debug/pprof/block" \
    > "${result_dir}/block.prof" || true

  # Collect process stats
  echo "    - Process statistics..."
  ps -p "${TSNSRV_PID}" -o pid,ppid,pcpu,pmem,vsz,rss,etime,comm > "${result_dir}/ps_stats.txt" || true

  # Count goroutines
  curl -s "http://${PPROF_ADDR}/debug/pprof/goroutine?debug=1" 2>/dev/null | \
    head -1 > "${result_dir}/goroutine_count.txt" || true

  echo "  Stopping tsnsrv..."
  kill "${TSNSRV_PID}" || true
  wait "${TSNSRV_PID}" 2>/dev/null || true

  echo "  ✓ Profiles collected for ${count} services"
done

echo ""
echo "======================================"
echo "Profiling complete!"
echo "Results in: ${RESULTS_DIR}"
echo ""
echo "To analyze profiles, use:"
echo "  go tool pprof ${BINARY} ${RESULTS_DIR}/<count>_services/<profile>.prof"
echo ""
echo "Example analysis commands:"
echo "  # CPU hotspots"
echo "  go tool pprof -top ${BINARY} ${RESULTS_DIR}/50_services/cpu.prof"
echo ""
echo "  # Goroutine analysis"
echo "  go tool pprof -top ${BINARY} ${RESULTS_DIR}/50_services/goroutine.prof"
echo ""
echo "  # Memory allocations"
echo "  go tool pprof -top ${BINARY} ${RESULTS_DIR}/50_services/heap.prof"
echo ""
echo "  # Interactive analysis"
echo "  go tool pprof ${BINARY} ${RESULTS_DIR}/50_services/cpu.prof"
