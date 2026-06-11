#!/bin/bash
#
# Run Fluss YCSB benchmark: 100M records, 99 buckets, insert/update/read.
# Usage: cd <YCSB_HOME> && bash scripts/run-100m-b99-tests.sh [threads]
#

THREADS=${1:-3}

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

# === 1. Load: insert 100M records (99 buckets) ===

run_test "Load: Insert 100M (${THREADS}t, b99)" "logs/100m-${THREADS}t-b99-load-insert-$TS.log" \
    bin/ycsb.sh load fluss -P workloads/workload_100m_b99_read -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/100m-${THREADS}t-b99-load-insert.txt

# === 2. Run: 100M pure updates (99 buckets) ===

run_test "Run: 100M updates (${THREADS}t, b99)" "logs/100m-${THREADS}t-b99-run-update-$TS.log" \
    bin/ycsb.sh run fluss -P workloads/workload_100m_b99_update -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/100m-${THREADS}t-b99-run-update.txt

# === 3. Run: 100M pure reads (99 buckets) ===

run_test "Run: 100M reads (${THREADS}t, b99)" "logs/100m-${THREADS}t-b99-run-read-$TS.log" \
    bin/ycsb.sh run fluss -P workloads/workload_100m_b99_read -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/100m-${THREADS}t-b99-run-read.txt

# === Summary ===

SUMMARY_FILE="results/100m-${THREADS}t-b99-summary-$TS.txt"

{
    echo "========================================"
    echo "  ALL 100M (${THREADS} THREADS, 99 BUCKETS) TESTS COMPLETE"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo "  Threads: $THREADS"
    echo "  Buckets: 99"
    echo "  Table:   usertable_b99"
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
