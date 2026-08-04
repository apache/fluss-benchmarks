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
STORAGE_DIR="${K8S_DIR}/storage"

echo "=== Step 2: Setting up local NVMe storage ==="
echo ""

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed or not in PATH"
    exit 1
fi

# Check storage setup script exists
if [ ! -f "${STORAGE_DIR}/setup-local-storage.sh" ]; then
    echo "ERROR: setup-local-storage.sh not found at ${STORAGE_DIR}/setup-local-storage.sh"
    exit 1
fi

# Run storage setup script
echo "Running storage setup script..."
cd "${STORAGE_DIR}"
./setup-local-storage.sh

# Verify storage setup
echo ""
echo "Verifying storage setup..."
if kubectl get storageclass local-storage &> /dev/null; then
    echo "✓ StorageClass 'local-storage' created"
else
    echo "ERROR: StorageClass 'local-storage' not found"
    exit 1
fi

if kubectl get pv -l component=tablet-server &> /dev/null; then
    PV_COUNT=$(kubectl get pv -l component=tablet-server --no-headers 2>/dev/null | wc -l | awk '{print $1}')
    echo "✓ Found ${PV_COUNT} PersistentVolumes for tablet servers"
    kubectl get pv -l component=tablet-server
else
    echo "ERROR: No PersistentVolumes found for tablet servers"
    exit 1
fi

echo ""
echo "✓ Step 2 completed: Local NVMe storage setup completed successfully"

