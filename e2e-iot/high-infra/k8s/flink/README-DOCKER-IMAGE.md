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


# Flink Job with Embedded JAR

This approach embeds the Flink job JAR directly in the Docker image for `local://` submission from the Flink cluster.

## Workflow

1. **Build and Push Image**: The JAR is built and embedded in a Flink Docker image, then pushed to ECR
2. **Deploy Flink Cluster**: Flink JobManager and TaskManager use the custom image (which contains the JAR)
3. **Submit Job**: Use Flink CLI with `local://` path to reference the JAR in the image

## Files

- `Dockerfile.simple` - Dockerfile that embeds JAR in Flink image
- `build-and-push.sh` - Script to build JAR, create Docker image, and push to ECR
- `submit-job-local.sh` - Script to submit job using Flink CLI with `local://` path
- `flink-jobmanager.yaml` - Updated to use custom image
- `flink-taskmanager.yaml` - Updated to use custom image

## Usage

### 1. Build and Push Image

```bash
cd e2e-iot/high-infra/k8s/flink
./build-and-push.sh
```

This will:
- Build the JAR from `e2e-iot/fluss_flink_realtime`
- Create Docker image with JAR at `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
- Push to ECR: `343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo:latest`

### 2. Deploy/Update Flink Cluster

The Flink deployments are already configured to use the custom image:

```bash
kubectl apply -f flink-jobmanager.yaml
kubectl apply -f flink-taskmanager.yaml
```

### 3. Submit Job

```bash
./submit-job-local.sh
```

This uses Flink CLI to submit the job with `local:///opt/flink/usrlib/fluss-flink-realtime-demo.jar`

## Benefits

- ✅ No manual JAR upload needed
- ✅ JAR is versioned with Docker image
- ✅ Cleaner than REST API approach
- ✅ Works with standard Flink deployments (no operator needed)
- ✅ JAR is always available in the cluster

## Differences from Operator Approach

- Uses standard Flink deployments (Deployment/StatefulSet) instead of FlinkDeployment CRD
- Job submission is manual via Flink CLI, not automatic
- More control over when jobs are submitted

