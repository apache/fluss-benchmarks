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
TERRAFORM_DIR="${K8S_DIR}/../terraform"

CLUSTER_NAME="${CLUSTER_NAME:-fluss-eks-cluster}"
REGION="${REGION:-us-west-2}"

echo "=== Step 1: Updating kubeconfig ==="
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${REGION}"
echo ""

# Check AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI is not installed or not in PATH"
    exit 1
fi

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Update kubeconfig
echo "Updating kubeconfig for EKS cluster..."
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}"

# Verify connection
echo "Verifying cluster connection..."
if kubectl cluster-info &> /dev/null; then
    echo "✓ Successfully connected to cluster"
    kubectl cluster-info
    echo ""
    echo "Cluster nodes:"
    kubectl get nodes
else
    echo "ERROR: Failed to connect to cluster"
    exit 1
fi

echo ""
echo "✓ Step 1 completed: kubeconfig updated successfully"


