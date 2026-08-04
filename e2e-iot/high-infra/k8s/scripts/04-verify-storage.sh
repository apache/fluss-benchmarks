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
VERIFICATION_FAILED=0

echo "=== Step 4: Verifying NVMe storage for tablet servers ==="
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Verify PersistentVolumes are using NVMe
echo "Checking PersistentVolumes..."
PV_COUNT=$(kubectl get pv -l component=tablet-server --no-headers 2>/dev/null | wc -l | awk '{print $1}')
if [ "${PV_COUNT}" -eq "0" ]; then
    echo "ERROR: No PersistentVolumes found for tablet servers"
    echo "  Run: cd ${K8S_DIR}/storage && ./setup-local-storage.sh"
    exit 1
fi

echo "✓ Found ${PV_COUNT} PersistentVolumes for tablet servers"
kubectl get pv -l component=tablet-server

# Check PV details for NVMe path
echo ""
echo "Verifying PV paths (should show /opt/alldata/fluss/data)..."
NVME_PVS=$(kubectl get pv -l component=tablet-server -o jsonpath='{.items[*].spec.local.path}' 2>/dev/null || echo "")
if echo "${NVME_PVS}" | grep -q "/opt/alldata/fluss/data"; then
    echo "✓ PVs are configured with NVMe paths"
else
    echo "ERROR: PV paths are not /opt/alldata/fluss/data"
    kubectl get pv -l component=tablet-server -o yaml | grep -A 5 "path:" || true
    VERIFICATION_FAILED=1
fi

# Verify Fluss StatefulSet requests persistent storage
echo ""
echo "Checking Fluss tablet StatefulSet persistence..."
if kubectl get sts tablet-server -n "${NAMESPACE}" &>/dev/null; then
    VCT_COUNT=$(kubectl get sts tablet-server -n "${NAMESPACE}" -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    VCT_COUNT="${VCT_COUNT:-0}"
    if [ "${VCT_COUNT}" -eq "0" ]; then
        echo "ERROR: tablet-server StatefulSet has no volumeClaimTemplates (persistence not enabled)"
        echo "  Redeploy Fluss: kubectl delete sts tablet-server -n ${NAMESPACE} --cascade=orphan"
        echo "  Then re-run: ${K8S_DIR}/deploy.sh ${NAMESPACE} \"\${DEMO_IMAGE_REPO}\" \"\${DEMO_IMAGE_TAG}\" \"\${FLUSS_IMAGE_REPO}\""
        VERIFICATION_FAILED=1
    else
        echo "✓ tablet-server StatefulSet has volumeClaimTemplates"
    fi
else
    echo "ERROR: tablet-server StatefulSet not found in namespace ${NAMESPACE}"
    VERIFICATION_FAILED=1
fi

# Verify PVCs are bound
echo ""
echo "Checking PersistentVolumeClaims..."
TABLET_REPLICAS=$(kubectl get sts tablet-server -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
EXPECTED_PVC_COUNT="${TABLET_REPLICAS}"  # tablet NVMe PVCs only (coordinator uses emptyDir)
PVC_COUNT=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | awk '{print $1}')
if [ "${PVC_COUNT}" -eq "0" ]; then
    echo "ERROR: No PersistentVolumeClaims found in namespace ${NAMESPACE}"
    echo "  PVs stay Available until Fluss creates PVCs (data-tablet-server-0, etc.)."
    echo "  Cause: StatefulSet volumeClaimTemplates are immutable — if Fluss was first"
    echo "  deployed without persistence, helm upgrade cannot add PVCs."
    echo "  Fix: re-run step 3 (deploy.sh recreates StatefulSets automatically) or:"
    echo "    kubectl delete sts tablet-server coordinator-server -n ${NAMESPACE} --cascade=orphan"
    echo "    ${K8S_DIR}/deploy.sh ${NAMESPACE} \"\${DEMO_IMAGE_REPO}\" \"\${DEMO_IMAGE_TAG}\" \"\${FLUSS_IMAGE_REPO}\""
    VERIFICATION_FAILED=1
else
    echo "✓ Found ${PVC_COUNT} PersistentVolumeClaims"
    kubectl get pvc -n "${NAMESPACE}"

    BOUND_COUNT=$(kubectl get pvc -n "${NAMESPACE}" -o jsonpath='{.items[?(@.status.phase=="Bound")].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    if [ "${BOUND_COUNT}" -lt "${EXPECTED_PVC_COUNT}" ]; then
        echo "ERROR: Not all PVCs are bound (${BOUND_COUNT}/${EXPECTED_PVC_COUNT} expected)"
        kubectl get pvc -n "${NAMESPACE}"
        VERIFICATION_FAILED=1
    else
        echo "✓ All PVCs are bound"
    fi
fi

# Verify tablet server pods have volumes mounted
echo ""
echo "Checking tablet server pods..."
TABLET_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=tablet -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -z "${TABLET_PODS}" ]; then
    TABLET_PODS=$(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[?(@.metadata.name=~"tablet-server.*")].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "${TABLET_PODS}" ]; then
    echo "ERROR: No tablet server pods found"
    kubectl get pods -n "${NAMESPACE}" | grep -E "NAME|tablet" || kubectl get pods -n "${NAMESPACE}"
    VERIFICATION_FAILED=1
else
    echo "✓ Found tablet server pods:"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=tablet -o wide 2>/dev/null || \
    kubectl get pods -n "${NAMESPACE}" -o wide | grep tablet-server

    NOT_READY=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=tablet --no-headers 2>/dev/null | grep -vc "Running" || true)
    if [ "${NOT_READY}" -gt "0" ]; then
        echo "ERROR: Some tablet server pods are not Running (check ImagePullBackOff — push images with push-images-to-ecr.sh)"
        kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=tablet | grep -v "Running" || true
        VERIFICATION_FAILED=1
    fi

    FIRST_POD=$(echo "${TABLET_PODS}" | awk '{print $1}')
    if [ -n "${FIRST_POD}" ]; then
        echo ""
        echo "Checking volume mounts in pod ${FIRST_POD}..."
        # Fluss Helm chart mounts the PV at /tmp/fluss/data (data.dir), not /opt/alldata
        PVC_CLAIM=$(kubectl get pod "${FIRST_POD}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}' 2>/dev/null || true)
        if kubectl exec -n "${NAMESPACE}" "${FIRST_POD}" -- test -d /tmp/fluss/data 2>/dev/null; then
            MOUNT_INFO=$(kubectl exec -n "${NAMESPACE}" "${FIRST_POD}" -- df -h /tmp/fluss/data 2>/dev/null || echo "")
            MOUNT_SIZE=$(echo "${MOUNT_INFO}" | tail -1 | awk '{print $2}')
            if [ -n "${PVC_CLAIM}" ]; then
                echo "✓ Persistent data volume is mounted at /tmp/fluss/data (PVC: ${PVC_CLAIM})"
                echo "${MOUNT_INFO}"
            elif kubectl exec -n "${NAMESPACE}" "${FIRST_POD}" -- mount 2>/dev/null | grep -q "/tmp/fluss/data"; then
                echo "ERROR: /tmp/fluss/data is mounted but not from a PVC (likely emptyDir on root disk: ${MOUNT_SIZE})"
                echo "  The published Apache chart 0.9.0-incubating ignores persistence.enabled."
                echo "  Re-run deploy.sh (uses repo helm/ chart with volumeClaimTemplates support)."
                echo "${MOUNT_INFO}"
                VERIFICATION_FAILED=1
            else
                echo "ERROR: /tmp/fluss/data exists but is emptyDir (not bound to NVMe PV)"
                echo "  Check: kubectl get pvc -n ${NAMESPACE} && kubectl describe pod ${FIRST_POD} -n ${NAMESPACE} | grep -A10 Volumes"
                VERIFICATION_FAILED=1
            fi
        else
            echo "ERROR: /tmp/fluss/data not found in pod"
            VERIFICATION_FAILED=1
        fi
    fi
fi

echo ""
if [ "${VERIFICATION_FAILED}" -eq "0" ]; then
    echo "✓ Step 4 completed: NVMe storage verification passed"
else
    echo "✗ Step 4 FAILED: NVMe storage verification failed — fix issues above before continuing"
    exit 1
fi
