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
JOBS_DIR="${K8S_DIR}/jobs"

NAMESPACE="${NAMESPACE:-fluss}"
DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-}"
DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"

# Producer configuration defaults
export BUCKETS="${BUCKETS:-128}"
export PRODUCER_RATE="${PRODUCER_RATE:-250000}"
export TOTAL_PRODUCERS="${TOTAL_PRODUCERS:-8}"
export PRODUCER_FLUSH_EVERY="${PRODUCER_FLUSH_EVERY:-5000}"
export CLIENT_WRITER_BATCH_TIMEOUT="${CLIENT_WRITER_BATCH_TIMEOUT:-90ms}"
export BOOTSTRAP="${BOOTSTRAP:-coordinator-server-hs.fluss.svc.cluster.local:9124}"
export DATABASE="${DATABASE:-iot}"
export TABLE="${TABLE:-sensor_readings}"

echo "=== Step 5: Deploying multi-instance producer ==="
echo "Namespace: ${NAMESPACE}"
echo "Demo Image: ${DEMO_IMAGE_REPO}:${DEMO_IMAGE_TAG}"
echo "Buckets: ${BUCKETS}"
echo "Total Producers: ${TOTAL_PRODUCERS}"
echo "Rate per Producer: ${PRODUCER_RATE} records/sec"
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check if demo image repo is set
if [ -z "${DEMO_IMAGE_REPO}" ]; then
    echo "ERROR: DEMO_IMAGE_REPO is not set"
    exit 1
fi

# Check scripts exist
if [ ! -f "${JOBS_DIR}/create-table.sh" ]; then
    echo "ERROR: create-table.sh not found at ${JOBS_DIR}/create-table.sh"
    exit 1
fi

if [ ! -f "${JOBS_DIR}/deploy-producer-multi-instance.sh" ]; then
    echo "ERROR: deploy-producer-multi-instance.sh not found at ${JOBS_DIR}/deploy-producer-multi-instance.sh"
    exit 1
fi

# Export all variables needed
export NAMESPACE DEMO_IMAGE_REPO DEMO_IMAGE_TAG

# Step 5.1: Create table
echo "[5.1/2] Creating Fluss table with ${BUCKETS} buckets..."
cd "${JOBS_DIR}"
"${JOBS_DIR}/create-table.sh" \
    --namespace "${NAMESPACE}" \
    --bootstrap "${BOOTSTRAP}" \
    --database "${DATABASE}" \
    --table "${TABLE}" \
    --buckets "${BUCKETS}" \
    --image-repo "${DEMO_IMAGE_REPO}" \
    --image-tag "${DEMO_IMAGE_TAG}"

if [ $? -ne 0 ]; then
    echo "ERROR: Table creation failed"
    exit 1
fi

echo "✓ Table created successfully"

# Step 5.2: Deploy multi-instance producer
echo ""
echo "[5.2/2] Deploying ${TOTAL_PRODUCERS} producer instances..."
"${JOBS_DIR}/deploy-producer-multi-instance.sh" --wait

if [ $? -ne 0 ]; then
    echo "ERROR: Producer deployment failed"
    exit 1
fi

# Verify producer pods are running
echo ""
echo "Verifying producer pods..."
sleep 5
PRODUCER_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer --no-headers 2>/dev/null | wc -l | awk '{print $1}')
if [ "${PRODUCER_PODS}" -eq "0" ]; then
    echo "ERROR: No producer pods found"
    exit 1
fi

echo "✓ Found ${PRODUCER_PODS} producer pods"
kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer -o wide

# Check pod distribution
echo ""
echo "Producer pod distribution:"
kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' | sort -k2

echo ""
echo "✓ Step 5 completed: Multi-instance producer deployed successfully"

