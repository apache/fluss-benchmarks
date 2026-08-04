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

# Deploy Grafana dashboard via ConfigMap
# Usage: ./deploy-dashboard.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_YAML="${SCRIPT_DIR}/grafana-dashboard.yaml"
DASHBOARD_JSON="${SCRIPT_DIR}/fluss-flink-dashboard.json"
NAMESPACE="${NAMESPACE:-monitoring}"

echo "=== Deploying Grafana Dashboard ==="
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    echo "ERROR: Namespace ${NAMESPACE} does not exist"
    exit 1
fi

# Try to use YAML file first
if [ -f "${DASHBOARD_YAML}" ]; then
    echo "[1/2] Applying dashboard ConfigMap from YAML..."
    kubectl apply -f "${DASHBOARD_YAML}"
    
    if [ $? -eq 0 ]; then
        echo "  ✓ Dashboard ConfigMap deployed successfully from YAML!"
    else
        echo "  ⚠ Failed to deploy dashboard ConfigMap from YAML"
        exit 1
    fi
elif [ -f "${DASHBOARD_JSON}" ]; then
    echo "[1/2] Creating ConfigMap from JSON file..."
    kubectl create configmap fluss-flink-dashboard \
        --from-file=fluss-flink-dashboard.json="${DASHBOARD_JSON}" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | \
    kubectl label --local -f - grafana_dashboard=1 -o yaml | \
    kubectl apply -f -
    
    if [ $? -eq 0 ]; then
        echo "  ✓ Dashboard ConfigMap deployed successfully from JSON!"
    else
        echo "  ⚠ Failed to deploy dashboard ConfigMap from JSON"
        exit 1
    fi
else
    echo "ERROR: Neither dashboard YAML nor JSON file found"
    echo "  Expected: ${DASHBOARD_YAML}"
    echo "  Or: ${DASHBOARD_JSON}"
    exit 1
fi

echo ""
echo "[2/3] Verifying dashboard ConfigMap..."
sleep 2  # Wait a moment for ConfigMap to be fully available
if kubectl get configmap -n "${NAMESPACE}" fluss-flink-dashboard &>/dev/null; then
    kubectl get configmap -n "${NAMESPACE}" fluss-flink-dashboard
    echo "  ✓ ConfigMap verified"
else
    echo "  ⚠ ConfigMap not found, but deployment may have succeeded"
    echo "  Checking all ConfigMaps in namespace ${NAMESPACE}:"
    kubectl get configmap -n "${NAMESPACE}" | grep -i dashboard || echo "  No dashboard ConfigMaps found"
fi

echo ""
echo "[3/3] Importing dashboard via Grafana API..."
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin123}"
GRAFANA_POD=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${GRAFANA_POD}" ]; then
    echo "  ⚠ Grafana pod not found, skipping API import"
    echo "  You can import manually via Grafana UI"
else
    # Extract dashboard JSON from ConfigMap
    DASHBOARD_JSON_CONTENT=$(kubectl get configmap -n "${NAMESPACE}" fluss-flink-dashboard -o jsonpath='{.data.fluss-flink-dashboard\.json}')
    
    if [ -z "${DASHBOARD_JSON_CONTENT}" ]; then
        echo "  ⚠ Could not extract dashboard JSON from ConfigMap"
        echo "  You can import manually via Grafana UI"
    else
        # Prepare dashboard payload (ensure overwrite is set)
        DASHBOARD_PAYLOAD=$(echo "${DASHBOARD_JSON_CONTENT}" | jq '. + {overwrite: true}' 2>/dev/null || echo "${DASHBOARD_JSON_CONTENT}")
        
        # Import via Grafana API
        IMPORT_RESPONSE=$(kubectl exec -n "${NAMESPACE}" "${GRAFANA_POD}" -c grafana -- curl -s -X POST \
            "http://localhost:3000/api/dashboards/db" \
            -H "Content-Type: application/json" \
            -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
            -d "${DASHBOARD_PAYLOAD}" 2>/dev/null || echo "")
        
        if echo "${IMPORT_RESPONSE}" | grep -q '"status":"success"'; then
            DASHBOARD_UID=$(echo "${IMPORT_RESPONSE}" | jq -r '.uid // empty' 2>/dev/null || echo "")
            DASHBOARD_URL=$(echo "${IMPORT_RESPONSE}" | jq -r '.url // empty' 2>/dev/null || echo "")
            echo "  ✓ Dashboard imported successfully via Grafana API!"
            if [ -n "${DASHBOARD_UID}" ]; then
                echo "  Dashboard UID: ${DASHBOARD_UID}"
            fi
        else
            ERROR_MSG=$(echo "${IMPORT_RESPONSE}" | jq -r '.message // .error // "Unknown error"' 2>/dev/null || echo "Unknown error")
            echo "  ⚠ Dashboard import via API failed: ${ERROR_MSG}"
            echo "  You can import manually via Grafana UI"
        fi
    fi
fi

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/prometheus-grafana 3000:80"
echo "  Then open: http://localhost:3000"
echo "  Username: ${GRAFANA_USER}, Password: ${GRAFANA_PASS}"
echo ""

