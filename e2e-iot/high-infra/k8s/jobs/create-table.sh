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

# Script to create Fluss table with specified number of buckets
# This should be run before deploying the producer

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default values
NAMESPACE="${NAMESPACE:-fluss}"
BOOTSTRAP="${BOOTSTRAP:-coordinator-server-hs.fluss.svc.cluster.local:9124}"
DATABASE="${DATABASE:-iot}"
TABLE="${TABLE:-sensor_readings}"
BUCKETS="${BUCKETS:-128}"
DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo}"
DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --bootstrap)
            BOOTSTRAP="$2"
            shift 2
            ;;
        --database)
            DATABASE="$2"
            shift 2
            ;;
        --table)
            TABLE="$2"
            shift 2
            ;;
        --buckets)
            BUCKETS="$2"
            shift 2
            ;;
        --image-repo)
            DEMO_IMAGE_REPO="$2"
            shift 2
            ;;
        --image-tag)
            DEMO_IMAGE_TAG="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --namespace NAMESPACE     Kubernetes namespace (default: fluss)"
            echo "  --bootstrap BOOTSTRAP     Fluss coordinator address (default: coordinator-server-hs.fluss.svc.cluster.local:9124)"
            echo "  --database DATABASE       Database name (default: iot)"
            echo "  --table TABLE             Table name (default: sensor_readings)"
            echo "  --buckets BUCKETS         Number of buckets (default: 128)"
            echo "  --image-repo REPO         Docker image repository (required, no default)"
            echo "  --image-tag TAG           Docker image tag (default: latest)"
            echo "  --help                    Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  NAMESPACE, BOOTSTRAP, DATABASE, TABLE, BUCKETS, DEMO_IMAGE_REPO, DEMO_IMAGE_TAG"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "=== Creating Fluss Table with ${BUCKETS} Buckets ==="
echo "  Namespace: ${NAMESPACE}"
echo "  Bootstrap: ${BOOTSTRAP}"
echo "  Database: ${DATABASE}"
echo "  Table: ${TABLE}"
echo "  Buckets: ${BUCKETS}"
echo "  Image: ${DEMO_IMAGE_REPO}:${DEMO_IMAGE_TAG}"
echo ""

# Export variables for envsubst
export NAMESPACE BOOTSTRAP DATABASE TABLE BUCKETS DEMO_IMAGE_REPO DEMO_IMAGE_TAG

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    echo "ERROR: Namespace '${NAMESPACE}' does not exist"
    exit 1
fi

# Delete existing job if it exists (to allow re-running)
echo "Cleaning up any existing create-table job..."
kubectl delete job -n "${NAMESPACE}" fluss-create-table --ignore-not-found=true

# Wait a moment for cleanup
sleep 2

# Apply the job YAML
echo "Creating table creation job..."
envsubst < "${K8S_DIR}/jobs/create-table-job.yaml" | kubectl apply -f -

# Wait for job to complete
echo ""
echo "Waiting for job to complete..."
JOB_NAME="fluss-create-table"

# Wait for job to start
TIMEOUT=60
ELAPSED=0
while ! kubectl get job -n "${NAMESPACE}" "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q "True"; do
    if kubectl get job -n "${NAMESPACE}" "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null | grep -q "True"; then
        echo ""
        echo "ERROR: Job failed!"
        echo "Job logs:"
        kubectl logs -n "${NAMESPACE}" -l app=fluss-setup,component=table-creator --tail=50
        exit 1
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        echo "ERROR: Job did not complete within ${TIMEOUT} seconds"
        echo "Job status:"
        kubectl get job -n "${NAMESPACE}" "${JOB_NAME}"
        echo ""
        echo "Job logs:"
        kubectl logs -n "${NAMESPACE}" -l app=fluss-setup,component=table-creator --tail=50
        exit 1
    fi
    
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -n "."
done

echo ""
echo "✓ Job completed successfully!"
echo ""
echo "Job logs:"
kubectl logs -n "${NAMESPACE}" -l app=fluss-setup,component=table-creator --tail=50

echo ""
echo "=== Table Creation Complete ==="
echo "Table '${DATABASE}.${TABLE}' is ready with ${BUCKETS} buckets"
echo "You can now deploy the producer to use this table"

