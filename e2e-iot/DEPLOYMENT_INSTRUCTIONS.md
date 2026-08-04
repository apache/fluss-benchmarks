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


# Complete Platform Deployment Instructions

This document provides step-by-step instructions to deploy the complete Fluss platform with Flink integration on AWS EKS.

## Prerequisites

Paths in this guide assume the `fluss-benchmarks` repository root. The E2E IoT benchmark lives under `e2e-iot/`.

- AWS CLI configured with appropriate credentials
- kubectl installed and configured
- terraform installed (>= 1.0)
- helm installed (>= 3.0)
- Docker installed (for building images)
- Maven installed (for building Flink job JAR)

## Step 1: Set Environment Variables

Configure the Fluss version and ECR settings. `--fluss-version` is **required**; the script errors if it is omitted.

```bash
cd e2e-iot
source ./default.env.sh --fluss-version 0.9.0-incubating
```

`default.env.sh` sets:
- `FLUSS_VERSION` - Fluss release tag (from `--fluss-version`)
- `FLUSS_IMAGE_TAG` - ECR image tag for deploy (same as `FLUSS_VERSION`)
- `DEMO_IMAGE_REPO` - ECR repository for demo image
- `DEMO_IMAGE_TAG` - Image tag (default: `latest`)
- `FLUSS_IMAGE_REPO` - ECR repository for Fluss image (no tag; deploy uses `FLUSS_IMAGE_TAG`)
- `NAMESPACE` - Kubernetes namespace (default: `fluss`)
- `CLUSTER_NAME` - EKS cluster name (default: `fluss-eks-cluster`)
- `REGION` - AWS region (default: `us-west-2`)

Deploy scripts (`high-infra/k8s/deploy.sh`, `03-deploy-components.sh`) require `FLUSS_VERSION` from this step.

## Step 2: Push Images to ECR

With `FLUSS_VERSION` set, build and push images. The push script reads `FLUSS_VERSION` from the environment (no CLI version flag).

```bash
# Still in e2e-iot with default.env.sh sourced
./push-images-to-ecr.sh --all

# Or push only Fluss / only demo
./push-images-to-ecr.sh --fluss-only
./push-images-to-ecr.sh --producer-only
```

This script will:
- Build the Fluss demo image using Maven dependencies matching `FLUSS_VERSION`
- Pull `apache/fluss:${FLUSS_VERSION}` from Docker Hub
- Push both images to your AWS ECR repositories

After a successful push, the script writes `ecr-repositories.txt` with `FLUSS_VERSION` and ECR URLs.

Optional: download the matching Helm chart for offline use:

```bash
cd e2e-iot/high-infra
./download-helm-chart.sh
```

## Step 3: Execute Deployment Scripts

Navigate to the scripts directory and execute all deployment scripts in order:

```bash
cd e2e-iot/high-infra/k8s/scripts
```

Execute the following scripts in sequence:

### 3.1: Deploy Infrastructure (Terraform)
```bash
./00-deploy-infra.sh
```

This script:
- Creates EKS cluster using Terraform
- Sets up VPC, subnets, and networking
- Creates ECR repositories
- Sets up S3 bucket for Flink checkpoints
- Configures IAM roles and policies

**Expected duration:** 15-20 minutes

### 3.2: Update Kubeconfig
```bash
./01-update-kubeconfig.sh
```

This script:
- Updates kubeconfig to connect to the EKS cluster
- Verifies cluster connectivity

### 3.3: Setup Storage
```bash
./02-setup-storage.sh
```

This script:
- Creates local storage class for persistent volumes
- Sets up persistent volume claims for Fluss components

### 3.4: Deploy Components
```bash
./03-deploy-components.sh
```

This script:
- Deploys ZooKeeper
- Deploys Apache Fluss (Coordinator and Tablet Servers)
- Deploys Flink cluster (JobManager and TaskManagers)
- Deploys monitoring stack (Prometheus and Grafana)

**Expected duration:** 5-10 minutes

### 3.5: Verify Storage
```bash
./04-verify-storage.sh
```

This script:
- Verifies persistent volume claims are bound
- Checks storage mounts on Fluss tablet servers

### 3.6: Deploy Producer
```bash
./05-deploy-producer.sh
```

This script:
- Creates Fluss table with specified buckets
- Deploys multi-instance producer job
- Starts data ingestion

**Expected duration:** 2-3 minutes

### 3.7: Submit Flink Job
```bash
./06-submit-flink-job.sh
```

This script:
- Submits Flink aggregator job to the cluster
- Configures job to read from Fluss log table
- Starts real-time aggregation

**Expected duration:** 1-2 minutes

### 3.8: Deploy Dashboard
```bash
./07-deploy-dashboard.sh
```

This script:
- Deploys Grafana dashboard ConfigMap
- Imports Fluss and Flink monitoring dashboard
- Configures Prometheus data sources

### 3.9: Verify Deployment
```bash
./08-verify-deployment.sh
```

This script:
- Verifies all pods are running
- Checks ServiceMonitors and PodMonitors
- Verifies producer and Flink job are active
- Displays access information

### 3.10: View End-to-End Metrics
```bash
./09-view-metrics.sh
```

This script:
- Changes to the e2e-iot directory
- Launches Grafana port-forward to view end-to-end metrics
- Opens access to Grafana dashboard for platform monitoring
- Displays real-time metrics and dashboards

**Note:** This script will run in the foreground. Press Ctrl+C to stop port-forwarding.

**Expected duration:** Runs until stopped (Ctrl+C)

## Step 4: Access Services

### Access Flink Web UI

Use the port-forward script:
```bash
cd e2e-iot
./port-forward-flink.sh
```

Or manually:
```bash
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
```

Then open: http://localhost:8081

### Access Grafana Dashboard

Use the port-forward script:
```bash
cd e2e-iot
./port-forward-grafana.sh
```

Or manually:
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

Then open: http://localhost:3000
- **Username:** `admin`
- **Password:** `admin123`

## Quick Reference

### Check Pod Status
```bash
kubectl get pods -n fluss
kubectl get pods -n monitoring
```

### Check Flink Job Status
```bash
kubectl get pods -n fluss -l app=flink
kubectl logs -n fluss -l app=flink,component=jobmanager --tail=50
```

### Check Producer Status
```bash
kubectl get pods -n fluss -l app=fluss-producer
kubectl logs -n fluss -l app=fluss-producer --tail=50
```

### Check Fluss Components
```bash
kubectl get pods -n fluss -l app.kubernetes.io/name=fluss
kubectl get svc -n fluss
```

## Troubleshooting

### Pods Not Starting
```bash
# Check pod events
kubectl describe pod <pod-name> -n fluss

# Check pod logs
kubectl logs <pod-name> -n fluss
```

### Flink Job Not Running
```bash
# Check JobManager logs
kubectl logs -n fluss -l app=flink,component=jobmanager --tail=100

# Check TaskManager logs
kubectl logs -n fluss -l app=flink,component=taskmanager --tail=100
```

### Storage Issues
```bash
# Check PVC status
kubectl get pvc -n fluss

# Check storage class
kubectl get storageclass
```

### Network Issues
```bash
# Check services
kubectl get svc -n fluss

# Check endpoints
kubectl get endpoints -n fluss
```

## Cleanup

To destroy all resources:

```bash
cd e2e-iot/high-infra/terraform
terraform destroy
```

**Warning:** This will delete the EKS cluster, VPC, and all associated resources.

