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
DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"
AWS_REGION="${REGION:-us-west-2}"

if [ -z "${FLUSS_VERSION:-}" ]; then
    echo "ERROR: FLUSS_VERSION is not set."
    echo "  source e2e-iot/default.env.sh --fluss-version 0.9.0-incubating"
    exit 1
fi

DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-}"
FLUSS_IMAGE_REPO="${FLUSS_IMAGE_REPO:-}"
FLUSS_IMAGE_TAG="${FLUSS_IMAGE_TAG:-${FLUSS_VERSION}}"

if [ -z "${DEMO_IMAGE_REPO}" ] || [ -z "${FLUSS_IMAGE_REPO}" ]; then
    echo "ERROR: DEMO_IMAGE_REPO and FLUSS_IMAGE_REPO must be set."
    echo "  source e2e-iot/default.env.sh --fluss-version ${FLUSS_VERSION}"
    exit 1
fi

echo "=== Step 3: Deploying all components ==="
echo "Namespace: ${NAMESPACE}"
echo "Demo Image (for Flink job submission): ${DEMO_IMAGE_REPO:-<not set>}:${DEMO_IMAGE_TAG}"
echo "Fluss Version: ${FLUSS_VERSION}"
echo "Fluss Image: ${FLUSS_IMAGE_REPO}"
echo "Flink Cluster Image: apache/flink:1.20.3-scala_2.12-java17 (hardcoded)"
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check helm is available
if ! command -v helm &> /dev/null; then
    echo "ERROR: helm is not installed or not in PATH"
    exit 1
fi

# Check deploy script exists
if [ ! -f "${K8S_DIR}/deploy.sh" ]; then
    echo "ERROR: deploy.sh not found at ${K8S_DIR}/deploy.sh"
    exit 1
fi

# Run deployment script (skip producer and Flink job submission)
# Producer will be deployed separately in step 5
echo "[2/2] Deploying ZooKeeper, Fluss, Flink cluster, and Monitoring..."
cd "${K8S_DIR}"

# Call deploy.sh - it will skip producer deployment since deploy.sh checks for DEMO_IMAGE_REPO
# Flink cluster uses hardcoded image: apache/flink:1.20.3-scala_2.12-java17
# Pass DEMO_IMAGE_REPO so Flink init container can use it
bash "${K8S_DIR}/deploy.sh" "${NAMESPACE}" "${DEMO_IMAGE_REPO}" "${DEMO_IMAGE_TAG}" "${FLUSS_IMAGE_REPO}"

# Wait for critical components to be ready
echo ""
echo "Waiting for components to be ready..."
echo "  Waiting for ZooKeeper..."
kubectl wait --for=condition=ready pod -l app=zookeeper -n "${NAMESPACE}" --timeout=120s || {
    echo "WARNING: ZooKeeper pods may not be ready yet"
}

echo "  Waiting for Fluss Coordinator..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=coordinator -n "${NAMESPACE}" --timeout=300s || {
    echo "WARNING: Fluss Coordinator pods may not be ready yet"
}

echo "  Waiting for Flink JobManager..."
kubectl wait --for=condition=ready pod -l app=flink,component=jobmanager -n "${NAMESPACE}" --timeout=300s || {
    echo "WARNING: Flink JobManager pods may not be ready yet"
}

echo ""
echo "Component status:"
kubectl get pods -n "${NAMESPACE}"
kubectl get pods -n monitoring 2>/dev/null || echo "Monitoring namespace not ready yet"

echo ""
echo "✓ Step 3 completed: All components deployed"

