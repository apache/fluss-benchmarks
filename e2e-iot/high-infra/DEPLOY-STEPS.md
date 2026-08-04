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


# Deployment Steps Guide

This document describes the step-by-step deployment process for the Fluss high-infrastructure setup, starting from after Terraform infrastructure deployment.

## Prerequisites

Paths in this guide assume the `fluss-benchmarks` repository root. AWS deployment assets live under `e2e-iot/high-infra/`.

- Terraform infrastructure deployed (EKS cluster, node groups, ECR repositories)
- `kubectl` configured and connected to the EKS cluster
- `helm` installed
- AWS CLI configured with appropriate permissions
- ECR images pushed (fluss, fluss-demo) for your chosen Fluss version

### Fluss version and environment

Default Fluss version is `0.9.0-incubating`. Push and deploy must use the same version.

```bash
cd e2e-iot

# Set version and ECR env (required before push or deploy)
source ./default.env.sh --fluss-version 0.9.0-incubating

# Push images (reads FLUSS_VERSION from environment)
./push-images-to-ecr.sh --all
```

| Variable | Purpose |
|----------|---------|
| `FLUSS_VERSION` | Fluss release tag (set by `default.env.sh --fluss-version`) |
| `FLUSS_IMAGE_TAG` | Image tag used by Helm deploy (same as `FLUSS_VERSION`) |
| `FLUSS_IMAGE_REPO` | ECR repo URL without tag (from `default.env.sh`) |

## Step 1: Update Kubeconfig

After Terraform deployment, update your kubeconfig to connect to the EKS cluster:

```bash
cd e2e-iot/high-infra/terraform
aws eks update-kubeconfig --region us-west-2 --name fluss-eks-cluster

# Verify connection
kubectl cluster-info
```

## Step 2: Setup Local NVMe Storage (for Tablet Servers)

Configure local NVMe storage for Fluss tablet servers:

```bash
cd e2e-iot/high-infra/k8s/storage
./setup-local-storage.sh
```

This script:
- Creates a `local-storage` StorageClass
- Creates PersistentVolumes for tablet servers (3 PVs, 500Gi each)
- Configures node affinity to tablet-server nodes

**Verify:**
```bash
kubectl get storageclass local-storage
kubectl get pv -l component=tablet-server
```

## Step 3: Deploy All Components

Deploy ZooKeeper, Fluss, Flink, and Monitoring stack:

```bash
cd e2e-iot/high-infra/k8s

# Deploy with ECR images (default.env.sh must already be sourced)
./deploy.sh fluss "${DEMO_IMAGE_REPO}" "${DEMO_IMAGE_TAG}" "${FLUSS_IMAGE_REPO}"
```

**What gets deployed:**
1. **Namespace**: Creates `fluss` namespace
2. **ZooKeeper**: StatefulSet with 1 replica
3. **Fluss**: 
   - Coordinator (1 replica)
   - Tablet Servers (3 replicas)
   - Uses ECR image: `343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss:latest`
4. **Flink**:
   - JobManager (1 replica)
   - TaskManager (2 replicas)
   - Uses ECR image: `343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo:latest`
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

## Step 4: Deploy Multi-Instance Producer Job

Deploy 8 producer instances (2 per node across 4 producer nodes) with 128 buckets:

### Option 1: Use Multi-Instance Script (Recommended)

```bash
cd e2e-iot/high-infra/k8s/jobs

# Deploy 8 producer instances with 128 buckets
export BUCKETS=128
./deploy-producer-multi-instance.sh --wait
```

**Multi-Instance Configuration (defaults):**
- **Total Instances**: 8 (instance IDs 0-7)
- **Distribution**: 2 pods per producer node (4 nodes total)
- **Rate per instance**: 250,000 records/second
- **Total rate**: 2,000,000 records/second
- **Flush**: Every 5,000 records (optimal for throughput)
- **Batch Timeout**: 90ms (optimal for batching)
- **Buffer Size**: 2gb
- **Batch Size**: 128mb
- **Memory**: 4Gi request, 16Gi limit per instance
- **CPU**: 2000m request, 8000m limit per instance
- **Writer Threads**: 48 per instance
- **Buckets**: 128 (must match table bucket count)

**Customize if needed:**
```bash
./deploy-producer-optimal.sh \
  --rate 200000 \
  --flush 5000 \
  --batch-timeout 90ms
```

### Option 2: Use Multi-Instance Script with Custom Parameters

```bash
cd e2e-iot/high-infra/k8s/jobs

# Deploy 8 producer instances with custom parameters
export BUCKETS=128
export PRODUCER_RATE=250000
export TOTAL_PRODUCERS=8
./deploy-producer-multi-instance.sh --wait
```

**Configuration:**
- **Image**: `343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo:latest`
- **JAR Path**: `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
- **Rate per instance**: 250,000 records/second (default, customizable)
- **Total rate**: 2,000,000 records/second (8 instances × 250K)
- **Flush**: Every 5,000 records (optimal for throughput)
- **Batch Timeout**: 90ms (optimal for batching)
- **Buckets**: 128 (must match table bucket count)
- **Nodes**: Runs on `producer` node group (c5.2xlarge), 2 pods per node

**Note**: See `k8s/jobs/PRODUCER_CONFIG.md` for detailed configuration options and performance tuning guidelines.

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

## Step 5: Submit Flink Aggregator Job

Submit the Flink job that processes sensor data:

```bash
cd e2e-iot/high-infra/k8s/flink
./submit-job-from-image.sh
```

**What this script does:**
1. Cancels any existing Flink jobs
2. Verifies JAR exists in Flink image at `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
3. Uploads JAR from the image's local filesystem to Flink cluster
4. Submits job via REST API with:
   - Entry class: `org.apache.fluss.benchmarks.flink.FlinkSensorAggregatorJob`
   - Parallelism: 32
   - Window: 1 minute
   - **Scan mode**: `latest` (reads from latest position, not from beginning)

**Note**: The JAR is embedded in the Flink image (`343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo:latest`), so no local file upload is needed. The script uses the JAR from the ECR image.

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

## Step 6: Deploy Grafana Dashboard

Deploy the Grafana dashboard for monitoring:

```bash
cd e2e-iot/high-infra/k8s/monitoring
./deploy-dashboard.sh
```

**Access Grafana:**
```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Then visit: http://localhost:3000
# Username: admin
# Password: admin123
```

**Dashboard includes:**
- Producer metrics (records/sec, latency)
- Flink metrics (input/output rates, aggregator records)
- Fluss Coordinator metrics (cluster status, table/bucket counts)
- Fluss Tablet Server metrics (messages rate, bytes rate, replication)
- JVM metrics (CPU, memory for coordinator and tablet servers)

## Step 7: Verify Deployment

### Check All Pods

```bash
# Fluss namespace
kubectl get pods -n fluss

# Expected:
# - zk-0: Running
# - coordinator-server-0: Running
# - tablet-server-0, tablet-server-1, tablet-server-2: Running
# - flink-jobmanager-*: Running
# - flink-taskmanager-0, flink-taskmanager-1: Running
# - fluss-producer-*: Running

# Monitoring namespace
kubectl get pods -n monitoring
```

### Check Node Placement

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

### Verify Metrics Scraping

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

### Verify Data Flow

```bash
# Check producer is writing data
kubectl logs -n fluss -l app=fluss-producer --tail=50 | grep -i "records\|throughput"

# Check Flink is processing data
kubectl logs -n fluss -l app=flink,component=taskmanager --tail=50 | grep -i "aggregate\|records"

# Check Fluss tablet servers are receiving data
kubectl logs -n fluss -l app.kubernetes.io/component=tablet-server --tail=20
```

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
  cd e2e-iot/high-infra/k8s/flink
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

## Quick Reference Commands

### Access Services

```bash
# Flink Web UI
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081

# Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Producer Metrics
kubectl port-forward -n fluss svc/fluss-producer-metrics 8080:8080
```

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
cd e2e-iot/high-infra/k8s/jobs
./deploy-producer-optimal.sh

# Restart Flink job
cd e2e-iot/high-infra/k8s/flink
./submit-job-from-image.sh
```

## Cleanup

To remove all deployed components (but keep infrastructure):

```bash
# Delete producer job
kubectl delete job -n fluss fluss-producer

# Delete Flink job (via REST API or UI)
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
# Visit http://localhost:8081 and cancel job

# Delete all components
cd e2e-iot/high-infra/k8s
kubectl delete -f flink/
kubectl delete -f zookeeper/
helm uninstall fluss -n fluss
helm uninstall prometheus -n monitoring
kubectl delete namespace fluss monitoring
```

## Notes

- **ECR Images**: Ensure images are pushed to ECR before deployment
- **Storage**: Local NVMe storage setup is required for tablet servers if using persistence
- **Node Types**: All components are configured to run on specific node groups:
  - Coordinator: c5.2xlarge
  - Tablet Servers: i7i.8xlarge (with NVMe)
  - Flink JobManager: c5.4xlarge
  - Flink TaskManager: c5.4xlarge
  - Producer: c5.2xlarge
- **Parallelism**: Flink job is configured with parallelism 32 (16 slots per TaskManager × 2 TaskManagers)
- **Scan Mode**: Flink job reads from `latest` position (configured via SQL hint `scan.startup.mode = 'latest'`), meaning it only processes new data and doesn't read historical data from the beginning

