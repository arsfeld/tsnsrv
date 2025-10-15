#!/usr/bin/env bash
# Analyze collected profiles to identify scaling issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
BINARY="${PROJECT_ROOT}/tsnsrv"
ANALYSIS_DIR="${SCRIPT_DIR}/analysis"

SERVICE_COUNTS=(10 20 30 40 50)

mkdir -p "${ANALYSIS_DIR}"

echo "==================================================="
echo "Multi-Service CPU Scaling Analysis"
echo "==================================================="
echo ""

# Check if profiles exist
missing=0
for count in "${SERVICE_COUNTS[@]}"; do
  if [ ! -f "${RESULTS_DIR}/${count}_services/cpu.prof" ]; then
    echo "WARNING: Missing profiles for ${count} services"
    missing=1
  fi
done

if [ ${missing} -eq 1 ]; then
  echo ""
  echo "ERROR: Some profiles are missing. Run collect_profiles.sh first."
  exit 1
fi

echo "1. Goroutine Count Scaling"
echo "---------------------------------------------------"
echo ""
echo "Service Count | Goroutine Count | Goroutines per Service"
echo "-------------|-----------------|----------------------"

goroutine_data="${ANALYSIS_DIR}/goroutine_scaling.csv"
echo "services,goroutines,per_service" > "${goroutine_data}"

for count in "${SERVICE_COUNTS[@]}"; do
  result_dir="${RESULTS_DIR}/${count}_services"

  # Extract goroutine count from profile
  goroutines=$(go tool pprof -raw "${result_dir}/goroutine.prof" 2>/dev/null | \
    grep -E "^goroutine [0-9]+" | wc -l || echo "0")

  per_service=$(echo "scale=2; ${goroutines} / ${count}" | bc)

  printf "%12s | %15s | %21s\n" "${count}" "${goroutines}" "${per_service}"
  echo "${count},${goroutines},${per_service}" >> "${goroutine_data}"
done

echo ""
echo "---------------------------------------------------"
echo ""

echo "2. CPU Profile Analysis - Top Functions"
echo "---------------------------------------------------"
echo ""

for count in "${SERVICE_COUNTS[@]}"; do
  echo "Services: ${count}"
  echo ""

  result_dir="${RESULTS_DIR}/${count}_services"
  go tool pprof -top -nodecount=10 "${result_dir}/cpu.prof" 2>/dev/null | \
    tail -n +4 | head -n 15 || echo "  No CPU data"

  echo ""
done

echo "---------------------------------------------------"
echo ""

echo "3. Memory Allocation Analysis"
echo "---------------------------------------------------"
echo ""

for count in "${SERVICE_COUNTS[@]}"; do
  echo "Services: ${count}"
  echo ""

  result_dir="${RESULTS_DIR}/${count}_services"
  go tool pprof -top -nodecount=10 "${result_dir}/heap.prof" 2>/dev/null | \
    tail -n +4 | head -n 15 || echo "  No heap data"

  echo ""
done

echo "---------------------------------------------------"
echo ""

echo "4. Mutex Contention Analysis"
echo "---------------------------------------------------"
echo ""

for count in "${SERVICE_COUNTS[@]}"; do
  echo "Services: ${count}"
  echo ""

  result_dir="${RESULTS_DIR}/${count}_services"
  go tool pprof -top -nodecount=10 "${result_dir}/mutex.prof" 2>/dev/null | \
    tail -n +4 | head -n 15 || echo "  No mutex contention data"

  echo ""
done

echo "---------------------------------------------------"
echo ""

echo "5. Scaling Comparison - 10 vs 50 Services"
echo "---------------------------------------------------"
echo ""
echo "CPU Profile Delta (what functions scale poorly):"
echo ""

base_prof="${RESULTS_DIR}/10_services/cpu.prof"
compare_prof="${RESULTS_DIR}/50_services/cpu.prof"

if [ -f "${base_prof}" ] && [ -f "${compare_prof}" ]; then
  go tool pprof -top -nodecount=15 -base="${base_prof}" "${compare_prof}" 2>/dev/null | \
    tail -n +4 | head -n 20 || echo "  Unable to compare profiles"
else
  echo "  Missing baseline or comparison profiles"
fi

echo ""
echo "---------------------------------------------------"
echo ""

echo "6. Process Statistics Summary"
echo "---------------------------------------------------"
echo ""
echo "Service Count | CPU% | Memory (RSS KB) | Runtime"
echo "-------------|------|----------------|--------"

for count in "${SERVICE_COUNTS[@]}"; do
  result_dir="${RESULTS_DIR}/${count}_services"
  if [ -f "${result_dir}/ps_stats.txt" ]; then
    stats=$(tail -1 "${result_dir}/ps_stats.txt" || echo "")
    cpu=$(echo "${stats}" | awk '{print $3}')
    mem=$(echo "${stats}" | awk '{print $6}')
    time=$(echo "${stats}" | awk '{print $7}')
    printf "%12s | %4s | %14s | %s\n" "${count}" "${cpu}" "${mem}" "${time}"
  fi
done

echo ""
echo "==================================================="
echo ""

# Generate detailed reports
echo "Generating detailed reports..."

# Top CPU consumers across all service counts
report_file="${ANALYSIS_DIR}/cpu_scaling_report.txt"
{
  echo "CPU Scaling Analysis Report"
  echo "Generated: $(date)"
  echo ""
  echo "==================================================="
  echo ""

  for count in "${SERVICE_COUNTS[@]}"; do
    echo "Services: ${count}"
    echo "---------------------------------------------------"
    go tool pprof -top -nodecount=20 "${RESULTS_DIR}/${count}_services/cpu.prof" 2>/dev/null || \
      echo "No data"
    echo ""
    echo ""
  done
} > "${report_file}"

echo "  CPU scaling report: ${report_file}"

# Goroutine analysis
report_file="${ANALYSIS_DIR}/goroutine_report.txt"
{
  echo "Goroutine Scaling Analysis"
  echo "Generated: $(date)"
  echo ""
  echo "==================================================="
  echo ""

  for count in "${SERVICE_COUNTS[@]}"; do
    echo "Services: ${count}"
    echo "---------------------------------------------------"
    echo ""
    go tool pprof -top -nodecount=20 "${RESULTS_DIR}/${count}_services/goroutine.prof" 2>/dev/null || \
      echo "No data"
    echo ""
    echo "Detailed goroutine dump:"
    go tool pprof -traces "${RESULTS_DIR}/${count}_services/goroutine.prof" 2>/dev/null | head -100 || \
      echo "No data"
    echo ""
    echo ""
  done
} > "${report_file}"

echo "  Goroutine report: ${report_file}"

echo ""
echo "==================================================="
echo "Analysis complete!"
echo ""
echo "Reports saved to: ${ANALYSIS_DIR}/"
echo ""
echo "Next steps:"
echo "1. Review the scaling patterns above"
echo "2. Look for functions that show super-linear growth"
echo "3. Check detailed reports in ${ANALYSIS_DIR}/"
echo "4. Generate visual call graphs:"
echo "   go tool pprof -svg ${BINARY} ${RESULTS_DIR}/50_services/cpu.prof > cpu_graph.svg"
echo ""
