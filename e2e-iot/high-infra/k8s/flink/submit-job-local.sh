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

# Submit Flink job using REST API
# The JAR is embedded in the Flink image at /opt/flink/usrlib/fluss-flink-realtime-demo.jar

NAMESPACE="${NAMESPACE:-fluss}"
JOBMANAGER_POD=$(kubectl get pod -n ${NAMESPACE} -l app=flink,component=jobmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${JOBMANAGER_POD}" ]; then
    echo "ERROR: Flink JobManager pod not found in namespace ${NAMESPACE}"
    exit 1
fi

echo "=== Submitting Flink Aggregator Job ==="
echo "JobManager Pod: ${JOBMANAGER_POD}"
echo "Namespace: ${NAMESPACE}"
echo ""

# Cancel existing running jobs
echo "[1/4] Cancelling existing Flink jobs..."
EXISTING_JOBS=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- curl -s http://localhost:8081/jobs 2>/dev/null | jq -r '.jobs[]? | select(.status == "RUNNING" or .status == "CREATED") | .id' 2>/dev/null || echo "")

if [ -n "${EXISTING_JOBS}" ]; then
    echo "${EXISTING_JOBS}" | while read job_id; do
        if [ -n "${job_id}" ]; then
            echo "  Cancelling job: ${job_id}"
            kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- curl -s -X PATCH "http://localhost:8081/jobs/${job_id}" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo "    ✓ Job ${job_id} cancelled"
            else
                echo "    ⚠ Failed to cancel job ${job_id}"
            fi
        fi
    done
    # Wait a moment for jobs to be cancelled
    sleep 3
else
    echo "  ℹ No running jobs found"
fi
echo ""

# Upload JAR via REST API
echo "[2/3] Uploading JAR to Flink cluster..."
echo "Uploading JAR to Flink cluster..."
UPLOAD_RESPONSE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- curl -s -X POST \
    "http://localhost:8081/v1/jars/upload" \
    -H "Content-Type: multipart/form-data" \
    -F "jarfile=@/opt/flink/usrlib/fluss-flink-realtime-demo.jar")

echo "Upload response: ${UPLOAD_RESPONSE}"

# Extract JAR ID from response
JAR_ID=$(echo "${UPLOAD_RESPONSE}" | grep -o 'flink-web-upload/[^"]*' | sed 's|flink-web-upload/||' || echo "")

if [ -z "${JAR_ID}" ]; then
    echo "ERROR: Failed to extract JAR ID from upload response"
    echo "Response: ${UPLOAD_RESPONSE}"
    exit 1
fi

echo "✓ JAR uploaded with ID: ${JAR_ID}"
echo ""

# Submit job via REST API
echo "[3/3] Submitting job via REST API..."
JOB_RESPONSE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- curl -s -X POST \
    "http://localhost:8081/v1/jars/${JAR_ID}/run" \
    -H "Content-Type: application/json" \
    -d "{
        \"entryClass\": \"org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob\",
        \"programArgs\": \"--bootstrap coordinator-server-hs.${NAMESPACE}.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1\",
        \"parallelism\": 192
    }")

echo "Job submission response: ${JOB_RESPONSE}"

# Extract Job ID from response
JOB_ID=$(echo "${JOB_RESPONSE}" | grep -o '"jobid":"[^"]*' | sed 's/"jobid":"//' || echo "")

if [ -z "${JOB_ID}" ]; then
    echo "ERROR: Failed to extract Job ID from submission response"
    echo "Response: ${JOB_RESPONSE}"
    exit 1
fi

echo ""
echo "✓ Job submitted successfully!"
echo "Job ID: ${JOB_ID}"
echo ""
echo "Monitor job at:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
echo "  Then open: http://localhost:8081/#/job/${JOB_ID}"
echo ""
echo "View metrics dashboard:"
echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  Then open: http://localhost:3000"
echo "  Username: admin, Password: admin123"

