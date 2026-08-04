<!--
 Licensed to the Apache Software Foundation (ASF) under one or more
 contributor license agreements.  See the NOTICE file distributed with
 this work for additional information regarding copyright ownership.
 The ASF licenses this file to You under the Apache License, Version 2.0
 (the "License"); you may not use this file except in compliance with
 the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
-->


# Local NVMe Storage Setup for Fluss Tablet Servers

This directory contains the configuration and scripts needed to set up local NVMe storage for Fluss tablet servers, similar to how Pulsar handles local storage.

## Overview

The setup uses:
- **StorageClass**: `local-storage` with `no-provisioner` (requires manual PV creation)
- **PersistentVolumes**: Manually created PVs that reference local paths on tablet server nodes
- **Node Setup**: NVMe drives are automatically formatted and mounted by Terraform's `pre_bootstrap_user_data` script

## Prerequisites

1. **Terraform Infrastructure**: The tablet server nodes must be deployed with NVMe drives mounted at:
   - `/opt/alldata` (NVMe mount point)
   - `/opt/alldata/fluss/data` (primary data storage, used as PV local path)

2. **Node Labels**: Tablet server nodes must have:
   - `fluss-component: tablet-server`
   - `storage-type: nvme`

## Setup Steps

### 1. Create StorageClass and PersistentVolumes

Run the setup script:

```bash
cd /path/to/fluss-benchmarks/e2e-iot/high-infra/k8s/storage
export NAMESPACE=fluss
export TABLET_REPLICAS=3  # Match your tablet server replica count
export STORAGE_SIZE=500Gi  # Adjust based on your NVMe drive size

./setup-local-storage.sh
```

This script will:
- Create the `local-storage` StorageClass
- Create PersistentVolumes for each tablet server replica
- Clean up any existing PVs before creating new ones

### 2. Verify Setup

```bash
# Check StorageClass
kubectl get storageclass local-storage

# Check PersistentVolumes
kubectl get pv -l component=tablet-server

# Verify PVs are in Available state
kubectl get pv -l component=tablet-server -o wide
```

### 3. Deploy Fluss with Local Storage

Update your Helm values (`helm-charts/fluss-values.yaml`) or deployment script to use:

```yaml
persistence:
  enabled: true
  storageClass: local-storage
  size: 500Gi
  local_storage: true
```

Or set environment variables when deploying:

```bash
export enable_persistence=true
export storage_class=local-storage
export storage_size=500Gi
export local_storage=true
```

### 4. Deploy Fluss

Deploy Fluss using your normal deployment process. The StatefulSet will create PVCs that bind to the manually created PVs.

## How It Works

1. **Terraform Setup**: When tablet server nodes are created, the `pre_bootstrap_user_data` script:
   - Formats NVMe drive (`/dev/nvme1n1`)
   - Mounts it to `/opt/alldata`
   - Creates `/opt/alldata/fluss/data`, `remote-data`, and `logs` with proper permissions

2. **Kubernetes Storage**: 
   - StorageClass `local-storage` uses `no-provisioner` (manual PV creation)
   - PersistentVolumes are created manually, each referencing a local path on a specific node
   - PVs have node affinity to ensure they only bind to tablet server nodes

3. **Pod Binding**:
   - When a Fluss tablet server pod is created, it requests a PVC
   - The PVC binds to an available PV based on node affinity
   - The pod mounts the local NVMe storage at `/tmp/fluss/data`

## Files

- `local-storage-class.yaml`: StorageClass definition
- `create-local-pvs.sh`: Script to generate PersistentVolumes
- `setup-local-storage.sh`: Main setup script (runs everything)

## Troubleshooting

### PVs Not Binding

If PVCs remain in `Pending` state:

1. Check PV node affinity matches your nodes:
   ```bash
   kubectl get pv fluss-tablet-data-0 -o yaml | grep -A 10 nodeAffinity
   ```

2. Verify node labels:
   ```bash
   kubectl get nodes -l fluss-component=tablet-server --show-labels
   ```

3. Check if PVs are in `Available` state:
   ```bash
   kubectl get pv -l component=tablet-server
   ```

### Storage Not Available

If pods can't access storage:

1. Verify NVMe drives are mounted on nodes:
   ```bash
   kubectl debug node/<tablet-server-node> -it --image=busybox -- df -h /mnt/fluss-tablet-data
   ```

2. Check directory permissions:
   ```bash
   kubectl debug node/<tablet-server-node> -it --image=busybox -- ls -la /mnt/fluss-tablet-data
   ```

### Recreating PVs

To recreate PVs (e.g., after changing replica count):

```bash
# Delete existing PVs
kubectl delete pv -l component=tablet-server,type=local-nvme

# Recreate with new settings
export TABLET_REPLICAS=5
./setup-local-storage.sh
```

## Notes

- **Reclaim Policy**: PVs use `Retain` policy to prevent accidental data loss
- **Volume Binding**: Uses `WaitForFirstConsumer` to ensure pods are scheduled on correct nodes
- **Storage Size**: Adjust `STORAGE_SIZE` based on your actual NVMe drive capacity
- **Replica Count**: Ensure `TABLET_REPLICAS` matches your Fluss tablet server replica count

