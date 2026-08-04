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

# Submit Flink job using flink run command
# The JAR is already embedded in the Flink image at /opt/flink/usrlib/fluss-flink-realtime-demo.jar
# This script uses the JAR directly from the image without uploading

NAMESPACE="${NAMESPACE:-fluss}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Note: S3 ConfigMap configuration is now handled by deploy.sh during deployment
# No need to update it here during job submission
echo ""

JOBMANAGER_POD=$(kubectl get pod -n ${NAMESPACE} -l app=flink,component=jobmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${JOBMANAGER_POD}" ]; then
    echo "ERROR: Flink JobManager pod not found in namespace ${NAMESPACE}"
    exit 1
fi

echo "=== Submitting Flink Aggregator Job ==="
echo "JobManager Pod: ${JOBMANAGER_POD}"
echo "Namespace: ${NAMESPACE}"
echo "JAR Location: /opt/flink/usrlib/fluss-flink-realtime-demo.jar (from image)"
echo ""

# Cancel existing running jobs
echo "[1/3] Cancelling existing Flink jobs..."
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

# Verify JAR exists in the image
echo "[2/3] Verifying JAR exists in Flink image..."
JAR_EXISTS=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- test -f /opt/flink/usrlib/fluss-flink-realtime-demo.jar && echo "yes" || echo "no")

if [ "${JAR_EXISTS}" != "yes" ]; then
    echo "ERROR: JAR file not found at /opt/flink/usrlib/fluss-flink-realtime-demo.jar"
    echo "Please ensure the Flink image contains the JAR file"
    echo "You may need to rebuild and push the image using build-and-push.sh"
    exit 1
fi

JAR_SIZE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- ls -lh /opt/flink/usrlib/fluss-flink-realtime-demo.jar | awk '{print $5}')
echo "  ✓ JAR found (size: ${JAR_SIZE})"
echo ""

# Submit job using REST API with local JAR path
echo "[3/3] Submitting job via REST API using local JAR..."
# Use local:// protocol to reference JAR from JobManager's local filesystem
JOB_RESPONSE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- curl -s -X POST \
    "http://localhost:8081/v1/jobs" \
    -H "Content-Type: application/json" \
    -d "{
        \"jarFile\": \"local:///opt/flink/usrlib/fluss-flink-realtime-demo.jar\",
        \"entryClass\": \"org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob\",
        \"programArgs\": \"--bootstrap coordinator-server-hs.${NAMESPACE}.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1\",
        \"parallelism\": 192
    }" 2>&1)

echo "Job submission response: ${JOB_RESPONSE}"

# Extract Job ID from response
JOB_ID=$(echo "${JOB_RESPONSE}" | grep -o '"jobid":"[^"]*' | sed 's/"jobid":"//' || echo "")

if [ -z "${JOB_ID}" ]; then
    # Try alternative extraction
    JOB_ID=$(echo "${JOB_RESPONSE}" | jq -r '.jobid // empty' 2>/dev/null || echo "")
fi

if [ -z "${JOB_ID}" ]; then
    echo ""
    echo "⚠️  Could not extract Job ID from response"
    echo "Response: ${JOB_RESPONSE}"
    echo ""
    echo "Trying alternative method: Upload JAR first, then submit..."
    
    # Alternative: Upload JAR from local path, then submit
    UPLOAD_RESPONSE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- curl -s -X POST \
        "http://localhost:8081/v1/jars/upload" \
        -H "Content-Type: multipart/form-data" \
        -F "jarfile=@/opt/flink/usrlib/fluss-flink-realtime-demo.jar" 2>&1)
    
    JAR_ID=$(echo "${UPLOAD_RESPONSE}" | grep -o 'flink-web-upload/[^"]*' | sed 's|flink-web-upload/||' || echo "")
    
    if [ -z "${JAR_ID}" ]; then
        echo "ERROR: Failed to upload JAR"
        echo "Upload response: ${UPLOAD_RESPONSE}"
        exit 1
    fi
    
    echo "✓ JAR uploaded with ID: ${JAR_ID}"
    
    # Submit job
    JOB_RESPONSE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- curl -s -X POST \
        "http://localhost:8081/v1/jars/${JAR_ID}/run" \
        -H "Content-Type: application/json" \
        -d "{
            \"entryClass\": \"org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob\",
            \"programArgs\": \"--bootstrap coordinator-server-hs.${NAMESPACE}.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1\",
            \"parallelism\": 192
        }" 2>&1)
    
    JOB_ID=$(echo "${JOB_RESPONSE}" | grep -o '"jobid":"[^"]*' | sed 's/"jobid":"//' || echo "")
fi

if [ -z "${JOB_ID}" ]; then
    echo ""
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
if [ -n "${JOB_ID}" ]; then
    echo "  Then open: http://localhost:8081/#/job/${JOB_ID}"
else
    echo "  Then open: http://localhost:8081"
fi
echo ""
echo "View metrics dashboard:"
echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  Then open: http://localhost:3000"
echo "  Username: admin, Password: admin123"
echo ""
echo "Check job logs:"
echo "  kubectl logs -n ${NAMESPACE} ${JOBMANAGER_POD} -f"

