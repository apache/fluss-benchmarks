#!/bin/bash
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLINK_DIR="${K8S_DIR}/flink"

NAMESPACE="${NAMESPACE:-fluss}"
DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-}"
DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"

echo "=== Step 6: Submitting Flink aggregator job ==="
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check DEMO_IMAGE_REPO is set
if [ -z "${DEMO_IMAGE_REPO}" ]; then
    echo "ERROR: DEMO_IMAGE_REPO environment variable is not set"
    echo "Please set it with: export DEMO_IMAGE_REPO=your-repo/fluss-demo"
    exit 1
fi

# Verify Flink JobManager is ready
echo "Checking Flink JobManager status..."
JOBMANAGER_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=flink,component=jobmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${JOBMANAGER_POD}" ]; then
    echo "ERROR: Flink JobManager pod not found"
    exit 1
fi

JOBMANAGER_STATUS=$(kubectl get pod -n "${NAMESPACE}" "${JOBMANAGER_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${JOBMANAGER_STATUS}" != "Running" ]; then
    echo "ERROR: Flink JobManager pod is not Running (status: ${JOBMANAGER_STATUS})"
    exit 1
fi

echo "✓ Flink JobManager is ready: ${JOBMANAGER_POD}"
echo ""

# Check if JAR exists in JobManager pod (mounted via init container)
if kubectl exec -n "${NAMESPACE}" "${JOBMANAGER_POD}" -- test -f /opt/flink/usrlib/fluss-flink-realtime-demo.jar 2>/dev/null; then
    echo "✓ JAR found in JobManager pod at /opt/flink/usrlib/fluss-flink-realtime-demo.jar"
else
    echo "WARNING: JAR not found in JobManager pod at /opt/flink/usrlib/fluss-flink-realtime-demo.jar"
    echo "The JobManager should have the JAR mounted via init container."
    echo "Please ensure DEMO_IMAGE_REPO is set and redeploy the JobManager."
    exit 1
fi
echo ""

# Submit job from inside JobManager pod (same approach as submit-job-local.sh)
echo "[2/4] Submitting Flink job from inside JobManager pod..."
kubectl exec -n "${NAMESPACE}" "${JOBMANAGER_POD}" -- sh -c "
set -e

echo '[2/4] Cancelling existing Flink jobs...'
EXISTING_JOBS=\$(curl -s http://localhost:8081/jobs 2>/dev/null | grep -o '\"id\":\"[^\"]*' | sed 's/\"id\":\"//' || echo '')

if [ -n \"\${EXISTING_JOBS}\" ]; then
    echo \"\${EXISTING_JOBS}\" | while read job_id; do
        if [ -n \"\${job_id}\" ]; then
            JOB_STATUS=\$(curl -s \"http://localhost:8081/jobs/\${job_id}\" 2>/dev/null | grep -o '\"status\":\"[^\"]*' | sed 's/\"status\":\"//' || echo '')
            if [ \"\${JOB_STATUS}\" = \"RUNNING\" ] || [ \"\${JOB_STATUS}\" = \"CREATED\" ]; then
                echo \"  Cancelling job: \${job_id}\"
                curl -s -X PATCH \"http://localhost:8081/jobs/\${job_id}\" > /dev/null 2>&1 || true
            fi
        fi
    done
    sleep 3
else
    echo '  ℹ No running jobs found'
fi
echo ''

echo '[3/4] Uploading JAR to Flink cluster...'
UPLOAD_RESPONSE=\$(curl -s -X POST \
    \"http://localhost:8081/v1/jars/upload\" \
    -H \"Content-Type: multipart/form-data\" \
    -F \"jarfile=@/opt/flink/usrlib/fluss-flink-realtime-demo.jar\")

JAR_ID=\$(echo \"\${UPLOAD_RESPONSE}\" | grep -o 'flink-web-upload/[^\"]*' | sed 's|flink-web-upload/||' || echo '')

if [ -z \"\${JAR_ID}\" ]; then
    JAR_ID=\$(echo \"\${UPLOAD_RESPONSE}\" | grep -o '\"filename\":\"[^\"]*' | sed 's/\"filename\":\"//' | sed 's|.*/||' || echo '')
fi

if [ -z \"\${JAR_ID}\" ] || [ \"\${JAR_ID}\" = \"null\" ]; then
    echo \"ERROR: Failed to extract JAR ID from upload response\"
    echo \"Response: \${UPLOAD_RESPONSE}\"
    exit 1
fi

echo \"✓ JAR uploaded with ID: \${JAR_ID}\"
echo ''

echo '[4/4] Submitting job via REST API...'
JOB_RESPONSE=\$(curl -s -X POST \
    \"http://localhost:8081/v1/jars/\${JAR_ID}/run\" \
    -H \"Content-Type: application/json\" \
    -d '{
        \"entryClass\": \"org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob\",
        \"programArgs\": \"--bootstrap coordinator-server-hs.${NAMESPACE}.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1\",
        \"parallelism\": 192
    }')

JOB_ID=\$(echo \"\${JOB_RESPONSE}\" | grep -o '\"jobid\":\"[^\"]*' | sed 's/\"jobid\":\"//' || echo '')

if [ -z \"\${JOB_ID}\" ] || [ \"\${JOB_ID}\" = \"null\" ]; then
    echo \"ERROR: Failed to extract Job ID from submission response\"
    echo \"Response: \${JOB_RESPONSE}\"
    exit 1
fi

echo ''
echo \"✓ Job submitted successfully!\"
echo \"Job ID: \${JOB_ID}\"
echo ''
echo \"Job status URL: http://localhost:8081/#/job/\${JOB_ID}\"

# Wait and check job status
sleep 5
JOB_STATUS=\$(curl -s \"http://localhost:8081/jobs/\${JOB_ID}\" 2>/dev/null | grep -o '\"state\":\"[^\"]*' | sed 's/\"state\":\"//' || echo 'UNKNOWN')
echo \"Job status: \${JOB_STATUS}\"
"

if [ $? -ne 0 ]; then
    echo ""
    echo "ERROR: Flink job submission failed"
    exit 1
fi

echo ""
echo "✓ Step 6 completed: Flink aggregator job submitted successfully"
echo ""
echo "Monitor job at:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
echo "  Then open: http://localhost:8081"
