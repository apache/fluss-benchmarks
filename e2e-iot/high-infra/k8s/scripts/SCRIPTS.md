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

# Benchmark Deployment Scripts

This directory contains individual deployment scripts for each step of the 2-million-messages-per-second benchmark deployment, along with a master script that orchestrates all steps with error handling.

## Master Script

### `deploy-benchmark.sh`

The master script that runs all deployment steps in sequence with comprehensive error handling.

**Usage:**

```bash
# Run all steps
./deploy-benchmark.sh

# Skip specific steps
./deploy-benchmark.sh --skip-step 4 --skip-step 7

# Start from a specific step (skip previous steps)
./deploy-benchmark.sh --start-from-step 5

# Run only a specific step
./deploy-benchmark.sh --only-step 3

# Show help
./deploy-benchmark.sh --help
```

**Environment Variables:**

- `NAMESPACE` - Kubernetes namespace (default: `fluss`)
- `DEMO_IMAGE_REPO` - Demo image repository (required for step 5)
- `DEMO_IMAGE_TAG` - Demo image tag (default: `latest`)
- `FLUSS_VERSION` - Fluss release tag (set via `source default.env.sh --fluss-version VERSION`)
- `FLUSS_IMAGE_TAG` - Fluss image tag for Helm deploy (defaults to `FLUSS_VERSION`)
- `FLUSS_IMAGE_REPO` - Fluss ECR repository URL without tag (default: `apache/fluss:0.9.0-incubating` if unset)
- `CLUSTER_NAME` - EKS cluster name (default: `fluss-eks-cluster`)
- `REGION` - AWS region (default: `us-west-2`)

**Example:**

```bash
cd e2e-iot
source ./default.env.sh --fluss-version 0.9.0-incubating
./push-images-to-ecr.sh --all

cd high-infra/k8s/scripts
./deploy-benchmark.sh
```

## Individual Scripts

Each script can be run independently, but they are designed to be called by the master script.

### Step 0: `00-deploy-infra.sh`

Deploys AWS infrastructure using Terraform (EKS cluster, node groups, VPC, etc.).

**Requirements:**
- Terraform installed (>= 1.0)
- AWS CLI configured with appropriate credentials
- AWS account with permissions to create EKS clusters, VPCs, EC2 instances, etc.

**Environment Variables:**
- `REGION` - AWS region (default: `us-west-2`)
- `CLUSTER_NAME` - EKS cluster name (default: `fluss-eks-cluster`)
- `AUTO_APPROVE` - Auto-approve terraform apply (default: `false`)

**What it does:**
1. Checks prerequisites (Terraform, AWS CLI, credentials)
2. Validates terraform.tfvars exists (creates from example if missing)
3. Initializes Terraform
4. Validates Terraform configuration
5. Creates Terraform plan
6. Applies infrastructure (with confirmation unless AUTO_APPROVE=true)
7. Waits for EKS cluster to be ACTIVE
8. Waits for nodes to join the cluster
9. Outputs cluster information and next steps

**Configuration:**
Before running, ensure `terraform.tfvars` is configured with:
- `fluss_image_repository` - ECR repository URL for Fluss image
- `demo_image_repository` - ECR repository URL for demo image
- Other required variables (see `terraform.tfvars.example`)

**Example:**
```bash
# Interactive (with confirmation)
./00-deploy-infra.sh

# Auto-approve (no confirmation prompt)
AUTO_APPROVE=true ./00-deploy-infra.sh
```

### Step 1: `01-update-kubeconfig.sh`

Updates kubeconfig to connect to the EKS cluster.

**Requirements:**
- AWS CLI configured
- kubectl installed
- EKS cluster exists

**Environment Variables:**
- `CLUSTER_NAME` - EKS cluster name (default: `fluss-eks-cluster`)
- `REGION` - AWS region (default: `us-west-2`)

### Step 2: `02-setup-storage.sh`

Sets up local NVMe storage for Fluss tablet servers.

**Requirements:**
- kubectl configured
- Storage setup script exists at `../storage/setup-local-storage.sh`

**What it does:**
- Creates `local-storage` StorageClass
- Creates PersistentVolumes for tablet servers
- Verifies storage setup

### Step 3: `03-deploy-components.sh`

Deploys all infrastructure components:
- ZooKeeper
- Fluss (Coordinator + Tablet Servers)
- Flink cluster (JobManager + TaskManagers)
- Monitoring stack (Prometheus + Grafana)
- ServiceMonitors and PodMonitors

**Requirements:**
- kubectl configured
- helm installed
- `deploy.sh` script exists at `../deploy.sh`

**Environment Variables:**
- `NAMESPACE` - Kubernetes namespace (default: `fluss`)
- `DEMO_IMAGE_TAG` - Demo image tag (default: `latest`)
- `FLUSS_VERSION` - Fluss release tag (must match ECR push)
- `FLUSS_IMAGE_REPO` - Fluss ECR repository (without tag)
- `FLUSS_IMAGE_TAG` - Fluss image tag for deploy (defaults to `FLUSS_VERSION`)

**Note:** This step skips producer deployment, which is handled separately in step 5.

### Step 4: `04-verify-storage.sh`

Verifies that NVMe storage is correctly configured for tablet servers.

**Requirements:**
- kubectl configured
- Step 2 completed successfully

**What it checks:**
- PersistentVolumes exist with path `/opt/alldata/fluss/data`
- Fluss StatefulSet has `volumeClaimTemplates` and PVCs are `Bound`
- Tablet server pods mount NVMe at `/tmp/fluss/data` (Fluss `data.dir`)

**Common failure — PVs Available but no PVCs:** Kubernetes does not allow adding
`volumeClaimTemplates` to an existing StatefulSet. Re-run step 3 (`deploy.sh` now
recreates StatefulSets automatically when PVCs are missing).

### Step 5: `05-deploy-producer.sh`

Deploys the multi-instance producer (8 instances, 2 per node).

**Requirements:**
- kubectl configured
- Step 3 completed successfully
- `DEMO_IMAGE_REPO` environment variable set

**Environment Variables:**
- `NAMESPACE` - Kubernetes namespace (default: `fluss`)
- `DEMO_IMAGE_REPO` - Demo image repository (**required**)
- `DEMO_IMAGE_TAG` - Demo image tag (default: `latest`)
- `BUCKETS` - Number of buckets (default: `128`)
- `TOTAL_PRODUCERS` - Number of producer instances (default: `8`)
- `PRODUCER_RATE` - Records per second per producer (default: `250000`)
- `BOOTSTRAP` - Fluss coordinator address
- `DATABASE` - Database name (default: `iot`)
- `TABLE` - Table name (default: `sensor_readings`)

**What it does:**
1. Creates Fluss table with specified number of buckets
2. Deploys multi-instance producer job
3. Verifies producer pods are running

### Step 6: `06-submit-flink-job.sh`

Submits the Flink aggregator job.

**Requirements:**
- kubectl configured
- Step 3 completed successfully
- Flink JobManager pod running

**Environment Variables:**
- `NAMESPACE` - Kubernetes namespace (default: `fluss`)

**What it does:**
1. Verifies Flink JobManager is ready
2. Submits Flink aggregator job via REST API
3. Verifies job is running

### Step 7: `07-deploy-dashboard.sh`

Deploys Grafana dashboard for monitoring.

**Requirements:**
- kubectl configured
- Step 3 completed successfully
- Grafana pod running in monitoring namespace

**Environment Variables:**
- `NAMESPACE` - Kubernetes namespace (default: `fluss`)

**What it does:**
1. Deploys Grafana dashboard ConfigMap
2. Imports dashboard via Grafana API (if possible)
3. Verifies dashboard is available

### Step 8: `08-verify-deployment.sh`

Performs final verification of the deployment.

**Requirements:**
- kubectl configured
- All previous steps completed

**What it checks:**
- All pods are running
- Node placement is correct
- ServiceMonitors and PodMonitors are deployed
- Data flow is working (producer and Flink logs)

## Error Handling

The master script (`deploy-benchmark.sh`) provides comprehensive error handling:

- **Step Failure Detection**: If any step fails, the script immediately stops and reports which step failed
- **Clear Error Messages**: Each failure includes:
  - Step number and description
  - Exit code
  - Instructions for retrying
- **Retry Options**: Failed steps can be retried using:
  - `--start-from-step N` - Retry from a specific step
  - `--only-step N` - Retry only a specific step

## Example Workflows

### Full Deployment

```bash
# Step 0: Deploy infrastructure (if not already done)
./00-deploy-infra.sh

# Steps 1-8: Deploy all components
source ../../../default.env.sh --fluss-version 0.9.0-incubating
./deploy-benchmark.sh
```

Or run everything including infrastructure:

```bash
source ../../../default.env.sh --fluss-version 0.9.0-incubating
./deploy-benchmark.sh  # Runs steps 0-8
```

### Deployment After Infrastructure is Ready

If infrastructure is already deployed, start from step 1:

```bash
./deploy-benchmark.sh --start-from-step 1
```

If components are already deployed, start from step 5:

```bash
export DEMO_IMAGE_REPO=your-repo/fluss-demo
./deploy-benchmark.sh --start-from-step 5
```

### Retry Failed Step

If step 6 failed, retry only that step:

```bash
./deploy-benchmark.sh --only-step 6
```

### Skip Verification Steps

Skip storage verification and final verification:

```bash
./deploy-benchmark.sh --skip-step 4 --skip-step 8
```

## Troubleshooting

### Step Fails with "Script not found"

Ensure you're running scripts from the `scripts/` directory or using absolute paths.

### Step 5 Fails: "DEMO_IMAGE_REPO is not set"

Set the environment variable:
```bash
export DEMO_IMAGE_REPO=your-repo/fluss-demo
```

### Step 3 Fails: "kubectl is not installed"

Install kubectl and ensure it's in your PATH.

### Step 3 Fails: "helm is not installed"

Install helm:
```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Related Documentation

- [DEPLOY-STEPS.md](../DEPLOY-STEPS.md) - Detailed deployment guide
- [DEPLOYMENT.md](../DEPLOYMENT.md) - Kubernetes deployment guide
- [instruction.md](../../instruction.md) - Deployment instructions overview

