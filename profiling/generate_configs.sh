#!/usr/bin/env bash
# Generate test configurations with varying service counts for profiling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"

# Service counts to test
SERVICE_COUNTS=(10 20 30 40 50)

# Dummy upstream URL (services won't actually receive traffic)
UPSTREAM_URL="http://localhost:8080"

echo "Generating test configurations..."

for count in "${SERVICE_COUNTS[@]}"; do
  config_file="${CONFIGS_DIR}/config_${count}_services.yaml"

  echo "Generating config for ${count} services: ${config_file}"

  # Start the YAML file with top-level prometheusAddr
  cat > "${config_file}" <<EOF
prometheusAddr: ":9099"
services:
EOF

  # Generate service entries
  for i in $(seq 1 "${count}"); do
    cat >> "${config_file}" <<EOF
  - name: "test-service-${i}"
    upstream: "${UPSTREAM_URL}"
    ephemeral: true
    funnel: false
    listenAddr: ":443"
    stateDir: "/tmp/tsnsrv-profile/service-${i}"
    suppressWhois: true
    timeout: 30s
EOF
  done

  echo "  Created: ${config_file}"
done

echo ""
echo "Configuration files generated in ${CONFIGS_DIR}/"
echo "Service counts: ${SERVICE_COUNTS[*]}"
