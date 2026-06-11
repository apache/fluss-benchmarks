#!/bin/bash
#
# Run Fluss YCSB benchmark: 20 million records, insert/update/read.
# Usage: cd <YCSB_HOME> && bash scripts/run-20m-tests.sh [threads]
#

THREADS=${1:-64}

mkdir -p results logs

TS=$(date '+%Y%m%d-%H%M%S')

PASSED=0
FAILED=0
FAILED_TESTS=""

run_test() {
    local name="$1"
    local logfile="$2"
    shift 2
    echo ""
    echo "========================================"
    echo "  START: $name"
    echo "  Log:   $logfile"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    "$@" 2>&1 | tee "$logfile"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then
        echo "[PASSED] $name"
        PASSED=$((PASSED + 1))
    else
        echo "[FAILED] $name (exit code: $rc)"
        echo "  --- last 30 lines of $logfile ---"
        tail -n 30 "$logfile" | sed 's/^/    /'
        echo "  ---"
        FAILED=$((FAILED + 1))
        FAILED_TESTS="$FAILED_TESTS  - $name (log: $logfile)\n"
    fi
    echo "Waiting 30s before next test..."
    sleep 30
}

# === 1. Load: insert 20M records ===

run_test "Load: Insert 20M records" "logs/20m-load-insert-$TS.log" \
    bin/ycsb.sh load fluss -P workloads/workload_read -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/20m-load-insert.txt

# === 2. Run: 20M pure updates ===

run_test "Run: 20M updates" "logs/20m-run-update-$TS.log" \
    bin/ycsb.sh run fluss -P workloads/workload_update -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/20m-run-update.txt

# === 3. Run: 20M pure reads ===

run_test "Run: 20M reads" "logs/20m-run-read-$TS.log" \
    bin/ycsb.sh run fluss -P workloads/workload_read -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/20m-run-read.txt

# === Summary ===

SUMMARY_FILE="results/20m-summary-$TS.txt"

{
    echo "========================================"
    echo "  ALL 20M TESTS COMPLETE"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo "  Threads: $THREADS"
    echo "  Passed:  $PASSED"
    echo "  Failed:  $FAILED"
    if [ -n "$FAILED_TESTS" ]; then
        echo "  Failed tests:"
        echo -e "$FAILED_TESTS"
    fi
    echo "  Results: results/"
    echo "  Logs:    logs/  (suffix $TS)"
    echo "========================================"
} | tee "$SUMMARY_FILE"

echo ""
echo "Summary saved to: $SUMMARY_FILE"
