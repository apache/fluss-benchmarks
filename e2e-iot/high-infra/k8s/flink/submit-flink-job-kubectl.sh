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

# Script to submit Flink job using kubectl exec into JobManager
# This script runs the Flink CLI from within the JobManager pod

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-fluss}"

echo "=== Submitting Flink Aggregator Job via Flink CLI ==="
echo ""

# Get JobManager pod name
JOBMANAGER_POD=$(kubectl get pod -n ${NAMESPACE} -l app=flink-jobmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${JOBMANAGER_POD}" ]; then
    echo "ERROR: Flink JobManager pod not found in namespace ${NAMESPACE}"
    exit 1
fi

echo "Using JobManager pod: ${JOBMANAGER_POD}"
echo ""

# Check if JAR needs to be copied to the pod
# For now, we'll assume the JAR is available in the demo image
# You can copy it first using: kubectl cp <local-jar> ${NAMESPACE}/${JOBMANAGER_POD}:/tmp/fluss-flink-realtime-demo.jar

echo "Submitting Flink job..."
echo "Note: The JAR file needs to be available in the JobManager pod"
echo ""

# Option 1: If JAR is already in the pod
# kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- /opt/flink/bin/flink run \
#     -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob \
#     /tmp/fluss-flink-realtime-demo.jar \
#     --bootstrap coordinator-server-hs.${NAMESPACE}.svc.cluster.local:9124 \
#     --database iot \
#     --table sensor_readings \
#     --window-minutes 1

# Option 2: Use REST API via curl from JobManager pod
echo "Using REST API to submit job..."
echo ""

# First, we need to get the JAR into the pod or use a URL
# For now, let's use the REST API approach with a helper pod

echo "Creating temporary pod to submit job..."
kubectl run flink-job-submitter-$(date +%s) \
    --rm -i --restart=Never \
    --image=curlimages/curl:latest \
    -n ${NAMESPACE} \
    -- sh -c "
        apk add --no-cache jq >/dev/null 2>&1 || true
        echo 'Uploading JAR...'
        # Note: You need to provide the JAR file
        # This is a template - you'll need to modify based on how you want to provide the JAR
        echo 'ERROR: JAR file path required'
        echo 'Please modify this script to provide the JAR file location'
        echo 'Options:'
        echo '  1. Copy JAR to a pod: kubectl cp <local-jar> ${NAMESPACE}/<pod>:/tmp/jar'
        echo '  2. Host JAR on HTTP server and download it'
        echo '  3. Use ConfigMap or PersistentVolume'
    " || true

echo ""
echo "For manual submission, you can:"
echo ""
echo "1. Port-forward Flink JobManager:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
echo ""
echo "2. Upload JAR via REST API:"
echo "   curl -X POST -H 'Expect:' -F 'jarfile=@/path/to/fluss-flink-realtime-demo.jar' http://localhost:8081/v1/jars/upload"
echo ""
echo "3. Submit job:"
echo "   curl -X POST http://localhost:8081/v1/jars/<jar-id>/run \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"entryClass\":\"org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob\",\"programArgs\":\"--bootstrap coordinator-server-hs.${NAMESPACE}.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1\",\"parallelism\":2}'"
echo ""

