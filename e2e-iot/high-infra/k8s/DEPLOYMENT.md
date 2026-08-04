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


# Complete Deployment Guide

This guide walks through deploying the entire Fluss + Flink stack on AWS EKS.

## Prerequisites

1. **AWS CLI configured** with appropriate credentials
2. **Terraform** installed (>= 1.0)
3. **kubectl** installed and configured
4. **helm** installed (>= 3.0)
5. **Docker images** built and pushed to ECR for your Fluss version (default `0.9.0-incubating`):
   - Fluss image: `fluss:<FLUSS_VERSION>` (e.g. `fluss:0.9.0-incubating`)
   - Demo image: `fluss-demo:latest` (contains producer and Flink job JAR)

```bash
cd e2e-iot
source ./default.env.sh --fluss-version 0.9.0-incubating
./push-images-to-ecr.sh --all
```

## Step 1: Create EKS Cluster and Node Groups

```bash
cd e2e-iot/high-infra/terraform

# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply infrastructure
terraform apply
```

This creates:
- VPC with public/private subnets
- EKS cluster
- Node groups:
  - Coordinator nodes (1 node)
  - Tablet server nodes (3 nodes)
  - Flink JobManager node (1 node)
  - Flink TaskManager nodes (2 nodes)
- ECR repositories
- EBS CSI driver

**Wait for all nodes to join the cluster:**
```bash
kubectl get nodes
# Should show 7 nodes total
```

## Step 2: Configure kubectl

```bash
# Get kubeconfig
aws eks update-kubeconfig --name fluss-eks-cluster --region us-west-2

# Verify access
kubectl get nodes
```

## Step 3: Deploy All Kubernetes Resources

```bash
cd e2e-iot

# After push-images-to-ecr.sh (with default.env.sh already sourced)
cd high-infra/k8s
./deploy.sh fluss "${DEMO_IMAGE_REPO}" "${DEMO_IMAGE_TAG}" "${FLUSS_IMAGE_REPO}"
```

The deployment script will:
1. Create namespace
2. Deploy ZooKeeper
3. Deploy Fluss (via Helm)
4. Deploy Flink cluster (JobManager + TaskManagers)
5. Deploy monitoring stack (Prometheus + Grafana)
6. Deploy ServiceMonitors and PodMonitors
7. Wait for components to be ready

**Note:** Producer and Flink job deployment are done separately (see steps below).

## Step 4: Verify NVMe Storage for Tablet Servers

**IMPORTANT:** Verify that tablet server storage is using NVMe drives before proceeding.

### Check PersistentVolumes are using NVMe:
```bash
# Verify PVs exist and are bound
kubectl get pv -l component=tablet-server

# Check PV details - should show path: /opt/alldata/fluss/data
kubectl get pv -l component=tablet-server -o yaml | grep -A 5 "path:"

# Verify PVCs are bound to PVs
kubectl get pvc -n fluss
```

### Verify tablet server pods are using NVMe storage:
```bash
# Check tablet server pods and their volumes
kubectl get pods -n fluss -l app=fluss,component=tablet-server -o wide

# Verify mount paths inside tablet server pods
kubectl exec -n fluss <tablet-server-pod-name> -- df -h /tmp/fluss/data

# Check PVCs are bound
kubectl get pvc -n fluss
```

### Verify NVMe drives are mounted on nodes:
```bash
# Get tablet server node names
TABLET_NODES=$(kubectl get nodes -l fluss-component=tablet-server -o jsonpath='{.items[*].metadata.name}')

# Check NVMe mount on each node (requires node debug access)
for node in $TABLET_NODES; do
  echo "Checking node: $node"
  kubectl debug node/$node -it --image=busybox -- sh -c "df -h | grep alldata || echo 'NVMe not mounted'"
done
```

**Expected Results:**
- PVs should show `path: /opt/alldata/fluss/data` (on the node)
- PVCs `data-tablet-server-*` should be `Bound` to those PVs
- Tablet server pods mount storage at `/tmp/fluss/data` (Fluss `data.dir`)
- Nodes should show NVMe drives mounted at `/opt/alldata`

## Step 5: Deploy Multi-Instance Producer

Deploy 8 producer instances (2 per node across 4 producer nodes) with 128 buckets:

```bash
cd e2e-iot/high-infra/k8s/jobs

# Deploy multi-instance producer (8 instances total, 2 per node, 128 buckets)
export BUCKETS=128
./deploy-producer-multi-instance.sh

# Or with custom parameters:
export PRODUCER_RATE=250000
export TOTAL_PRODUCERS=8
export BUCKETS=128
./deploy-producer-multi-instance.sh
```

This will:
- Deploy 8 producer jobs (instance IDs 0-7)
- Ensure 2 pods per producer node using topology spread constraints
- Each producer runs at the specified rate (default: 250K records/sec per instance)
- Uses 128 buckets for the Fluss table (must match table bucket count)

**Verify producer deployment:**
```bash
# Check producer pods (should see 8 pods, 2 per node)
kubectl get pods -n fluss -l app=fluss-producer -o wide

# Check producer metrics
kubectl logs -n fluss -l app=fluss-producer --tail=50
```

## Step 6: Deploy Flink Job

Submit the Flink aggregator job:

```bash
cd e2e-iot/high-infra/k8s/flink

# Submit Flink job (automatically configures S3 checkpoints)
./submit-job-from-image.sh
```

This script will:
1. Update Flink ConfigMap with S3 checkpoint paths (from Terraform outputs)
2. Restart Flink pods to apply new configuration
3. Submit the Flink aggregator job

**Note:** S3 checkpoint configuration is automatically handled by the script.

## Step 7: Verify Deployment

### Check all pods are running:
```bash
kubectl get pods -n fluss
kubectl get pods -n monitoring
```

### Verify Flink cluster:
```bash
# Check Flink pods
kubectl get pods -n fluss -l app=flink

# Verify node placement
kubectl get pods -n fluss -l app=flink -o wide
kubectl get nodes -l flink-component --show-labels
```

### Verify Flink S3 Checkpoints:
```bash
# Get S3 bucket name from Terraform
cd e2e-iot/high-infra/terraform
S3_BUCKET=$(terraform output -raw flink_s3_bucket_name)

# Check checkpoints are being written to S3
aws s3 ls s3://${S3_BUCKET}/flink-checkpoints/fluss-eks-cluster/ --recursive

# Verify checkpoint configuration in Flink ConfigMap
kubectl get configmap flink-config -n fluss -o yaml | grep -A 2 "state.checkpoints.dir"
```

### Verify monitoring:
```bash
# Check ServiceMonitors
kubectl get servicemonitor -n fluss

# Check PodMonitors
kubectl get podmonitor -n fluss

# Check Prometheus targets (after port-forwarding)
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090/targets
```

## Step 8: Access Services

### Flink Web UI
```bash
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
# Open http://localhost:8081
```

### Grafana
```bash
GRAFANA_SVC=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n monitoring svc/$GRAFANA_SVC 3000:80
# Open http://localhost:3000
# Username: admin
# Password: admin123
```

### Prometheus
```bash
PROM_SVC=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n monitoring svc/$PROM_SVC 9090:9090
# Open http://localhost:9090
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      EKS Cluster                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ Coordinator │  │ Tablet Svr 1 │  │ Tablet Svr 2 │     │
│  │   (1 node)  │  │   (1 node)   │  │   (1 node)   │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ JobManager  │  │ TaskManager │  │ TaskManager │     │
│  │   (1 node)  │  │   (1 node)  │  │   (1 node)  │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐                       │
│  │  Producer    │  │  Monitoring │                       │
│  │ (8 instances │  │  (Prom/Graf)│                       │
│  │  2 per node) │  │             │                       │
│  └──────────────┘  └──────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### Pods not starting
```bash
# Check pod events
kubectl describe pod <pod-name> -n fluss

# Check logs
kubectl logs <pod-name> -n fluss
```

### Flink job not submitted
```bash
# Check job submission logs
kubectl logs -n fluss -l app=flink-job-submission

# Check if Flink JobManager is ready
kubectl get pods -n fluss -l component=jobmanager
kubectl logs -n fluss -l component=jobmanager
```

### Metrics not appearing
```bash
# Check if ServiceMonitors are created
kubectl get servicemonitor -n fluss

# Check Prometheus targets
# Port-forward Prometheus and check /targets endpoint

# Verify metrics endpoints
kubectl port-forward -n fluss <pod-name> 8080:8080
curl http://localhost:8080/metrics
```

### Node placement issues
```bash
# Check node labels
kubectl get nodes --show-labels

# Check pod node placement
kubectl get pods -n fluss -o wide

# Check pod events for scheduling issues
kubectl describe pod <pod-name> -n fluss | grep -A 10 Events
```

### Tablet server storage not using NVMe
```bash
# Check PV bindings
kubectl get pv -l component=tablet-server
kubectl get pvc -n fluss

# Verify PV paths point to NVMe mount
kubectl get pv fluss-tablet-data-0 -o jsonpath='{.spec.local.path}'
# Should show: /opt/alldata/fluss/data

# Check tablet server pod volumes
kubectl describe pod <tablet-server-pod> -n fluss | grep -A 10 "Mounts:"

# Verify NVMe is mounted on node
kubectl debug node/<tablet-node> -it --image=busybox -- df -h | grep alldata
```

### Producer pods not distributing correctly
```bash
# Check topology spread constraints
kubectl get pods -n fluss -l app=fluss-producer -o wide

# Verify 2 pods per producer node
kubectl get pods -n fluss -l app=fluss-producer -o wide | awk '{print $7}' | sort | uniq -c

# Check producer job configuration
kubectl get job -n fluss -l app=fluss-producer -o yaml | grep -A 5 topologySpreadConstraints
```

## Cleanup

To destroy everything:
```bash
# Delete Kubernetes resources
kubectl delete namespace fluss monitoring

# Destroy Terraform infrastructure
cd e2e-iot/high-infra/terraform
terraform destroy
```

