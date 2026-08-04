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

# Deployment script for Kubernetes resources
# Usage: ./deploy.sh [namespace] [demo-image-repo] [demo-image-tag] [fluss-image-repo]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}"

NAMESPACE="${1:-${NAMESPACE:-fluss}}"
DEMO_IMAGE_REPO="${2:-${DEMO_IMAGE_REPO:-}}"
DEMO_IMAGE_TAG="${3:-${DEMO_IMAGE_TAG:-latest}}"
FLUSS_IMAGE_REPO="${4:-${FLUSS_IMAGE_REPO:-}}"

if [ -z "${FLUSS_VERSION:-}" ]; then
    echo "ERROR: FLUSS_VERSION is not set."
    echo "  source e2e-iot/default.env.sh --fluss-version 0.9.0-incubating"
    exit 1
fi

if [ -z "${DEMO_IMAGE_REPO}" ]; then
    echo "ERROR: DEMO_IMAGE_REPO is not set."
    echo "  source e2e-iot/default.env.sh --fluss-version ${FLUSS_VERSION}"
    exit 1
fi

if [ -z "${FLUSS_IMAGE_REPO}" ]; then
    echo "ERROR: FLUSS_IMAGE_REPO is not set."
    echo "  source e2e-iot/default.env.sh --fluss-version ${FLUSS_VERSION}"
    exit 1
fi

FLUSS_IMAGE_TAG="${FLUSS_IMAGE_TAG:-${FLUSS_VERSION}}"

# Export variables for envsubst
export NAMESPACE
export DEMO_IMAGE_REPO
export DEMO_IMAGE_TAG

echo "=== Deploying Kubernetes Resources ==="
echo "Namespace: ${NAMESPACE}"
echo "Demo Image: ${DEMO_IMAGE_REPO}:${DEMO_IMAGE_TAG}"
echo "Fluss Image: ${FLUSS_IMAGE_REPO}"
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check helm is available (for Fluss and monitoring)
if ! command -v helm &> /dev/null; then
    echo "ERROR: helm is not installed or not in PATH"
    exit 1
fi

# 1. Create namespace
echo "[1/8] Creating namespace..."
kubectl apply -f "${K8S_DIR}/namespace/namespace.yaml"

# 2. Deploy ZooKeeper
echo "[2/8] Deploying ZooKeeper..."
kubectl apply -f "${K8S_DIR}/zookeeper/zookeeper.yaml"

# Wait for ZooKeeper to be ready
echo "Waiting for ZooKeeper to be ready..."
kubectl wait --for=condition=ready pod -l app=zookeeper -n ${NAMESPACE} --timeout=120s || true

# StatefulSet volumeClaimTemplates are immutable. If Fluss was first installed without
# persistence, helm upgrade cannot add PVCs — recreate the StatefulSets before Helm.
ensure_fluss_persistence_sts() {
    local sts_name=$1
    local pvc_prefix=$2

    if ! kubectl get sts "${sts_name}" -n "${NAMESPACE}" &>/dev/null; then
        return 0
    fi

    local vct_name replicas pvc_count
    vct_name=$(kubectl get sts "${sts_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true)
    replicas=$(kubectl get sts "${sts_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    pvc_count=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -c "${pvc_prefix}" || true)

    if [ -z "${vct_name}" ]; then
        echo "  ${sts_name}: no volumeClaimTemplates — recreating to enable NVMe persistence"
        kubectl delete sts "${sts_name}" -n "${NAMESPACE}" --cascade=orphan --wait=true
    elif [ "${pvc_count}" -lt "${replicas}" ]; then
        echo "  ${sts_name}: ${pvc_count}/${replicas} PVCs found — recreating so PVCs bind to PVs"
        kubectl delete sts "${sts_name}" -n "${NAMESPACE}" --cascade=orphan --wait=true
    fi
}

# 3. Deploy Fluss via Helm
echo "[3/8] Deploying Fluss via Helm..."
FLUSS_CHART_VERSION="${FLUSS_CHART_VERSION:-${FLUSS_VERSION}}"
# The published chart at downloads.apache.org (0.9.0-incubating) ignores persistence.enabled
# and always uses emptyDir. Use a chart with volumeClaimTemplates (vendored or fluss repo helm/).
if [ -z "${FLUSS_CHART_PATH:-}" ]; then
    if [ -f "${SCRIPT_DIR}/../helm-charts/fluss/Chart.yaml" ]; then
        FLUSS_CHART_PATH="${SCRIPT_DIR}/../helm-charts/fluss"
    elif [ -f "${SCRIPT_DIR}/../../../../helm/Chart.yaml" ]; then
        FLUSS_CHART_PATH="${SCRIPT_DIR}/../../../../helm"
    fi
fi
if [ -z "${FLUSS_CHART_PATH:-}" ] || [ ! -f "${FLUSS_CHART_PATH}/Chart.yaml" ]; then
    echo "ERROR: Fluss Helm chart with persistence support not found."
    echo "  Set FLUSS_CHART_PATH or place chart at high-infra/helm-charts/fluss (benchmarks repo)"
    echo "  or use apache/fluss checkout with helm/ (fluss main repo)."
    exit 1
fi
echo "Using Fluss Helm chart: ${FLUSS_CHART_PATH}"

echo "Ensuring Fluss StatefulSets can use NVMe persistence..."
ensure_fluss_persistence_sts "tablet-server" "data-tablet-server"
kubectl delete pod -n "${NAMESPACE}" -l 'app.kubernetes.io/component=tablet' --ignore-not-found --wait=false 2>/dev/null || true

FLUSS_HELM_SET=(
    --set persistence.enabled=true
    --set persistence.coordinatorEnabled=false
    --set persistence.storageClass=local-storage
    --set persistence.size=500Gi
    --set configurationOverrides."zookeeper\.address"="zk-svc.${NAMESPACE}.svc.cluster.local:2181"
    --set configurationOverrides."metrics\.reporters"="prometheus"
    --set configurationOverrides."metrics\.reporter\.prometheus\.port"="9249"
)

if [ -n "${FLUSS_IMAGE_REPO}" ]; then
    # Extract registry, repository, and tag from image
    if [[ "${FLUSS_IMAGE_REPO}" == *".dkr.ecr."* ]]; then
        # ECR format: <account>.dkr.ecr.<region>.amazonaws.com/<repo> or <account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>
        if [[ "${FLUSS_IMAGE_REPO}" == *":"* ]]; then
            # Has tag
            FLUSS_REPO_WITHOUT_TAG="${FLUSS_IMAGE_REPO%%:*}"
            FLUSS_TAG="${FLUSS_IMAGE_REPO##*:}"
        else
            # No tag — use FLUSS_IMAGE_TAG (must match push-images-to-ecr.sh)
            FLUSS_REPO_WITHOUT_TAG="${FLUSS_IMAGE_REPO}"
            FLUSS_TAG="${FLUSS_IMAGE_TAG}"
        fi
        # For ECR, registry is empty and repository is the full ECR URL without tag
        FLUSS_REGISTRY=""
        FLUSS_REPO="${FLUSS_REPO_WITHOUT_TAG}"
    else
        # Docker Hub format: <repo>:<tag> or <registry>/<repo>:<tag>
        if [[ "${FLUSS_IMAGE_REPO}" == *":"* ]]; then
            FLUSS_REPO="${FLUSS_IMAGE_REPO%%:*}"
            FLUSS_TAG="${FLUSS_IMAGE_REPO##*:}"
        else
            FLUSS_REPO="${FLUSS_IMAGE_REPO}"
            FLUSS_TAG="${FLUSS_IMAGE_TAG}"
        fi
        FLUSS_REGISTRY="docker.io"
    fi
    
    helm upgrade --install fluss "${FLUSS_CHART_PATH}" \
        --namespace ${NAMESPACE} \
        --set image.registry="${FLUSS_REGISTRY}" \
        --set image.repository="${FLUSS_REPO}" \
        --set image.tag="${FLUSS_TAG}" \
        "${FLUSS_HELM_SET[@]}" \
        --wait=false
else
    helm upgrade --install fluss "${FLUSS_CHART_PATH}" \
        --namespace ${NAMESPACE} \
        "${FLUSS_HELM_SET[@]}" \
        --wait=false
fi

echo "Waiting for Fluss PVCs to bind to local NVMe PVs..."
TABLET_REPLICAS=$(kubectl get sts tablet-server -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
for i in $(seq 0 $((TABLET_REPLICAS - 1))); do
    kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/data-tablet-server-${i}" -n "${NAMESPACE}" --timeout=180s || {
        echo "WARNING: PVC data-tablet-server-${i} not bound — run 04-verify-storage.sh for details"
    }
done

# 4. Deploy Flink cluster
echo "[4/8] Deploying Flink cluster..."
# Flink image is hardcoded to apache/flink:1.20.3-scala_2.12-java17
# Use envsubst for namespace and DEMO_IMAGE_REPO/DEMO_IMAGE_TAG (for init container)
# Create Flink service account first
envsubst < "${K8S_DIR}/flink/flink-serviceaccount.yaml" | kubectl apply -f -
# Apply ConfigMap with namespace substitution
envsubst < "${K8S_DIR}/flink/flink-config.yaml" | kubectl apply -f -
# Apply JobManager and TaskManager (namespace and DEMO_IMAGE_REPO/DEMO_IMAGE_TAG for init container)
envsubst < "${K8S_DIR}/flink/flink-jobmanager.yaml" | kubectl apply -f -
envsubst < "${K8S_DIR}/flink/flink-taskmanager.yaml" | kubectl apply -f -

# 4.1. Update Flink ConfigMap with S3 checkpoint configuration
echo "[4.1/9] Updating Flink ConfigMap with S3 checkpoint configuration..."
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
CLUSTER_NAME="fluss-eks-cluster"

if command -v terraform &> /dev/null && [ -d "${TERRAFORM_DIR}" ]; then
    cd "${TERRAFORM_DIR}"
    S3_BUCKET=$(terraform output -raw flink_s3_bucket_name 2>/dev/null || echo "")
    cd - > /dev/null
    
    if [ -n "$S3_BUCKET" ]; then
        echo "  S3 Bucket: $S3_BUCKET"
        
        # Get current ConfigMap
        CURRENT_CONFIG=$(kubectl get configmap flink-config -n "${NAMESPACE}" -o jsonpath='{.data.flink-conf\.yaml}' 2>/dev/null || echo "")
        
        if [ -n "$CURRENT_CONFIG" ]; then
            # Replace placeholder with actual bucket name (using s3:// as in reference)
            UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | \
                sed "s|s3://fluss-eks-cluster-flink-state-PLACEHOLDER/flink-checkpoints/fluss-eks-cluster/|s3://${S3_BUCKET}/flink-checkpoints/${CLUSTER_NAME}/|g" | \
                sed "s|s3://fluss-eks-cluster-flink-state-PLACEHOLDER/flink-savepoints/fluss-eks-cluster/|s3://${S3_BUCKET}/flink-savepoints/${CLUSTER_NAME}/|g" | \
                sed "s|s3a://fluss-eks-cluster-flink-state-PLACEHOLDER/flink-checkpoints/fluss-eks-cluster/|s3://${S3_BUCKET}/flink-checkpoints/${CLUSTER_NAME}/|g" | \
                sed "s|s3a://fluss-eks-cluster-flink-state-PLACEHOLDER/flink-savepoints/fluss-eks-cluster/|s3://${S3_BUCKET}/flink-savepoints/${CLUSTER_NAME}/|g")
            
            # Update ConfigMap
            if command -v jq &> /dev/null; then
                kubectl patch configmap flink-config -n "${NAMESPACE}" \
                    --type merge \
                    -p "{\"data\":{\"flink-conf.yaml\":$(echo "$UPDATED_CONFIG" | jq -Rs .)}}" 2>/dev/null && \
                echo "  ✓ ConfigMap updated with S3 checkpoint paths"
            else
                echo "  ⚠ jq not found, skipping S3 ConfigMap update (will use placeholder)"
            fi
        else
            echo "  ⚠ ConfigMap not found yet, will be updated when Flink pods are ready"
        fi
    else
        echo "  ⚠ S3 bucket not found in Terraform outputs, skipping S3 configuration"
    fi
else
    echo "  ⚠ Terraform not found or directory missing, skipping S3 configuration update"
fi

# 5. Deploy monitoring (Prometheus/Grafana)
echo "[5/8] Deploying monitoring stack..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --version 55.5.0 \
    --namespace monitoring \
    --set prometheus.prometheusSpec.retention=30d \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set grafana.enabled=true \
    --set grafana.adminUser=admin \
    --set grafana.adminPassword=admin123 \
    --set grafana.service.type=LoadBalancer \
    --set alertmanager.enabled=false \
    --wait=false

# 6. Deploy ServiceMonitors and PodMonitors for Prometheus
echo "[6/8] Deploying ServiceMonitors and PodMonitors for Prometheus..."
if [ -f "${K8S_DIR}/monitoring/servicemonitors.yaml" ]; then
kubectl apply -f "${K8S_DIR}/monitoring/servicemonitors.yaml"
    echo "  ✓ ServiceMonitors deployed"
else
    echo "  WARNING: servicemonitors.yaml not found, skipping..."
fi
if [ -f "${K8S_DIR}/monitoring/podmonitors.yaml" ]; then
kubectl apply -f "${K8S_DIR}/monitoring/podmonitors.yaml"
    echo "  ✓ PodMonitors deployed"
else
    echo "  WARNING: podmonitors.yaml not found, skipping..."
fi

# 7. Deploy Grafana dashboard (if exists)
echo "[7/8] Deploying Grafana dashboard..."
if [ -f "${K8S_DIR}/monitoring/grafana-dashboard.yaml" ]; then
    kubectl apply -f "${K8S_DIR}/monitoring/grafana-dashboard.yaml"
    echo "  ✓ Grafana dashboard ConfigMap deployed"
    
    # Import dashboard via Grafana API to ensure it's visible
    echo "  Importing dashboard via Grafana API..."
    GRAFANA_USER="${GRAFANA_USER:-admin}"
    GRAFANA_PASS="${GRAFANA_PASS:-admin123}"
    GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "${GRAFANA_POD}" ]; then
        # Wait a moment for Grafana to be ready
        sleep 5
        
        # Extract dashboard JSON from ConfigMap
        DASHBOARD_JSON_CONTENT=$(kubectl get configmap -n monitoring fluss-flink-dashboard -o jsonpath='{.data.fluss-flink-dashboard\.json}' 2>/dev/null || echo "")
        
        if [ -n "${DASHBOARD_JSON_CONTENT}" ]; then
            # Prepare dashboard payload (ensure overwrite is set)
            if command -v jq &> /dev/null; then
                DASHBOARD_PAYLOAD=$(echo "${DASHBOARD_JSON_CONTENT}" | jq '. + {overwrite: true}' 2>/dev/null || echo "${DASHBOARD_JSON_CONTENT}")
            else
                DASHBOARD_PAYLOAD="${DASHBOARD_JSON_CONTENT}"
            fi
            
            # Import via Grafana API
            IMPORT_RESPONSE=$(kubectl exec -n monitoring "${GRAFANA_POD}" -c grafana -- curl -s -X POST \
                "http://localhost:3000/api/dashboards/db" \
                -H "Content-Type: application/json" \
                -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
                -d "${DASHBOARD_PAYLOAD}" 2>/dev/null || echo "")
            
            if echo "${IMPORT_RESPONSE}" | grep -q '"status":"success"'; then
                echo "  Dashboard imported successfully via Grafana API"
            else
                echo "  WARNING: Dashboard import via API failed; may need manual import"
                echo "  Dashboard ConfigMap is deployed; Grafana should auto-discover it"
            fi
        else
            echo "  ⚠ Could not extract dashboard JSON from ConfigMap"
        fi
    else
        echo "  ⚠ Grafana pod not found, skipping API import"
        echo "  Dashboard ConfigMap is deployed, Grafana should auto-discover it"
    fi
else
    echo "  No Grafana dashboard YAML found, skipping..."
fi

# 8. Quick readiness check (03-deploy-components.sh performs full waits)
echo "[8/8] Checking component status..."
wait_for_pods() {
    local label="$1"
    local description="$2"
    local timeout="${3:-60s}"
    echo "  Waiting for ${description}..."
    # Ignore SIGINT during kubectl wait so Ctrl+C does not abort the script with a spurious error
    trap 'echo "  Interrupted while waiting for '"${description}"'; continuing..."; return 0' INT
    kubectl wait --for=condition=ready pod -l "${label}" -n "${NAMESPACE}" --timeout="${timeout}" 2>/dev/null || {
        echo "  WARNING: ${description} not ready yet; check with: kubectl get pods -n ${NAMESPACE} -l ${label}"
    }
    trap - INT
}
wait_for_pods "app=flink,component=jobmanager" "Flink JobManager" "60s"
wait_for_pods "app=flink,component=taskmanager" "Flink TaskManagers" "60s"

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Check status:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get pods -n monitoring"
echo ""
echo "Check Flink cluster:"
echo "  kubectl get pods -n ${NAMESPACE} -l app=flink"
echo "  kubectl get nodes -l flink-component"
echo ""
echo "Check monitoring:"
echo "  kubectl get servicemonitor -n ${NAMESPACE}"
echo "  kubectl get podmonitor -n ${NAMESPACE}"
echo ""
echo "Access Flink Web UI:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
echo "  Then open: http://localhost:8081"
echo ""
echo "Access Grafana:"
echo "  GRAFANA_SVC=\$(kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl port-forward -n monitoring svc/\$GRAFANA_SVC 3000:80"
echo "  Then open: http://localhost:3000"
echo "  Username: admin"
echo "  Password: admin123"
echo ""
echo "Access Prometheus:"
echo "  PROM_SVC=\$(kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl port-forward -n monitoring svc/\$PROM_SVC 9090:9090"
echo "  Then open: http://localhost:9090"
echo ""
echo "Submit Flink aggregator job manually:"
echo "  cd ${K8S_DIR}/flink && ./submit-job-local.sh"

