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


# Flink Cluster Deployment

This directory contains Kubernetes manifests for deploying a Flink cluster with proper node placement.

## Architecture

- **1 JobManager**: Runs on a dedicated node labeled `flink-component=jobmanager`
- **2 TaskManagers**: Each runs on a separate node labeled `flink-component=taskmanager`
- **Node Affinity**: Ensures pods are scheduled on the correct node types
- **Pod Anti-Affinity**: Ensures TaskManagers are distributed across different nodes

## Node Groups

The Flink cluster requires dedicated node groups created via Terraform:

1. **flink-jobmanager**: 1 node (t3.medium)
   - Label: `flink-component=jobmanager`
   - Taint: `flink-component=jobmanager:NoSchedule`

2. **flink-taskmanager**: 2 nodes (t3.medium each)
   - Label: `flink-component=taskmanager`
   - Taint: `flink-component=taskmanager:NoSchedule`

## Deployment Order

1. **Deploy Flink ConfigMap:**
   ```bash
   kubectl apply -f flink-config.yaml
   ```

2. **Deploy JobManager:**
   ```bash
   kubectl apply -f flink-jobmanager.yaml
   ```

3. **Deploy TaskManagers:**
   ```bash
   kubectl apply -f flink-taskmanager.yaml
   ```

4. **Verify deployment:**
   ```bash
   kubectl get pods -n fluss -l app=flink
   kubectl get nodes -l flink-component
   ```

5. **Submit Flink job:**
   ```bash
   export DEMO_IMAGE_REPO="<your-image-repo>"
   export DEMO_IMAGE_TAG="<your-image-tag>"
   envsubst < flink-job-submission-simple.yaml | kubectl apply -f -
   ```

## Verifying Node Placement

```bash
# Check which nodes Flink pods are running on
kubectl get pods -n fluss -l app=flink -o wide

# Verify JobManager is on jobmanager node
kubectl get pod -n fluss -l component=jobmanager -o jsonpath='{.items[0].spec.nodeName}'
kubectl get node $(kubectl get pod -n fluss -l component=jobmanager -o jsonpath='{.items[0].spec.nodeName}') --show-labels

# Verify TaskManagers are on different nodes
kubectl get pods -n fluss -l component=taskmanager -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'
```

## Accessing Flink Web UI

```bash
kubectl port-forward -n fluss svc/flink-jobmanager 8081:8081
```

Then open http://localhost:8081

## Job Submission

The Flink job is submitted via REST API using the `flink-job-submission-simple.yaml` job. This job:

1. Waits for Flink JobManager to be ready
2. Waits for Fluss coordinator to be ready
3. Waits for producer to create the database
4. Uploads the JAR to Flink cluster
5. Submits the job with proper arguments

Check job submission status:
```bash
kubectl logs -n fluss -l app=flink-job-submission --tail=50
```

Check running jobs in Flink Web UI or via REST API:
```bash
curl http://localhost:8081/jobs
```

