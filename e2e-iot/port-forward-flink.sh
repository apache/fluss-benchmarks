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

NAMESPACE="fluss"
LOCAL_PORT="8081"
REMOTE_PORT="8081"
SERVICE_NAME="flink-jobmanager"

echo "=== Port Forwarding Flink JobManager ==="
echo "Namespace: ${NAMESPACE}"
echo "Service: ${SERVICE_NAME}"
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check if service exists
if ! kubectl get svc -n "${NAMESPACE}" "${SERVICE_NAME}" &> /dev/null; then
    echo "ERROR: Service ${SERVICE_NAME} not found in namespace ${NAMESPACE}"
    echo ""
    echo "Available services in ${NAMESPACE} namespace:"
    kubectl get svc -n "${NAMESPACE}" || echo "  No services found"
    exit 1
fi

# Check if JobManager pod is running
JOBMANAGER_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=flink,component=jobmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${JOBMANAGER_POD}" ]; then
    echo "WARNING: Flink JobManager pod not found. Port-forward may fail."
    echo ""
    echo "Available pods in ${NAMESPACE} namespace:"
    kubectl get pods -n "${NAMESPACE}" | grep -E "NAME|flink" || kubectl get pods -n "${NAMESPACE}"
else
    JOBMANAGER_STATUS=$(kubectl get pod -n "${NAMESPACE}" "${JOBMANAGER_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${JOBMANAGER_STATUS}" != "Running" ]; then
        echo "WARNING: Flink JobManager pod is not Running (status: ${JOBMANAGER_STATUS})"
    else
        echo "✓ Flink JobManager pod is running: ${JOBMANAGER_POD}"
    fi
fi

echo ""
echo "Starting port-forward..."
echo "  Local port: ${LOCAL_PORT}"
echo "  Remote port: ${REMOTE_PORT}"
echo ""
echo "Access Flink Web UI at: http://localhost:${LOCAL_PORT}"
echo ""
echo "Press Ctrl+C to stop port-forwarding"
echo ""

# Start port-forward
kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}"

