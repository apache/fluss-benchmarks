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
set -e

# Simple script to submit Flink job manually
# Prerequisites:
#   1. Port-forward Flink JobManager: kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
#   2. Have the JAR file available locally

NAMESPACE="${NAMESPACE:-fluss}"
JOBMANAGER="${JOBMANAGER:-localhost:8081}"
JAR_PATH="${1:-}"

if [ -z "${JAR_PATH}" ]; then
    echo "Usage: $0 <path-to-jar-file>"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/fluss-flink-realtime-demo.jar"
    echo ""
    echo "Prerequisites:"
    echo "  1. Port-forward Flink JobManager:"
    echo "     kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
    echo "  2. Have the JAR file available"
    exit 1
fi

if [ ! -f "${JAR_PATH}" ]; then
    echo "ERROR: JAR file not found: ${JAR_PATH}"
    exit 1
fi

echo "=== Submitting Flink Aggregator Job ==="
echo "JAR: ${JAR_PATH}"
echo "JobManager: ${JOBMANAGER}"
echo ""

# Check if JobManager is accessible
if ! curl -s "http://${JOBMANAGER}/overview" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to Flink JobManager at http://${JOBMANAGER}"
    echo "Make sure port-forward is running:"
    echo "  kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
    exit 1
fi

# Upload JAR
echo "Uploading JAR to Flink cluster..."
UPLOAD_RESPONSE=$(curl -s -X POST \
    "http://${JOBMANAGER}/v1/jars/upload" \
    -H "Expect:" \
    -F "jarfile=@${JAR_PATH}")

echo "Upload response: ${UPLOAD_RESPONSE}"

# Extract JAR ID
if command -v jq &> /dev/null; then
    JAR_ID=$(echo "${UPLOAD_RESPONSE}" | jq -r '.filename' | sed 's|.*/||')
else
    JAR_ID=$(echo "${UPLOAD_RESPONSE}" | grep -o '"filename":"[^"]*' | sed 's/"filename":"//' | sed 's|.*/||')
fi

if [ -z "${JAR_ID}" ] || [ "${JAR_ID}" = "null" ]; then
    echo "ERROR: Failed to upload JAR"
    echo "Response: ${UPLOAD_RESPONSE}"
    exit 1
fi

echo "✓ JAR uploaded with ID: ${JAR_ID}"
echo ""

# Submit job
echo "Submitting job..."
JOB_RESPONSE=$(curl -s -X POST \
    "http://${JOBMANAGER}/v1/jars/${JAR_ID}/run" \
    -H "Content-Type: application/json" \
    -d '{
        "entryClass": "org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob",
        "programArgs": "--bootstrap coordinator-server-hs.'"${NAMESPACE}"'.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1",
        "parallelism": 32,
        "savepointPath": null,
        "allowNonRestoredState": false
    }')

echo "Job submission response: ${JOB_RESPONSE}"
echo ""

# Extract Job ID
if command -v jq &> /dev/null; then
    JOB_ID=$(echo "${JOB_RESPONSE}" | jq -r '.jobid // empty')
    ERRORS=$(echo "${JOB_RESPONSE}" | jq -r '.errors[]? // empty' 2>/dev/null || echo "")
else
    JAR_ID=$(echo "${JOB_RESPONSE}" | grep -o '"jobid":"[^"]*' | sed 's/"jobid":"//' || echo "")
    ERRORS=$(echo "${JOB_RESPONSE}" | grep -o '"errors":\["[^"]*' | sed 's/"errors":\["//' || echo "")
fi

if [ -n "${ERRORS}" ]; then
    echo "ERROR: Job submission failed"
    echo "${ERRORS}"
    exit 1
fi

if [ -z "${JOB_ID}" ] || [ "${JOB_ID}" = "null" ]; then
    echo "ERROR: Failed to extract Job ID from response"
    echo "Response: ${JOB_RESPONSE}"
    exit 1
fi

echo "✓ Job submitted successfully!"
echo "Job ID: ${JOB_ID}"
echo "Job URL: http://${JOBMANAGER}/#/job/${JOB_ID}"
echo ""

# Check job status
sleep 3
if command -v jq &> /dev/null; then
    JOB_STATUS=$(curl -s "http://${JOBMANAGER}/jobs/${JOB_ID}" | jq -r '.state // "UNKNOWN"')
else
    JOB_STATUS=$(curl -s "http://${JOBMANAGER}/jobs/${JOB_ID}" | grep -o '"state":"[^"]*' | sed 's/"state":"//' || echo "UNKNOWN")
fi

echo "Job status: ${JOB_STATUS}"

if [ "${JOB_STATUS}" = "FAILED" ] || [ "${JOB_STATUS}" = "CANCELED" ]; then
    echo "WARNING: Job is in ${JOB_STATUS} state"
    exit 1
fi

echo ""
echo "Job is running! Monitor it at: http://${JOBMANAGER}/#/job/${JOB_ID}"

