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

# Script to manually submit Flink aggregator job to Flink cluster
# Usage: ./submit-flink-job.sh [jar-path] [flink-jobmanager-url]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-fluss}"

# Default values
JAR_PATH="${1:-/opt/flink/usrlib/fluss-flink-realtime-demo.jar}"
JOBMANAGER="${2:-flink-jobmanager.${NAMESPACE}.svc.cluster.local:8081}"

# If JAR_PATH is a local file, we need to upload it first
# Otherwise, assume it's already in the cluster or accessible

echo "=== Submitting Flink Aggregator Job ==="
echo "JAR Path: ${JAR_PATH}"
echo "Flink JobManager: ${JOBMANAGER}"
echo ""

# Check if we're running inside Kubernetes or locally
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
    echo "Running inside Kubernetes cluster..."
    
    # If JAR is a local path, check if it exists
    if [ -f "${JAR_PATH}" ]; then
        echo "Found JAR at ${JAR_PATH}"
        JAR_TO_UPLOAD="${JAR_PATH}"
    else
        echo "ERROR: JAR file not found at ${JAR_PATH}"
        echo "Please provide the path to the JAR file"
        exit 1
    fi
    
    # Upload JAR to Flink cluster
    echo "Uploading JAR to Flink cluster..."
    UPLOAD_RESPONSE=$(curl -s -X POST \
        "http://${JOBMANAGER}/v1/jars/upload" \
        -H "Content-Type: multipart/form-data" \
        -F "jarfile=@${JAR_TO_UPLOAD}")
    
    echo "Upload response: ${UPLOAD_RESPONSE}"
    
    # Extract JAR ID from response
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
    
    echo "JAR uploaded with ID: ${JAR_ID}"
    
    # Submit job
    echo "Submitting job..."
    JOB_RESPONSE=$(curl -s -X POST \
        "http://${JOBMANAGER}/v1/jars/${JAR_ID}/run" \
        -H "Content-Type: application/json" \
        -d '{
            "entryClass": "org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob",
            "programArgs": "--bootstrap coordinator-server-hs.fluss.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1",
            "parallelism": 2,
            "savepointPath": null,
            "allowNonRestoredState": false
        }')
    
    echo "Job submission response: ${JOB_RESPONSE}"
    
    # Extract Job ID from response
    if command -v jq &> /dev/null; then
        JOB_ID=$(echo "${JOB_RESPONSE}" | jq -r '.jobid')
    else
        JOB_ID=$(echo "${JOB_RESPONSE}" | grep -o '"jobid":"[^"]*' | sed 's/"jobid":"//')
    fi
    
    if [ -z "${JOB_ID}" ] || [ "${JOB_ID}" = "null" ]; then
        echo "ERROR: Failed to submit job"
        echo "Response: ${JOB_RESPONSE}"
        exit 1
    fi
    
    echo ""
    echo "✓ Job submitted successfully!"
    echo "Job ID: ${JOB_ID}"
    echo "Job status URL: http://${JOBMANAGER}/#/job/${JOB_ID}"
    
    # Wait a bit and check job status
    sleep 5
    if command -v jq &> /dev/null; then
        JOB_STATUS=$(curl -s "http://${JOBMANAGER}/jobs/${JOB_ID}" | jq -r '.state // "UNKNOWN"')
    else
        JOB_STATUS=$(curl -s "http://${JOBMANAGER}/jobs/${JOB_ID}" | grep -o '"state":"[^"]*' | sed 's/"state":"//' || echo "UNKNOWN")
    fi
    echo "Job status: ${JOB_STATUS}"
    
else
    echo "Running locally - using kubectl to execute in cluster..."
    echo ""
    echo "Option 1: Run script inside a pod with the JAR"
    echo "  kubectl run flink-job-submitter --rm -it --image=curlimages/curl:latest --restart=Never -n ${NAMESPACE} -- sh"
    echo ""
    echo "Option 2: Use Flink CLI from JobManager pod"
    echo "  kubectl exec -it -n ${NAMESPACE} \$(kubectl get pod -n ${NAMESPACE} -l app=flink-jobmanager -o jsonpath='{.items[0].metadata.name}') -- /opt/flink/bin/flink run -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob /path/to/jar"
    echo ""
    echo "Option 3: Port-forward and use REST API"
    echo "  kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
    echo "  Then run this script with JAR path"
    exit 1
fi

