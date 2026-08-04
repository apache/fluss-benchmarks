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

NAMESPACE="${NAMESPACE:-fluss}"

echo "=== Step 8: Verifying deployment ==="
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

VERIFICATION_FAILED=0

# Check all pods in fluss namespace
echo "Checking pods in ${NAMESPACE} namespace..."
PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || echo "")
if [ -z "${PODS}" ]; then
    echo "ERROR: No pods found in ${NAMESPACE} namespace"
    VERIFICATION_FAILED=1
else
    echo "✓ Found pods in ${NAMESPACE} namespace:"
    kubectl get pods -n "${NAMESPACE}"
    
    # Check for pods not in Running state
    NOT_RUNNING=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l | awk '{print $1}')
    if [ "${NOT_RUNNING}" -gt "0" ]; then
        echo ""
        echo "WARNING: Some pods are not in Running/Completed state:"
        kubectl get pods -n "${NAMESPACE}" | grep -v "Running\|Completed"
        VERIFICATION_FAILED=1
    fi
fi

# Check monitoring namespace
echo ""
echo "Checking pods in monitoring namespace..."
MONITORING_PODS=$(kubectl get pods -n monitoring --no-headers 2>/dev/null || echo "")
if [ -z "${MONITORING_PODS}" ]; then
    echo "WARNING: No pods found in monitoring namespace"
else
    echo "✓ Found pods in monitoring namespace:"
    kubectl get pods -n monitoring
fi

# Check node placement
echo ""
echo "Checking node placement..."
echo "Coordinator nodes:"
kubectl get nodes -l node-type=coordinator 2>/dev/null || echo "  No coordinator nodes found"
echo "Tablet server nodes:"
kubectl get nodes -l node-type=tablet-server 2>/dev/null || echo "  No tablet server nodes found"
echo "Flink nodes:"
kubectl get nodes -l node-type=flink-jobmanager 2>/dev/null || echo "  No Flink JobManager nodes found"
kubectl get nodes -l node-type=flink-taskmanager 2>/dev/null || echo "  No Flink TaskManager nodes found"
echo "Producer nodes:"
kubectl get nodes -l node-type=producer 2>/dev/null || echo "  No producer nodes found"

# Check ServiceMonitors and PodMonitors
echo ""
echo "Checking ServiceMonitors and PodMonitors..."
if kubectl get servicemonitor -n "${NAMESPACE}" &> /dev/null; then
    echo "✓ ServiceMonitors found:"
    kubectl get servicemonitor -n "${NAMESPACE}"
else
    echo "WARNING: No ServiceMonitors found"
fi

if kubectl get podmonitor -n "${NAMESPACE}" &> /dev/null; then
    echo "✓ PodMonitors found:"
    kubectl get podmonitor -n "${NAMESPACE}"
else
    echo "WARNING: No PodMonitors found"
fi

# Check data flow
echo ""
echo "Checking data flow..."
echo "Producer logs (last 10 lines):"
kubectl logs -n "${NAMESPACE}" -l app=fluss-producer --tail=10 2>/dev/null | grep -i "records\|throughput" || echo "  No producer logs found"

echo ""
echo "Flink TaskManager logs (last 10 lines):"
kubectl logs -n "${NAMESPACE}" -l app=flink,component=taskmanager --tail=10 2>/dev/null | grep -i "aggregate\|records" || echo "  No Flink logs found"

# Summary
echo ""
echo "=== Verification Summary ==="
if [ "${VERIFICATION_FAILED}" -eq "0" ]; then
    echo "✓ All verifications passed"
    echo ""
    echo "Access services:"
    echo "  Flink Web UI: kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
    echo "  Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "  Prometheus: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
    echo ""
    echo "✓ Step 8 completed: Deployment verification completed successfully"
else
    echo "⚠ Some verifications failed - please check the output above"
    exit 1
fi

