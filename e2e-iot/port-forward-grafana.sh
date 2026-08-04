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

NAMESPACE="monitoring"
LOCAL_PORT="3000"
REMOTE_PORT="80"

echo "=== Port Forwarding Grafana ==="
echo "Namespace: ${NAMESPACE}"
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Find Grafana service
GRAFANA_SVC=$(kubectl get svc -n "${NAMESPACE}" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${GRAFANA_SVC}" ]; then
    # Try alternative service name
    GRAFANA_SVC=$(kubectl get svc -n "${NAMESPACE}" | grep -i grafana | awk '{print $1}' | head -1 || echo "")
fi

if [ -z "${GRAFANA_SVC}" ]; then
    echo "ERROR: Grafana service not found in namespace ${NAMESPACE}"
    echo ""
    echo "Available services in ${NAMESPACE} namespace:"
    kubectl get svc -n "${NAMESPACE}" || echo "  No services found"
    exit 1
fi

echo "Found Grafana service: ${GRAFANA_SVC}"
echo ""
echo "Starting port-forward..."
echo "  Local port: ${LOCAL_PORT}"
echo "  Remote port: ${REMOTE_PORT}"
echo ""
echo "Access Grafana at: http://localhost:${LOCAL_PORT}"
echo "  Username: admin"
echo "  Password: admin123"
echo ""
echo "Press Ctrl+C to stop port-forwarding"
echo ""

# Start port-forward
kubectl port-forward -n "${NAMESPACE}" "svc/${GRAFANA_SVC}" "${LOCAL_PORT}:${REMOTE_PORT}"

