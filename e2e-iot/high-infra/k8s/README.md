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


# Kubernetes Deployment for Fluss + Flink

This directory contains Kubernetes YAML manifests for deploying Fluss, Flink, and related components.

## Structure

```
k8s/
├── namespace/          # Namespace definition
├── zookeeper/         # ZooKeeper StatefulSet and Service
├── flink/             # Flink cluster (JobManager + TaskManagers)
├── jobs/              # Producer and Flink aggregator jobs
├── monitoring/        # Monitoring resources (Prometheus/Grafana)
└── deploy.sh          # Deployment script
```

## Prerequisites

1. EKS cluster created via Terraform (see `../terraform/`)
2. `kubectl` configured to access the cluster
3. `helm` installed
4. Docker images pushed to ECR for your Fluss version (default `0.9.0-incubating`)

### Fluss version

Push and deploy must use the same version:

```bash
cd e2e-iot
source ./default.env.sh --fluss-version 0.9.0-incubating
./push-images-to-ecr.sh --all
```

`deploy.sh` uses `FLUSS_IMAGE_TAG` (from `FLUSS_VERSION`) when `FLUSS_IMAGE_REPO` has no inline tag.

## Deployment

### Quick Deploy

```bash
cd e2e-iot
source ./default.env.sh --fluss-version 0.9.0-incubating
cd high-infra/k8s
./deploy.sh fluss "${DEMO_IMAGE_REPO}" "${DEMO_IMAGE_TAG}" "${FLUSS_IMAGE_REPO}"
```

Example (manual values after sourcing default.env.sh):
```bash
./deploy.sh fluss \
  123456789012.dkr.ecr.us-west-2.amazonaws.com/fluss-demo \
  latest \
  123456789012.dkr.ecr.us-west-2.amazonaws.com/fluss
```

### Manual Deploy

1. **Create namespace:**
   ```bash
   kubectl apply -f namespace/namespace.yaml
   ```

2. **Deploy ZooKeeper:**
   ```bash
   kubectl apply -f zookeeper/zookeeper.yaml
   kubectl wait --for=condition=ready pod -l app=zookeeper -n fluss --timeout=120s
   ```

3. **Deploy Fluss via Helm** (official chart from Apache Fluss):
   ```bash
   helm repo add fluss https://downloads.apache.org/incubator/fluss/helm-chart
   helm repo update
   helm upgrade --install fluss fluss/fluss \
     --version 0.9.0-incubating \
     --namespace fluss \
     --set image.repository="<fluss-image-repo>" \
     --set image.tag="<fluss-image-tag>" \
     --set configurationOverrides."zookeeper\.address"="zk-svc.fluss.svc.cluster.local:2181"
   ```

4. **Deploy Flink cluster:**
   ```bash
   kubectl apply -f flink/flink-config.yaml
   kubectl apply -f flink/flink-jobmanager.yaml
   kubectl apply -f flink/flink-taskmanager.yaml
   ```

5. **Deploy monitoring:**
   ```bash
   kubectl create namespace monitoring
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
     --version 55.5.0 \
     --namespace monitoring \
     --set grafana.enabled=true \
     --set grafana.adminUser=admin \
     --set grafana.adminPassword=admin123 \
     --set grafana.service.type=LoadBalancer
   ```

6. **Deploy jobs (with image substitution):**
   ```bash
   export DEMO_IMAGE_REPO="<demo-image-repo>"
   export DEMO_IMAGE_TAG="<demo-image-tag>"
   # Deploy producer job (standalone)
   envsubst < jobs/producer-job.yaml | kubectl apply -f -
   # Submit Flink aggregator job to Flink cluster
   envsubst < flink/flink-job-submission-simple.yaml | kubectl apply -f -
   ```

## Flink Cluster

The Flink cluster consists of:
- **JobManager**: 1 replica (Deployment)
- **TaskManagers**: 2 replicas (StatefulSet)
- **Image**: `apache/flink:1.20.3-scala_2.12-java17`

### Access Flink Web UI

```bash
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
```

Then open http://localhost:8081

### Submit Flink Job

The Flink aggregator job is automatically submitted to the Flink cluster via the `flink-job-submission-simple.yaml` job.

To manually submit a job:

```bash
# Method 1: Use the job submission job (recommended)
export DEMO_IMAGE_REPO="<demo-image-repo>"
export DEMO_IMAGE_TAG="<demo-image-tag>"
envsubst < flink/flink-job-submission-simple.yaml | kubectl apply -f -

# Method 2: Use Flink CLI directly
FLINK_JM_POD=$(kubectl get pod -n fluss -l component=jobmanager -o jsonpath='{.items[0].metadata.name}')

# Copy JAR to pod
kubectl cp /path/to/fluss-flink-realtime-demo.jar $FLINK_JM_POD:/tmp/job.jar -n fluss

# Submit job via Flink CLI
kubectl exec -n fluss $FLINK_JM_POD -- \
  /opt/flink/bin/flink run \
  -m flink-jobmanager:6123 \
  -c org.apache.fluss.benchmarks.flink.FlinkSensorAggregatorJob \
  /tmp/job.jar \
  --bootstrap coordinator-server-hs.fluss.svc.cluster.local:9124 \
  --database iot \
  --table sensor_readings \
  --window-minutes 1

# Method 3: Use Flink REST API
JOBMANAGER="flink-jobmanager.fluss.svc.cluster.local:8081"

# Upload JAR
JAR_ID=$(curl -s -X POST \
  "http://${JOBMANAGER}/v1/jars/upload" \
  -H "Content-Type: multipart/form-data" \
  -F "jarfile=@/path/to/fluss-flink-realtime-demo.jar" \
  | jq -r '.filename' | sed 's|.*/||')

# Submit job
curl -X POST \
  "http://${JOBMANAGER}/v1/jars/${JAR_ID}/run" \
  -H "Content-Type: application/json" \
  -d '{
    "entryClass": "org.apache.fluss.benchmarks.flink.FlinkSensorAggregatorJob",
    "programArgs": "--bootstrap coordinator-server-hs.fluss.svc.cluster.local:9124 --database iot --table sensor_readings --window-minutes 1",
    "parallelism": 2
  }'
```

## Monitoring

### Access Grafana

```bash
# Get Grafana LoadBalancer URL
kubectl get svc -n monitoring | grep grafana

# Or port-forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

Default credentials:
- Username: `admin`
- Password: `admin123`

### Prometheus Metrics

All components expose Prometheus metrics:
- **Producer**: Port 8080, path `/metrics`
- **Flink Aggregator**: Port 9249, path `/metrics`
- **Flink JobManager**: Port 9249, path `/metrics`
- **Flink TaskManagers**: Port 9249, path `/metrics`
- **Fluss Servers**: Port 9249, path `/metrics`

## Troubleshooting

### Check pod status:
```bash
kubectl get pods -n fluss
kubectl get pods -n monitoring
```

### View logs:
```bash
kubectl logs -n fluss <pod-name>
kubectl logs -n fluss -l app=fluss-producer --tail=50 -f
kubectl logs -n fluss -l app=flink-aggregator --tail=50 -f
```

### Check services:
```bash
kubectl get svc -n fluss
kubectl get svc -n monitoring
```

