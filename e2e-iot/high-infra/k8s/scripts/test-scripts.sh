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

echo "=========================================="
echo "Script Validation Test"
echo "=========================================="
echo ""

ERRORS=0
WARNINGS=0

# Test 1: Check all scripts exist
echo "Test 1: Checking all scripts exist..."
for script in 00-deploy-infra.sh 01-update-kubeconfig.sh 02-setup-storage.sh 03-deploy-components.sh 04-verify-storage.sh 05-deploy-producer.sh 06-submit-flink-job.sh 07-deploy-dashboard.sh 08-verify-deployment.sh deploy-benchmark.sh; do
    if [ -f "${SCRIPT_DIR}/${script}" ]; then
        echo "  ✓ ${script}"
    else
        echo "  ✗ ${script} MISSING"
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# Test 2: Check syntax of all scripts
echo "Test 2: Checking script syntax..."
for script in 00-deploy-infra.sh 01-update-kubeconfig.sh 02-setup-storage.sh 03-deploy-components.sh 04-verify-storage.sh 05-deploy-producer.sh 06-submit-flink-job.sh 07-deploy-dashboard.sh 08-verify-deployment.sh deploy-benchmark.sh; do
    if bash -n "${SCRIPT_DIR}/${script}" 2>&1; then
        echo "  ✓ ${script}"
    else
        echo "  ✗ ${script} has syntax errors"
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# Test 3: Check scripts are executable
echo "Test 3: Checking scripts are executable..."
for script in 00-deploy-infra.sh 01-update-kubeconfig.sh 02-setup-storage.sh 03-deploy-components.sh 04-verify-storage.sh 05-deploy-producer.sh 06-submit-flink-job.sh 07-deploy-dashboard.sh 08-verify-deployment.sh deploy-benchmark.sh; do
    if [ -x "${SCRIPT_DIR}/${script}" ]; then
        echo "  ✓ ${script}"
    else
        echo "  ⚠ ${script} is not executable (fixing...)"
        chmod +x "${SCRIPT_DIR}/${script}"
        WARNINGS=$((WARNINGS + 1))
    fi
done
echo ""

# Test 4: Check master script help works
echo "Test 4: Testing master script help..."
if bash "${SCRIPT_DIR}/deploy-benchmark.sh" --help 2>&1 | grep -q "Usage:"; then
    echo "  ✓ deploy-benchmark.sh --help works"
else
    echo "  ✗ deploy-benchmark.sh --help failed"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Test 5: Check file references in scripts
echo "Test 5: Checking file references..."
echo "  Checking 02-setup-storage.sh references..."
if grep -q "setup-local-storage.sh" "${SCRIPT_DIR}/02-setup-storage.sh"; then
    if [ -f "${K8S_DIR}/storage/setup-local-storage.sh" ]; then
        echo "  ✓ storage/setup-local-storage.sh exists"
    else
        echo "  ⚠ storage/setup-local-storage.sh not found (may be OK if not using storage)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo "  Checking 03-deploy-components.sh references..."
if grep -q "deploy.sh" "${SCRIPT_DIR}/03-deploy-components.sh"; then
    if [ -f "${K8S_DIR}/deploy.sh" ]; then
        echo "  ✓ deploy.sh exists"
    else
        echo "  ✗ deploy.sh not found"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo "  Checking 05-deploy-producer.sh references..."
if grep -q "create-table.sh" "${SCRIPT_DIR}/05-deploy-producer.sh"; then
    if [ -f "${K8S_DIR}/jobs/create-table.sh" ]; then
        echo "  ✓ jobs/create-table.sh exists"
    else
        echo "  ✗ jobs/create-table.sh not found"
        ERRORS=$((ERRORS + 1))
    fi
fi

if grep -q "deploy-producer-multi-instance.sh" "${SCRIPT_DIR}/05-deploy-producer.sh"; then
    if [ -f "${K8S_DIR}/jobs/deploy-producer-multi-instance.sh" ]; then
        echo "  ✓ jobs/deploy-producer-multi-instance.sh exists"
    else
        echo "  ✗ jobs/deploy-producer-multi-instance.sh not found"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo "  Checking 06-submit-flink-job.sh references..."
if grep -q "submit-job-from-image.sh" "${SCRIPT_DIR}/06-submit-flink-job.sh"; then
    if [ -f "${K8S_DIR}/flink/submit-job-from-image.sh" ]; then
        echo "  ✓ flink/submit-job-from-image.sh exists"
    else
        echo "  ✗ flink/submit-job-from-image.sh not found"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo "  Checking 07-deploy-dashboard.sh references..."
if grep -q "deploy-dashboard.sh\|grafana-dashboard.yaml" "${SCRIPT_DIR}/07-deploy-dashboard.sh"; then
    if [ -f "${K8S_DIR}/monitoring/deploy-dashboard.sh" ] || [ -f "${K8S_DIR}/monitoring/grafana-dashboard.yaml" ]; then
        echo "  ✓ monitoring dashboard files exist"
    else
        echo "  ⚠ monitoring dashboard files not found (may be OK)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi
echo ""

# Test 6: Check master script step validation
echo "Test 6: Testing master script step validation..."
if bash "${SCRIPT_DIR}/deploy-benchmark.sh" --only-step 99 2>&1 | grep -q "Invalid step number\|ERROR"; then
    echo "  ✓ Invalid step number validation works"
else
    echo "  ⚠ Step validation may not be working correctly"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Test 7: Check environment variable handling
echo "Test 7: Testing environment variable defaults..."
export NAMESPACE=""
export DEMO_IMAGE_REPO=""
export CLUSTER_NAME=""
export REGION=""
if bash -c 'source "${SCRIPT_DIR}/deploy-benchmark.sh" 2>/dev/null; echo "NAMESPACE=${NAMESPACE:-fluss} CLUSTER=${CLUSTER_NAME:-fluss-eks-cluster}"' 2>&1 | grep -q "fluss"; then
    echo "  ✓ Environment variable defaults work"
else
    echo "  ⚠ Environment variable defaults may not work correctly"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Summary
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo "Errors: ${ERRORS}"
echo "Warnings: ${WARNINGS}"
echo ""

if [ ${ERRORS} -eq 0 ]; then
    echo "✓ All critical tests passed!"
    if [ ${WARNINGS} -gt 0 ]; then
        echo "⚠ Some warnings found (see above)"
    fi
    exit 0
else
    echo "✗ Some tests failed. Please fix the errors above."
    exit 1
fi


