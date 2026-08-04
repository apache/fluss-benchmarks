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

# Deploy multiple producer instances (8 total, 2 per node across 4 nodes)
# This script deploys 8 producer jobs with instance IDs 0-7
# Topology spread constraints ensure 2 pods run per producer node

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
export NAMESPACE="${NAMESPACE:-fluss}"
export TOTAL_PRODUCERS="${TOTAL_PRODUCERS:-8}"
export PRODUCER_RATE="${PRODUCER_RATE:-250000}"
export PRODUCER_FLUSH_EVERY="${PRODUCER_FLUSH_EVERY:-5000}"
export PRODUCER_STATS_INTERVAL_SECONDS="${PRODUCER_STATS_INTERVAL_SECONDS:-10}"
export CLIENT_WRITER_BATCH_TIMEOUT="${CLIENT_WRITER_BATCH_TIMEOUT:-90ms}"
export CLIENT_WRITER_BUFFER_MEMORY_SIZE="${CLIENT_WRITER_BUFFER_MEMORY_SIZE:-2gb}"
export CLIENT_WRITER_BATCH_SIZE="${CLIENT_WRITER_BATCH_SIZE:-128mb}"
export PRODUCER_MEMORY_REQUEST="${PRODUCER_MEMORY_REQUEST:-4Gi}"
export PRODUCER_MEMORY_LIMIT="${PRODUCER_MEMORY_LIMIT:-16Gi}"
export PRODUCER_CPU_REQUEST="${PRODUCER_CPU_REQUEST:-2000m}"
export PRODUCER_CPU_LIMIT="${PRODUCER_CPU_LIMIT:-8000m}"
export BOOTSTRAP="${BOOTSTRAP:-coordinator-server-hs.fluss.svc.cluster.local:9124}"
export DATABASE="${DATABASE:-iot}"
export TABLE="${TABLE:-sensor_readings}"
export BUCKETS="${BUCKETS:-128}"
export NUM_WRITER_THREADS="${NUM_WRITER_THREADS:-48}"
export DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo}"
export DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"

# Parse command line arguments
WAIT_FOR_READY=false
SHOW_LOGS=false
CLEANUP_EXISTING=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            export NAMESPACE="$2"
            shift 2
            ;;
        --rate)
            export PRODUCER_RATE="$2"
            shift 2
            ;;
        --total-producers)
            export TOTAL_PRODUCERS="$2"
            shift 2
            ;;
        --no-cleanup)
            CLEANUP_EXISTING=false
            shift
            ;;
        --wait)
            WAIT_FOR_READY=true
            shift
            ;;
        --logs)
            SHOW_LOGS=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Deploys ${TOTAL_PRODUCERS} producer instances (2 per node across 4 nodes)"
            echo ""
            echo "Options:"
            echo "  --namespace NAMESPACE          Kubernetes namespace (default: fluss)"
            echo "  --rate RATE                    Records per second per instance (default: 250000)"
            echo "  --total-producers COUNT         Total number of producer instances (default: 8)"
            echo "  --no-cleanup                   Don't delete existing producer jobs before deploying"
            echo "  --wait                         Wait for all pods to be ready"
            echo "  --logs                         Show logs after deployment"
            echo ""
            echo "This script will:"
            echo "  1. Delete existing producer jobs (unless --no-cleanup)"
            echo "  2. Deploy ${TOTAL_PRODUCERS} producer jobs with instance IDs 0-$((TOTAL_PRODUCERS-1))"
            echo "  3. Topology spread constraints ensure 2 pods per producer node"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

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

# Check if producer nodes exist
PRODUCER_NODES=$(kubectl get nodes -l node-type=producer --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${PRODUCER_NODES}" -eq 0 ]; then
    echo "ERROR: No producer nodes found. Please deploy infrastructure first."
    echo "Expected 4 producer nodes with label node-type=producer"
    exit 1
fi

if [ "${PRODUCER_NODES}" -lt 4 ]; then
    echo "WARNING: Found only ${PRODUCER_NODES} producer nodes, expected 4"
    echo "Topology spread may not work as expected"
fi

echo "=== Deploying ${TOTAL_PRODUCERS} Producer Instances ==="
echo "Namespace: ${NAMESPACE}"
echo "Producer Nodes Available: ${PRODUCER_NODES}"
echo "Image: ${DEMO_IMAGE_REPO}:${DEMO_IMAGE_TAG}"
echo "Rate per instance: ${PRODUCER_RATE} records/sec"
echo "Total rate: $((PRODUCER_RATE * TOTAL_PRODUCERS)) records/sec"
echo "Instances: 0-$((TOTAL_PRODUCERS-1))"
echo ""

# Cleanup existing producer jobs
if [ "${CLEANUP_EXISTING}" = true ]; then
    echo "[1/3] Cleaning up existing producer jobs..."
    EXISTING_JOBS=$(kubectl get jobs -n "${NAMESPACE}" -l app=fluss-producer -o name 2>/dev/null || echo "")
    if [ -n "${EXISTING_JOBS}" ]; then
        echo "${EXISTING_JOBS}" | xargs -r kubectl delete -n "${NAMESPACE}"
        echo "  ✓ Existing jobs deleted"
        sleep 3
    else
        echo "  ℹ No existing jobs found"
    fi
    echo ""
fi

# Deploy producer jobs
echo "[2/3] Deploying ${TOTAL_PRODUCERS} producer jobs..."
for INSTANCE_ID in $(seq 0 $((TOTAL_PRODUCERS-1))); do
    export INSTANCE_ID="${INSTANCE_ID}"
    JOB_NAME="fluss-producer-${INSTANCE_ID}"
    
    echo "  Deploying instance ${INSTANCE_ID} (job: ${JOB_NAME})..."
    
    # Create job YAML with instance-specific name
    envsubst < "${SCRIPT_DIR}/producer-job.yaml" | \
        sed "s/name: fluss-producer/name: ${JOB_NAME}/" | \
        kubectl apply -f - > /dev/null
    
    if [ $? -eq 0 ]; then
        echo "    ✓ Instance ${INSTANCE_ID} deployed"
    else
        echo "    ✗ Failed to deploy instance ${INSTANCE_ID}"
        exit 1
    fi
done
echo ""

# Wait for pods to be ready if requested
if [ "${WAIT_FOR_READY}" = true ]; then
    echo "[3/3] Waiting for producer pods to be ready..."
    TIMEOUT=600
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        READY_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
        TOTAL_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer --no-headers 2>/dev/null | wc -l | tr -d ' ')
        
        if [ "${READY_PODS}" -eq "${TOTAL_PRODUCERS}" ] && [ "${TOTAL_PODS}" -eq "${TOTAL_PRODUCERS}" ]; then
            echo "  ✓ All ${TOTAL_PRODUCERS} producer pods are ready"
            break
        fi
        
        echo "  Waiting... (${READY_PODS}/${TOTAL_PRODUCERS} pods ready)"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "  ⚠ Timeout waiting for all pods to be ready"
        echo "  Check status: kubectl get pods -n ${NAMESPACE} -l app=fluss-producer"
    fi
    echo ""
fi

# Show deployment status
echo "=== Deployment Status ==="
echo ""
echo "Producer Jobs:"
kubectl get jobs -n "${NAMESPACE}" -l app=fluss-producer
echo ""
echo "Producer Pods:"
kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer -o wide
echo ""

# Show pod distribution across nodes
echo "Pod Distribution Across Nodes:"
kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' | \
    sort -k2 | \
    awk '{nodes[$2]++} END {for (node in nodes) print "  " node ": " nodes[node] " pod(s)"}'
echo ""

# Show logs if requested
if [ "${SHOW_LOGS}" = true ]; then
    echo "=== Producer Logs (last 20 lines per instance) ==="
    for INSTANCE_ID in $(seq 0 $((TOTAL_PRODUCERS-1))); do
        POD=$(kubectl get pod -n "${NAMESPACE}" -l app=fluss-producer --field-selector=status.phase=Running -o jsonpath="{.items[?(@.metadata.labels['job-name']=='fluss-producer-${INSTANCE_ID}')].metadata.name}" 2>/dev/null || echo "")
        if [ -n "${POD}" ]; then
            echo "--- Instance ${INSTANCE_ID} (${POD}) ---"
            kubectl logs -n "${NAMESPACE}" "${POD}" --tail=20 2>/dev/null || echo "  Could not retrieve logs"
            echo ""
        fi
    done
fi

echo "=== Deployment Complete ==="
echo ""
echo "Monitor producers:"
echo "  kubectl get pods -n ${NAMESPACE} -l app=fluss-producer -o wide"
echo "  kubectl logs -n ${NAMESPACE} -l app=fluss-producer -f"
echo ""
echo "Check pod distribution:"
echo "  kubectl get pods -n ${NAMESPACE} -l app=fluss-producer -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.nodeName}{\"\\n\"}{end}' | sort -k2"
echo ""
echo "Delete all producer jobs:"
echo "  kubectl delete jobs -n ${NAMESPACE} -l app=fluss-producer"
echo ""

