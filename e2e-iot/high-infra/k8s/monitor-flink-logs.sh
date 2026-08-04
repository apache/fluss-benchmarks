#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#!/bin/bash
# Script to monitor Flink job logs for errors and failures
# Usage: ./monitor-flink-logs.sh [job-id]

set -euo pipefail

NAMESPACE="${NAMESPACE:-fluss}"
JOB_ID="${1:-06fa48f0f071363871180341f4c447e5}"

echo "=== Flink Job Log Monitor ==="
echo "Job ID: ${JOB_ID}"
echo "Namespace: ${NAMESPACE}"
echo ""
echo "Monitoring logs for errors... (Press Ctrl+C to stop)"
echo ""

# Function to check job status
check_job_status() {
    JOBMANAGER_POD=$(kubectl get pod -n ${NAMESPACE} -l app=flink,component=jobmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${JOBMANAGER_POD}" ]; then
        STATE=$(kubectl exec -n ${NAMESPACE} "${JOBMANAGER_POD}" -- curl -s "http://localhost:8081/jobs/${JOB_ID}" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('state', 'UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Job State: ${STATE}"
        if [ "${STATE}" != "RUNNING" ] && [ "${STATE}" != "CREATED" ]; then
            echo "⚠️  WARNING: Job is not in RUNNING state!"
            return 1
        fi
    fi
    return 0
}

# Monitor TaskManager logs for errors
monitor_taskmanager_logs() {
    echo "=== TaskManager Logs (following for errors) ==="
    kubectl logs -n ${NAMESPACE} -l app=flink,component=taskmanager -f --tail=0 2>&1 | while IFS= read -r line; do
        if echo "$line" | grep -qiE "(error|exception|failed|fail|outofrange|timeout)"; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  ERROR DETECTED: $line"
        fi
    done
}

# Monitor JobManager logs for errors
monitor_jobmanager_logs() {
    echo "=== JobManager Logs (following for errors) ==="
    kubectl logs -n ${NAMESPACE} -l app=flink,component=jobmanager -f --tail=0 2>&1 | while IFS= read -r line; do
        if echo "$line" | grep -qiE "(error|exception|failed|fail|timeout)"; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  ERROR DETECTED: $line"
        fi
    done
}

# Check job status periodically
(
    while true; do
        check_job_status
        sleep 30
    done
) &
STATUS_PID=$!

# Start monitoring logs
trap "kill $STATUS_PID 2>/dev/null; exit" INT TERM

# Monitor both TaskManager and JobManager logs
monitor_taskmanager_logs &
TM_PID=$!

monitor_jobmanager_logs &
JM_PID=$!

# Wait for any process to exit
wait $TM_PID $JM_PID $STATUS_PID


