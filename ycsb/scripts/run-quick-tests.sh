#!/bin/bash
#
# Quick validation: 10,000 records per test to verify setup works.
# Usage: cd <YCSB_HOME> && bash scripts/run-quick-tests.sh
#

THREADS=4

mkdir -p results logs

TS=$(date '+%Y%m%d-%H%M%S')

echo "=== Quick Validation (10,000 records) ==="
echo "Logs dir: logs/  (suffix: $TS)"
echo ""

# 1. Load: insert 10,000 records
LOG="logs/quick-load-insert-$TS.log"
echo "[1/3] Load: Insert 10,000 records...  log: $LOG"
bin/ycsb.sh load fluss -P workloads/workload_quick_read -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/quick-load-insert.txt \
    2>&1 | tee "$LOG"
echo ""

# 2. Run: 10,000 updates
LOG="logs/quick-run-update-$TS.log"
echo "[2/3] Run: 10,000 updates...  log: $LOG"
bin/ycsb.sh run fluss -P workloads/workload_quick_update -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/quick-run-update.txt \
    2>&1 | tee "$LOG"
echo ""

# 3. Run: 10,000 reads
LOG="logs/quick-run-read-$TS.log"
echo "[3/3] Run: 10,000 reads...  log: $LOG"
bin/ycsb.sh run fluss -P workloads/workload_quick_read -P conf/fluss.properties \
    -threads $THREADS -s \
    -p exporter=site.ycsb.measurements.exporter.TextMeasurementsExporter \
    -p exportfile=results/quick-run-read.txt \
    2>&1 | tee "$LOG"
echo ""

echo "=== Done ==="
echo "Result files:"
ls -la results/quick-*.txt 2>/dev/null || echo "  No result files found!"
echo "Log files:"
ls -la logs/quick-*-$TS.log 2>/dev/null || echo "  No log files found!"
