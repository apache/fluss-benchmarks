# FLUSS 2-Million Messages Per Second - Deployment Instructions

This document provides a comprehensive list of deployment instructions for the FLUSS 2-million-messages-per-second benchmark infrastructure.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Infrastructure Deployment (Terraform)](#infrastructure-deployment-terraform)
3. [Kubernetes Configuration](#kubernetes-configuration)
4. [Component Deployment](#component-deployment)
5. [Storage Setup](#storage-setup)
6. [Producer Deployment](#producer-deployment)
7. [Flink Job Deployment](#flink-job-deployment)
8. [Monitoring Setup](#monitoring-setup)
9. [Verification](#verification)
10. [Accessing Services](#accessing-services)
11. [Troubleshooting](#troubleshooting)
12. [Cleanup](#cleanup)

---

## Prerequisites

Before starting deployment, ensure you have:

- [ ] **AWS CLI** configured with appropriate credentials
- [ ] **Terraform** >= 1.0 installed
- [ ] **kubectl** installed and configured
- [ ] **helm** >= 3.0 installed
- [ ] **Docker** installed (for building images)
- [ ] **Maven** installed (for building Java applications)
- [ ] AWS account with permissions to:
  - Create EKS clusters
  - Create VPCs and subnets
  - Create EC2 instances
  - Create ECR repositories
  - Create S3 buckets
  - Create IAM roles and policies

---

## Infrastructure Deployment (Terraform)

### Step 1: Configure Terraform Variables

```bash
cd demos/2-million-messages-per-second/high-infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

**Key variables to configure:**
- `aws_region` - AWS region (default: `us-west-2`)
- `eks_cluster_name` - EKS cluster name (default: `fluss-eks-cluster`)
- `fluss_image_repository` - ECR repository URL for Fluss image
- `demo_image_repository` - ECR repository URL for demo image
- `subnet_ids` - List of private subnet IDs for EC2 instances
- `security_group_ids` - (Optional) Additional security groups
- `key_name` - (Optional) SSH key pair name

### Step 2: Build and Push Docker Images to ECR

Set the Fluss version via `default.env.sh` first (`--fluss-version` is required). Push scripts read `FLUSS_VERSION` from the environment.

**Option A: Use Automated Script**

```bash
cd e2e-iot
source ./default.env.sh --fluss-version 0.9.0-incubating
./push-images-to-ecr.sh --all
# or: ./push-images-to-ecr.sh --fluss-only
```

**Option B: Manual Build and Push**

```bash
VERSION=0.9.0-incubating

# Build demo application (client deps match Fluss version)
cd e2e-iot/fluss_flink_realtime
mvn clean package -Dfluss.version=${VERSION}
docker build -t fluss-demo:latest .

# Get ECR login
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_BASE}

# Tag and push demo image
docker tag fluss-demo:latest ${ECR_BASE}/fluss-demo:latest
docker push ${ECR_BASE}/fluss-demo:latest

# Pull, tag, and push Fluss image
docker pull apache/fluss:${VERSION}
docker tag apache/fluss:${VERSION} ${ECR_BASE}/fluss:${VERSION}
docker tag apache/fluss:${VERSION} ${ECR_BASE}/fluss:latest
docker push ${ECR_BASE}/fluss:${VERSION}
docker push ${ECR_BASE}/fluss:latest
```

### Step 3: Initialize and Apply Terraform

```bash
cd demos/2-million-messages-per-second/high-infra/terraform

# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply infrastructure
terraform apply
```

**What gets created:**
- EKS cluster with node groups:
  - Coordinator nodes (1 node)
  - Tablet server nodes (3 nodes)
  - Flink JobManager node (1 node)
  - Flink TaskManager nodes (6 nodes)
  - Producer nodes (4 nodes)
- ECR repositories (`fluss-demo`, `fluss`)
- VPC with public/private subnets
- EBS CSI driver (for persistent volumes)
- S3 bucket for Flink checkpoints
- IAM roles and policies

**Wait for nodes to join the cluster:**
```bash
kubectl get nodes
# Should show all nodes in Ready state
```

---

## Kubernetes Configuration

### Step 4: Update Kubeconfig

```bash
cd demos/2-million-messages-per-second/high-infra/terraform
aws eks update-kubeconfig --region us-west-2 --name fluss-eks-cluster

# Verify connection
kubectl cluster-info
kubectl get nodes
```

---

## Storage Setup

### Step 5: Setup Local NVMe Storage (for Tablet Servers)

**IMPORTANT:** Tablet servers require NVMe storage for optimal performance.

```bash
cd demos/2-million-messages-per-second/high-infra/k8s/storage
./setup-local-storage.sh
```

**What this script does:**
- Creates `local-storage` StorageClass
- Creates PersistentVolumes for tablet servers (3 PVs, 500Gi each)
- Configures node affinity to tablet-server nodes
- Sets up NVMe mount paths (`/opt/alldata/fluss/data`)

**Verify storage setup:**
```bash
kubectl get storageclass local-storage
kubectl get pv -l component=tablet-server
kubectl get pv -l component=tablet-server -o yaml | grep -A 5 "path:"
# Should show: path: /opt/alldata/fluss/data
```

---

## Component Deployment

### Step 6: Deploy All Components

Deploy ZooKeeper, Fluss, Flink, and Monitoring stack:

```bash
cd demos/2-million-messages-per-second/high-infra/k8s

# Get ECR repository URLs (adjust account ID and region as needed)
DEMO_IMAGE_REPO="343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo"
FLUSS_IMAGE_REPO="343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss"

# Deploy with ECR images
./deploy.sh fluss "${DEMO_IMAGE_REPO}" latest "${FLUSS_IMAGE_REPO}"
```

**What gets deployed:**
1. **Namespace**: Creates `fluss` namespace
2. **ZooKeeper**: StatefulSet with 1 replica
3. **Fluss**:
   - Coordinator (1 replica)
   - Tablet Servers (3 replicas)
   - Uses ECR image: `${FLUSS_IMAGE_REPO}:latest`
4. **Flink**:
   - JobManager (1 replica)
   - TaskManager (6 replicas, 32 slots each)
   - Uses ECR image: `${DEMO_IMAGE_REPO}:latest`
   - JAR embedded at: `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
5. **Monitoring**:
   - Prometheus (kube-prometheus-stack)
   - Grafana
   - ServiceMonitors and PodMonitors for metrics scraping
6. **Grafana Dashboard**: ConfigMap with Fluss & Flink dashboard

**Wait for components to be ready:**
```bash
# Check Fluss pods
kubectl get pods -n fluss

# Check monitoring pods
kubectl get pods -n monitoring

# Wait for all pods to be Running
kubectl wait --for=condition=ready pod -l app=zookeeper -n fluss --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=coordinator -n fluss --timeout=300s
kubectl wait --for=condition=ready pod -l app=flink,component=jobmanager -n fluss --timeout=120s
```

---

## Storage Verification

### Step 7: Verify NVMe Storage for Tablet Servers

**CRITICAL:** Verify tablet server storage is using NVMe drives before proceeding.

```bash
# Verify PVs exist and are bound
kubectl get pv -l component=tablet-server

# Check PV details - should show path: /opt/alldata/fluss/data
kubectl get pv -l component=tablet-server -o yaml | grep -A 5 "path:"

# Verify PVCs are bound to PVs
kubectl get pvc -n fluss

# Check tablet server pods and their volumes
kubectl get pods -n fluss -l app.kubernetes.io/component=tablet-server -o wide

# Verify mount paths inside tablet server pods (Fluss uses data.dir=/tmp/fluss/data)
kubectl exec -n fluss <tablet-server-pod-name> -- df -h /tmp/fluss/data

# Check PVCs were created and bound by the StatefulSet
kubectl get pvc -n fluss
kubectl get pv -l component=tablet-server
```

**Expected Results:**
- PVs should show `path: /opt/alldata/fluss/data` (node-local NVMe path)
- PVCs `data-tablet-server-0`, `data-tablet-server-1`, `data-tablet-server-2` should be `Bound`
- Tablet server pods mount the PV at `/tmp/fluss/data` (not `/opt/alldata` inside the pod)
- On the node, NVMe is at `/opt/alldata` with data at `/opt/alldata/fluss/data`

**If PVCs are missing:** The tablet-server StatefulSet was likely created without
`persistence.enabled=true`. Delete and redeploy Fluss (StatefulSet volumeClaimTemplates
are immutable):

```bash
kubectl delete sts tablet-server -n fluss --cascade=orphan
cd high-infra/k8s && ./deploy.sh fluss "${DEMO_IMAGE_REPO}" latest "${FLUSS_IMAGE_REPO}"
```

---

## Producer Deployment

### Step 8: Create Fluss Table

Before deploying producers, create the Fluss table with 128 buckets:

```bash
cd demos/2-million-messages-per-second/high-infra/k8s/jobs

# Create table with 128 buckets
export BUCKETS=128
./create-table.sh
```

**Verify table creation:**
```bash
kubectl logs -n fluss -l app=create-table --tail=50
```

### Step 9: Deploy Multi-Instance Producer

Deploy 8 producer instances (2 per node across 4 producer nodes) with 128 buckets:

**Option A: Use Multi-Instance Script (Recommended)**

```bash
cd demos/2-million-messages-per-second/high-infra/k8s/jobs

# Deploy 8 producer instances with 128 buckets
export BUCKETS=128
./deploy-producer-multi-instance.sh --wait
```

**Option B: Custom Parameters**

```bash
cd demos/2-million-messages-per-second/high-infra/k8s/jobs

# Deploy 8 producer instances with custom parameters
export BUCKETS=128
export PRODUCER_RATE=250000
export TOTAL_PRODUCERS=8
./deploy-producer-multi-instance.sh --wait
```

**Multi-Instance Configuration (defaults):**
- **Total Instances**: 8 (instance IDs 0-7)
- **Distribution**: 2 pods per producer node (4 nodes total)
- **Rate per instance**: 250,000 records/second
- **Total rate**: 2,000,000 records/second
- **Flush**: Every 5,000 records (optimal for throughput)
- **Batch Timeout**: 90ms (optimal for batching)
- **Buffer Size**: 2GB
- **Batch Size**: 128MB
- **Memory**: 4Gi request, 16Gi limit per instance
- **CPU**: 2000m request, 8000m limit per instance
- **Writer Threads**: 48 per instance
- **Buckets**: 128 (must match table bucket count)

**Monitor producers:**
```bash
# Check producer pod status (should see 8 pods, 2 per node)
kubectl get pods -n fluss -l app=fluss-producer -o wide

# View producer logs (all instances)
kubectl logs -n fluss -l app=fluss-producer -f

# View logs for specific instance
kubectl logs -n fluss -l app=fluss-producer,job-name=fluss-producer-0 -f

# Check pod distribution across nodes
kubectl get pods -n fluss -l app=fluss-producer -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' | sort -k2

# Check producer metrics
kubectl port-forward -n fluss svc/fluss-producer-metrics 8080:8080
# Then visit: http://localhost:8080/metrics
```

---

## Flink Job Deployment

### Step 10: Submit Flink Aggregator Job

Submit the Flink job that processes sensor data:

```bash
cd demos/2-million-messages-per-second/high-infra/k8s/flink
./submit-job-from-image.sh
```

**What this script does:**
1. Cancels any existing Flink jobs
2. Verifies JAR exists in Flink image at `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
3. Uploads JAR from the image's local filesystem to Flink cluster
4. Submits job via REST API with:
   - Entry class: `org.apache.fluss.benchmarks.flink.FlinkSensorAggregatorJob`
   - Parallelism: 192 (distributed across 6 TaskManager pods)
   - Window: 1 minute
   - **Scan mode**: `latest` (reads from latest position, not from beginning)
5. Configures S3 checkpoints automatically (from Terraform outputs)

**Monitor Flink job:**
```bash
# Check Flink pods
kubectl get pods -n fluss -l app=flink

# Access Flink Web UI
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
# Then visit: http://localhost:8081

# View Flink job logs
kubectl logs -n fluss -l app=flink,component=taskmanager -f
```

**Verify S3 Checkpoints:**
```bash
# Get S3 bucket name from Terraform
cd demos/2-million-messages-per-second/high-infra/terraform
S3_BUCKET=$(terraform output -raw flink_s3_bucket_name)

# Check checkpoints are being written to S3
aws s3 ls s3://${S3_BUCKET}/flink-checkpoints/fluss-eks-cluster/ --recursive

# Verify checkpoint configuration in Flink ConfigMap
kubectl get configmap flink-config -n fluss -o yaml | grep -A 2 "state.checkpoints.dir"
```

---

## Monitoring Setup

### Step 11: Deploy Grafana Dashboard

Deploy the Grafana dashboard for monitoring:

```bash
cd demos/2-million-messages-per-second/high-infra/k8s/monitoring
./deploy-dashboard.sh
```

**Dashboard includes:**
- Producer metrics (records/sec, latency)
- Flink metrics (input/output rates, aggregator records)
- Fluss Coordinator metrics (cluster status, table/bucket counts)
- Fluss Tablet Server metrics (messages rate, bytes rate, replication)
- JVM metrics (CPU, memory for coordinator and tablet servers)

---

## Verification

### Step 12: Verify Complete Deployment

**Check All Pods:**
```bash
# Fluss namespace
kubectl get pods -n fluss

# Expected:
# - zk-0: Running
# - coordinator-server-0: Running
# - tablet-server-0, tablet-server-1, tablet-server-2: Running
# - flink-jobmanager-*: Running
# - flink-taskmanager-0 through flink-taskmanager-5: Running
# - fluss-producer-*: Running (8 pods)

# Monitoring namespace
kubectl get pods -n monitoring
```

**Check Node Placement:**
```bash
# Verify nodes are on correct instance types
kubectl get nodes -l node-type=coordinator
kubectl get nodes -l node-type=tablet-server
kubectl get nodes -l node-type=flink-jobmanager
kubectl get nodes -l node-type=flink-taskmanager
kubectl get nodes -l node-type=producer

# Check pod placement
kubectl get pods -n fluss -o wide
```

**Verify Metrics Scraping:**
```bash
# Check ServiceMonitors
kubectl get servicemonitor -n fluss

# Check PodMonitors
kubectl get podmonitor -n fluss

# Port-forward Prometheus and check targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Visit: http://localhost:9090/targets
# All targets should be "UP"
```

**Verify Data Flow:**
```bash
# Check producer is writing data
kubectl logs -n fluss -l app=fluss-producer --tail=50 | grep -i "records\|throughput"

# Check Flink is processing data
kubectl logs -n fluss -l app=flink,component=taskmanager --tail=50 | grep -i "aggregate\|records"

# Check Fluss tablet servers are receiving data
kubectl logs -n fluss -l app.kubernetes.io/component=tablet-server --tail=20
```

---

## Accessing Services

### Flink Web UI
```bash
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
# Open http://localhost:8081
```

### Grafana
```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Then visit: http://localhost:3000
# Username: admin
# Password: admin123
```

### Prometheus
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Visit: http://localhost:9090
```

### Producer Metrics
```bash
kubectl port-forward -n fluss svc/fluss-producer-metrics 8080:8080
# Visit: http://localhost:8080/metrics
```

---

## Troubleshooting

### Producer Not Starting

**Issue**: Producer pod fails with "Unable to access jarfile"

**Solution**: Ensure JAR path is correct in `producer-job.yaml`:
- Correct path: `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
- Image must be built with JAR embedded

### Flink Job Submission Fails

**Issue**: Cannot upload JAR or submit job

**Solution**: 
- Ensure Flink JobManager pod is Running
- Check Flink REST API is accessible: `kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081`
- Verify JAR exists in Flink image:
  ```bash
  kubectl exec -n fluss <jobmanager-pod> -- test -f /opt/flink/usrlib/fluss-flink-realtime-demo.jar
  ```
- If JAR is missing, rebuild and push the image:
  ```bash
  cd demos/2-million-messages-per-second/high-infra/k8s/flink
  ./build-and-push.sh
  ```
- Then restart Flink pods to pull the new image

### Metrics Not Appearing

**Issue**: No metrics in Grafana/Prometheus

**Solution**:
1. Check ServiceMonitors/PodMonitors are deployed:
   ```bash
   kubectl get servicemonitor,podmonitor -n fluss
   ```
2. Verify Prometheus is scraping targets:
   ```bash
   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
   # Visit http://localhost:9090/targets
   ```
3. Check pod annotations:
   ```bash
   kubectl get pod -n fluss -o yaml | grep prometheus.io
   ```

### Pods Not Scheduling

**Issue**: Pods stuck in Pending state

**Solution**:
1. Check node availability:
   ```bash
   kubectl get nodes
   kubectl describe nodes
   ```
2. Check node selectors and tolerations match:
   ```bash
   kubectl describe pod <pod-name> -n fluss | grep -A 5 "Node-Selectors\|Tolerations"
   ```
3. Verify node labels:
   ```bash
   kubectl get nodes --show-labels
   ```

### Tablet Server Storage Not Using NVMe

**Issue**: Tablet servers not using NVMe storage

**Solution**:
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

---

## Cleanup

To remove all deployed components (but keep infrastructure):

```bash
# Delete producer job
kubectl delete job -n fluss fluss-producer

# Delete Flink job (via REST API or UI)
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
# Visit http://localhost:8081 and cancel job

# Delete all components
cd demos/2-million-messages-per-second/high-infra/k8s
kubectl delete -f flink/
kubectl delete -f zookeeper/
helm uninstall fluss -n fluss
helm uninstall prometheus -n monitoring
kubectl delete namespace fluss monitoring
```

To destroy infrastructure:

```bash
cd demos/2-million-messages-per-second/high-infra/terraform
terraform destroy
```

---

## Quick Reference Commands

### View Logs
```bash
# Producer
kubectl logs -n fluss -l app=fluss-producer -f

# Flink JobManager
kubectl logs -n fluss -l app=flink,component=jobmanager -f

# Flink TaskManager
kubectl logs -n fluss -l app=flink,component=taskmanager -f

# Fluss Coordinator
kubectl logs -n fluss -l app.kubernetes.io/component=coordinator -f

# Fluss Tablet Servers
kubectl logs -n fluss -l app.kubernetes.io/component=tablet-server -f
```

### Restart Components
```bash
# Restart producer (using optimal configuration)
kubectl delete job -n fluss fluss-producer
cd demos/2-million-messages-per-second/high-infra/k8s/jobs
./deploy-producer-multi-instance.sh

# Restart Flink job
cd demos/2-million-messages-per-second/high-infra/k8s/flink
./submit-job-from-image.sh
```

---

## Automated Deployment Script

For automated deployment, use the master script:

```bash
cd demos/2-million-messages-per-second/high-infra/k8s/scripts

# Set environment variables
export DEMO_IMAGE_REPO=343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo
export FLUSS_IMAGE_REPO=343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss

# Run all steps
./deploy-benchmark.sh

# Or run specific steps
./deploy-benchmark.sh --start-from-step 5
./deploy-benchmark.sh --only-step 6
```

---

## Additional Resources

- **[DEPLOY-STEPS.md](./high-infra/DEPLOY-STEPS.md)** - Detailed step-by-step deployment guide
- **[DEPLOYMENT_FIXES.md](./high-infra/DEPLOYMENT_FIXES.md)** - Known issues and fixes
- **[k8s/DEPLOYMENT.md](./high-infra/k8s/DEPLOYMENT.md)** - Kubernetes deployment guide
- **[MONITORING.md](./high-infra/MONITORING.md)** - Monitoring setup and configuration
- **[PRODUCER_CONFIG.md](./high-infra/k8s/jobs/PRODUCER_CONFIG.md)** - Producer configuration guide
- **[README.md](./README.md)** - Benchmark overview and architecture

---

## Notes

- **ECR Images**: Ensure images are pushed to ECR before deployment
- **Storage**: Local NVMe storage setup is required for tablet servers if using persistence
- **Node Types**: All components are configured to run on specific node groups:
  - Coordinator: c5.2xlarge
  - Tablet Servers: i7i.8xlarge (with NVMe)
  - Flink JobManager: c5.4xlarge
  - Flink TaskManager: c5.4xlarge
  - Producer: c5.2xlarge
- **Parallelism**: Flink job is configured with parallelism 192 (32 slots per TaskManager × 6 TaskManagers)
- **Scan Mode**: Flink job reads from `latest` position (configured via SQL hint `scan.startup.mode = 'latest'`), meaning it only processes new data and doesn't read historical data from the beginning
- **Buckets**: Table must be created with 128 buckets to match producer configuration

