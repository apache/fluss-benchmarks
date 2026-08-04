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

# Script to check Fluss table bucket count using Fluss Admin API
# Can be run locally (with port-forward) or via kubectl exec

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE="${NAMESPACE:-fluss}"
BOOTSTRAP="${BOOTSTRAP:-coordinator-server-hs.fluss.svc.cluster.local:9124}"
DATABASE="${DATABASE:-iot}"
TABLE="${TABLE:-sensor_readings}"
BUCKETS="${BUCKETS:-128}"
DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo}"
DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"
USE_KUBECTL_EXEC="${USE_KUBECTL_EXEC:-false}"

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
        --kubectl-exec)
            USE_KUBECTL_EXEC="true"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Check Fluss table bucket count using Fluss Admin API"
            echo ""
            echo "Options:"
            echo "  --namespace NAMESPACE     Kubernetes namespace (default: fluss)"
            echo "  --bootstrap BOOTSTRAP     Fluss coordinator address"
            echo "                            Default: coordinator-server-hs.fluss.svc.cluster.local:9124"
            echo "                            Use localhost:9124 if port-forwarding"
            echo "  --database DATABASE       Database name (default: iot)"
            echo "  --table TABLE             Table name (default: sensor_readings)"
            echo "  --buckets BUCKETS         Expected bucket count (default: 128)"
            echo "  --image-repo REPO         Docker image repository (for kubectl exec)"
            echo "  --image-tag TAG           Docker image tag (for kubectl exec)"
            echo "  --kubectl-exec            Run via kubectl exec instead of locally"
            echo "  --help                    Show this help message"
            echo ""
            echo "Examples:"
            echo "  # Check via port-forward (port-forward must be running):"
            echo "  kubectl port-forward -n fluss svc/coordinator-server-hs 9124:9124 &"
            echo "  $0 --bootstrap localhost:9124"
            echo ""
            echo "  # Check via kubectl exec (runs inside cluster):"
            echo "  $0 --kubectl-exec"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "=== Checking Fluss Table Bucket Count ==="
echo "  Bootstrap: ${BOOTSTRAP}"
echo "  Database: ${DATABASE}"
echo "  Table: ${TABLE}"
echo "  Expected buckets: ${BUCKETS}"
echo ""

if [ "${USE_KUBECTL_EXEC}" = "true" ]; then
    # Run via kubectl exec - need to find a pod with the demo jar
    echo "Running check via kubectl exec..."
    
    # Try to find a pod with the demo image
    POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app=fluss-setup,component=table-creator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "${POD_NAME}" ]; then
        # Try producer pod
        POD_NAME=$(kubectl get pods -n "${NAMESPACE}" -l app=fluss-producer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    if [ -z "${POD_NAME}" ]; then
        echo "ERROR: No pod found with demo image. Creating a temporary pod..."
        
        # Create a temporary job to check bucket count
        cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: fluss-check-buckets-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: check-buckets
          image: ${DEMO_IMAGE_REPO}:${DEMO_IMAGE_TAG}
          imagePullPolicy: Always
          command:
            - java
          args:
            - --add-opens=java.base/java.util=ALL-UNNAMED
            - --add-opens=java.base/java.lang=ALL-UNNAMED
            - --add-opens=java.base/java.nio=ALL-UNNAMED
            - --add-opens=java.base/java.time=ALL-UNNAMED
            - -cp
            - /opt/flink/usrlib/fluss-flink-realtime-demo.jar
            - org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussTableBucketChecker
            - ${BOOTSTRAP}
            - ${DATABASE}
            - ${TABLE}
            - ${BUCKETS}
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
EOF
        
        JOB_NAME=$(kubectl get jobs -n "${NAMESPACE}" -l job-name=fluss-check-buckets --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
        
        if [ -z "${JOB_NAME}" ]; then
            echo "ERROR: Failed to create check job"
            exit 1
        fi
        
        echo "Waiting for job to complete..."
        kubectl wait --for=condition=complete --timeout=60s job/${JOB_NAME} -n "${NAMESPACE}" || true
        
        echo ""
        echo "Job logs:"
        kubectl logs -n "${NAMESPACE}" -l job-name=${JOB_NAME} --tail=50
        
        # Cleanup
        kubectl delete job ${JOB_NAME} -n "${NAMESPACE}" --ignore-not-found=true
        
    else
        echo "Using pod: ${POD_NAME}"
        kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- java \
            --add-opens=java.base/java.util=ALL-UNNAMED \
            --add-opens=java.base/java.lang=ALL-UNNAMED \
            --add-opens=java.base/java.nio=ALL-UNNAMED \
            --add-opens=java.base/java.time=ALL-UNNAMED \
            -cp /opt/flink/usrlib/fluss-flink-realtime-demo.jar \
            org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussTableBucketChecker \
            "${BOOTSTRAP}" "${DATABASE}" "${TABLE}" "${BUCKETS}"
    fi
else
    # Run locally - need the demo jar
    DEMO_DIR="${SCRIPT_DIR}/../../../fluss_flink_realtime"
    DEMO_JAR="${DEMO_DIR}/target/fluss-flink-realtime-demo.jar"

    if [ ! -f "${DEMO_JAR}" ]; then
        echo "ERROR: Demo JAR not found at ${DEMO_JAR}"
        echo "Please build it first:"
        echo "  mvn -f ${DEMO_DIR}/pom.xml clean package"
        echo ""
        echo "Or use --kubectl-exec to run inside the cluster"
        exit 1
    fi
    
    echo "Running check locally..."
    java \
        --add-opens=java.base/java.util=ALL-UNNAMED \
        --add-opens=java.base/java.lang=ALL-UNNAMED \
        --add-opens=java.base/java.nio=ALL-UNNAMED \
        --add-opens=java.base/java.time=ALL-UNNAMED \
        -cp "${DEMO_JAR}" \
        org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussTableBucketChecker \
        "${BOOTSTRAP}" "${DATABASE}" "${TABLE}" "${BUCKETS}"
fi


