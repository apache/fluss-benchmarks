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

# Deploy producer with optimal performance configuration
# This script uses the optimal settings discovered through performance testing:
# - Batch timeout: 90ms (or 50ms) for optimal throughput
# - Flush interval: 5000 records (balances latency vs throughput)
# - Rate: 200000 records/sec
# - Buffer: 2gb, Batch: 128mb

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optimal performance configuration
export NAMESPACE="${NAMESPACE:-fluss}"
export PRODUCER_RATE="${PRODUCER_RATE:-200000}"
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
export BUCKETS="${BUCKETS:-48}"
export TOTAL_PRODUCERS="${TOTAL_PRODUCERS:-1}"
export INSTANCE_ID="${INSTANCE_ID:-0}"
export NUM_WRITER_THREADS="${NUM_WRITER_THREADS:-48}"
export DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo}"
export DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"

# Parse command line arguments for overrides
WAIT_FOR_READY=false
SHOW_LOGS=false

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
        --flush)
            export PRODUCER_FLUSH_EVERY="$2"
            shift 2
            ;;
        --batch-timeout)
            export CLIENT_WRITER_BATCH_TIMEOUT="$2"
            shift 2
            ;;
        --buffer-size)
            export CLIENT_WRITER_BUFFER_MEMORY_SIZE="$2"
            shift 2
            ;;
        --batch-size)
            export CLIENT_WRITER_BATCH_SIZE="$2"
            shift 2
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
            echo "Deploys producer with optimal performance configuration:"
            echo "  Rate: 200,000 records/sec"
            echo "  Flush: every 5,000 records"
            echo "  Batch timeout: 90ms"
            echo "  Buffer: 2gb, Batch: 128mb"
            echo ""
            echo "Options:"
            echo "  --namespace NAMESPACE          Kubernetes namespace (default: fluss)"
            echo "  --rate RATE                    Records per second (default: 200000)"
            echo "  --flush FLUSH                  Flush every N records (default: 5000)"
            echo "  --batch-timeout TIMEOUT         Batch timeout (default: 90ms)"
            echo "  --buffer-size SIZE             Writer buffer memory size (default: 2gb)"
            echo "  --batch-size SIZE              Writer batch size (default: 128mb)"
            echo "  --wait                         Wait for job to be ready"
            echo "  --logs                         Show logs after deployment"
            echo ""
            echo "Environment variables can also be used to override defaults."
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

echo "=== Deploying Producer with Optimal Configuration ==="
echo "Namespace: ${NAMESPACE}"
echo "Image: ${DEMO_IMAGE_REPO}:${DEMO_IMAGE_TAG}"
echo "Rate: ${PRODUCER_RATE} records/sec"
echo "Flush: every ${PRODUCER_FLUSH_EVERY} records"
echo "Batch Timeout: ${CLIENT_WRITER_BATCH_TIMEOUT}"
echo "Buffer Size: ${CLIENT_WRITER_BUFFER_MEMORY_SIZE}"
echo "Batch Size: ${CLIENT_WRITER_BATCH_SIZE}"
echo "Memory: ${PRODUCER_MEMORY_REQUEST} request, ${PRODUCER_MEMORY_LIMIT} limit"
echo "CPU: ${PRODUCER_CPU_REQUEST} request, ${PRODUCER_CPU_LIMIT} limit"
echo "Bootstrap: ${BOOTSTRAP}"
echo "Database: ${DATABASE}"
echo "Table: ${TABLE}"
echo "Buckets: ${BUCKETS}"
echo "Writer Threads: ${NUM_WRITER_THREADS}"
echo ""

# Always delete existing job before deploying
echo "[1/4] Deleting existing producer job (if any)..."
EXISTING_JOB=$(kubectl get job -n "${NAMESPACE}" fluss-producer -o name 2>/dev/null || echo "")
if [ -n "${EXISTING_JOB}" ]; then
    kubectl delete job -n "${NAMESPACE}" fluss-producer
    echo "  ✓ Existing job deleted"
    sleep 2
else
    echo "  ℹ No existing job found"
fi
echo ""

# Deploy producer job
echo "[2/4] Deploying producer job..."
# Use envsubst to substitute variables in the YAML
envsubst < "${SCRIPT_DIR}/producer-job.yaml" | kubectl apply -f -

echo "  ✓ Producer job deployed"
echo ""

# Wait for job to be ready if requested
if [ "${WAIT_FOR_READY}" = true ]; then
    echo "[3/4] Waiting for producer pod to be ready..."
    if kubectl wait --for=condition=ready pod -l app=fluss-producer -n "${NAMESPACE}" --timeout=300s 2>/dev/null; then
        echo "  ✓ Producer pod is ready"
    else
        echo "  ⚠ Timeout waiting for producer pod to be ready"
        echo "  Check status: kubectl get pods -n ${NAMESPACE} -l app=fluss-producer"
    fi
    echo ""
fi

# Show job status
echo "[4/4] Producer job status:"
kubectl get job -n "${NAMESPACE}" fluss-producer
echo ""
kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer
echo ""

# Show logs if requested
if [ "${SHOW_LOGS}" = true ]; then
    PRODUCER_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=fluss-producer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${PRODUCER_POD}" ]; then
        echo "=== Producer Logs (last 50 lines) ==="
        kubectl logs -n "${NAMESPACE}" "${PRODUCER_POD}" --tail=50 || echo "  Could not retrieve logs"
        echo ""
    fi
fi

echo "=== Deployment Complete ==="
echo ""
echo "Monitor producer:"
echo "  kubectl get pods -n ${NAMESPACE} -l app=fluss-producer"
echo "  kubectl logs -n ${NAMESPACE} -l app=fluss-producer -f"
echo ""
echo "View producer metrics:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/fluss-producer-metrics 8080:8080"
echo "  Then open: http://localhost:8080/metrics"
echo ""
echo "Delete producer job:"
echo "  kubectl delete job -n ${NAMESPACE} fluss-producer"
echo ""


