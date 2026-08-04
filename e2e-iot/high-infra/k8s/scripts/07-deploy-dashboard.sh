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
MONITORING_DIR="${K8S_DIR}/monitoring"

NAMESPACE="${NAMESPACE:-fluss}"

echo "=== Step 7: Deploying Grafana dashboard ==="
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check dashboard deployment script exists
if [ ! -f "${MONITORING_DIR}/deploy-dashboard.sh" ]; then
    echo "WARNING: deploy-dashboard.sh not found at ${MONITORING_DIR}/deploy-dashboard.sh"
    echo "Attempting to deploy dashboard manually..."
    
    # Deploy dashboard ConfigMap if script doesn't exist
    if [ -f "${MONITORING_DIR}/grafana-dashboard.yaml" ]; then
        echo "Deploying Grafana dashboard ConfigMap..."
        kubectl apply -f "${MONITORING_DIR}/grafana-dashboard.yaml"
        echo "✓ Dashboard ConfigMap deployed"
    else
        echo "ERROR: grafana-dashboard.yaml not found"
        exit 1
    fi
else
    # Use the deployment script
    echo "Running dashboard deployment script..."
    cd "${MONITORING_DIR}"
    # Dashboard ConfigMap goes in "monitoring" namespace, not the main namespace
    unset NAMESPACE
    export NAMESPACE="monitoring"
    ./deploy-dashboard.sh
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Dashboard deployment failed"
        exit 1
    fi
fi

# Verify Grafana pod is running
echo ""
echo "Checking Grafana status..."
GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${GRAFANA_POD}" ]; then
    echo "WARNING: Grafana pod not found in monitoring namespace"
else
    GRAFANA_STATUS=$(kubectl get pod -n monitoring "${GRAFANA_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${GRAFANA_STATUS}" = "Running" ]; then
        echo "✓ Grafana is running: ${GRAFANA_POD}"
    else
        echo "WARNING: Grafana pod is not Running (status: ${GRAFANA_STATUS})"
    fi
fi

# Verify dashboard ConfigMap
echo ""
echo "Checking dashboard ConfigMap..."
if kubectl get configmap -n monitoring fluss-flink-dashboard &> /dev/null; then
    echo "✓ Dashboard ConfigMap exists"
else
    echo "WARNING: Dashboard ConfigMap not found"
fi

echo ""
echo "✓ Step 7 completed: Grafana dashboard deployed successfully"


