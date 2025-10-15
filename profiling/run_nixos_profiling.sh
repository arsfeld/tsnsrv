#!/usr/bin/env bash
# Run profiling using NixOS VM with Headscale (no internet/Tailscale account required)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"

# Service counts to profile
SERVICE_COUNTS=(10 20 30 40 50)

# Duration to run before profiling (let it stabilize)
WARMUP_SECONDS=60

# CPU profile duration
CPU_PROFILE_SECONDS=30

# Prometheus/pprof address (will be forwarded from VM)
PPROF_ADDR="localhost:9099"

# Check if nix is available
if ! command -v nix &> /dev/null; then
  echo "ERROR: nix command not found"
  echo "This script requires Nix to be installed"
  exit 1
fi

echo "NixOS-based Profiling Runner"
echo "======================================"
echo "This will profile tsnsrv using isolated VMs with Headscale"
echo "No internet connection or Tailscale account required"
echo ""

# Build the binary for profile analysis
echo "Building tsnsrv binary for profile analysis..."
cd "${PROJECT_ROOT}"
nix build -L
BINARY="${PROJECT_ROOT}/result/bin/tsnsrv"

if [ ! -f "${BINARY}" ]; then
  echo "ERROR: Failed to build tsnsrv"
  exit 1
fi

echo "✓ Binary built: ${BINARY}"
echo ""

for count in "${SERVICE_COUNTS[@]}"; do
  result_dir="${RESULTS_DIR}/${count}_services"

  echo ""
  echo "======================================"
  echo "Profiling ${count} services..."
  echo "======================================"

  mkdir -p "${result_dir}"

  # Build the profiling VM for this service count
  echo "Building profiling VM (${count} services)..."

  # Note: This requires the VM config to be exposed in flake.nix
  # For now, we'll use the test approach and document the limitation

  echo "NOTE: Profile collection via NixOS VM requires manual setup"
  echo ""
  echo "To collect profiles for ${count} services:"
  echo "1. Run the profiling test:"
  echo "   nix build .#checks.x86_64-linux.profiling/services-${count} -L"
  echo ""
  echo "2. The test will verify that profiling works but won't extract files"
  echo ""
  echo "Alternative: Use the standard collect_profiles.sh with TS_AUTHKEY set"
  echo ""

  # For now, skip actual VM building until we resolve the extraction issue
  continue

  # TODO: Implement VM building and profile extraction
  # The challenge is that NixOS tests don't easily expose artifacts
  # Possible solutions:
  # 1. Create a separate VM builder (not a test) with port forwarding
  # 2. Use nixos-rebuild build-vm and manual profile collection
  # 3. Have the test encode profiles in output and decode them
done

echo ""
echo "======================================"
echo "Profiling setup complete!"
echo ""
echo "Current limitation: Profile extraction from NixOS VMs needs implementation"
echo "See: nixos/tests/profiling/vm-config.nix for VM configuration"
echo ""
echo "For now, use collect_profiles.sh with a Tailscale auth key:"
echo "  export TS_AUTHKEY='your-key'"
echo "  ./profiling/collect_profiles.sh"
