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


# AWS Fluss Deployment with Terraform

This directory contains Terraform configurations to deploy Fluss, producer, and Flink consumer on AWS EKS.

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Terraform** >= 1.0
3. **kubectl** configured to access your EKS cluster
4. **Helm** >= 3.0
5. An existing **EKS cluster** (or uncomment EKS module in `main.tf`)

## Directory Structure

```
low-infra/
├── terraform/           # Terraform configurations
│   ├── main.tf         # Main Terraform configuration
│   ├── variables.tf    # Variable definitions
│   ├── outputs.tf      # Output values
│   ├── zookeeper.tf    # ZooKeeper deployment
│   ├── fluss.tf        # Fluss Helm deployment
│   ├── jobs.tf         # Producer and Flink consumer jobs
│   ├── ecr.tf          # ECR repository for demo app
│   └── terraform.tfvars.example
├── helm-charts/        # Benchmark-specific Helm values (official chart from Apache Fluss repo)
│   └── fluss-values.yaml
└── manifests/          # Additional Kubernetes manifests (if needed)
```

## Setup

### 1. Configure Terraform Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

**Important**: Configure the following for EC2 instances:
- `subnet_ids`: List of private subnet IDs where EC2 instances will be launched
- `security_group_ids`: (Optional) Additional security groups for EC2 instances
- `key_name`: (Optional) SSH key pair name for EC2 access
- Instance types and counts for coordinator and tablet servers

### 2. Build and Push Images to ECR

Set the Fluss version first (`--fluss-version` is required), then push images. Push scripts read `FLUSS_VERSION` from the environment.

```bash
cd e2e-iot

# Make sure AWS CLI is configured
aws configure

source ./default.env.sh --fluss-version 0.9.0-incubating
./push-images-to-ecr.sh --all
```

This script will:
1. Create ECR repositories (if they don't exist)
2. Build the demo application image (`fluss-demo`) with Maven dependencies matching `FLUSS_VERSION`
3. Push demo image to ECR
4. Pull `apache/fluss:${FLUSS_VERSION}` from Docker Hub
5. Push Fluss image to ECR as `:${FLUSS_VERSION}` and `:latest`

`default.env.sh` exports `FLUSS_VERSION`, `FLUSS_IMAGE_REPO`, `FLUSS_IMAGE_TAG`, and other deploy defaults. Update `terraform/terraform.tfvars` `fluss_version` to match.

Alternatively, push only the Fluss image:

```bash
source ./default.env.sh --fluss-version 0.9.0-incubating
./push-images-to-ecr.sh --fluss-only
```

Manual pull/push (replace `VERSION` with your tag, e.g. `0.9.0-incubating`):

```bash
VERSION=0.9.0-incubating
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_BASE}

docker pull apache/fluss:${VERSION}
docker tag apache/fluss:${VERSION} ${ECR_BASE}/fluss:${VERSION}
docker tag apache/fluss:${VERSION} ${ECR_BASE}/fluss:latest
docker push ${ECR_BASE}/fluss:${VERSION}
docker push ${ECR_BASE}/fluss:latest
```

### 3. Initialize Terraform

```bash
cd terraform
terraform init
```

### 4. Plan Deployment

```bash
terraform plan
```

### 5. Apply Configuration

```bash
terraform apply
```

## What Gets Deployed

1. **ECR Repositories**: 
   - `fluss-demo`: For demo application (used by producer and Flink aggregator)
   - `fluss`: For Apache Fluss image
2. **EBS CSI Driver** (if `install_ebs_csi_driver = true`):
   - EKS addon for gp3 PersistentVolume support
   - IAM role with required permissions
   - Required if `enable_persistence = true`
3. **EC2 Instances** (Dedicated nodes):
   - Coordinator nodes: Labeled with `fluss-component=coordinator`
   - Tablet server nodes: Labeled with `fluss-component=tablet-server`
   - Each instance type and count is configurable
   - Root volumes: gp3, 100GB for tablet servers, 50GB for coordinators
4. **IAM Roles**: 
   - For EC2 instances to join EKS cluster
   - For EBS CSI driver (if installed)
5. **Kubernetes Namespace**: `fluss` namespace
6. **ZooKeeper**: StatefulSet with headless service
7. **Fluss**: Deployed via Helm chart
   - Coordinator server (StatefulSet) - scheduled on coordinator nodes only
   - Tablet servers (StatefulSet) - scheduled on tablet-server nodes only
   - Services and ConfigMaps
   - Uses ECR image if `use_ecr_for_fluss = true`
   - Node selectors ensure pods run on dedicated nodes
8. **Producer Job**: Kubernetes Job that writes sensor data to Fluss
9. **Flink Aggregator Job**: Kubernetes Job that processes and aggregates data

## Configuration

### Fluss Configuration

Deployments use the **official Apache Fluss Helm chart** from `https://downloads.apache.org/incubator/fluss/helm-chart` (see `k8s/deploy.sh`). Benchmark-specific overrides live in `helm-charts/fluss-values.yaml`. Key settings:

- **Persistence**: 
  - `enable_persistence = false`: Tablet servers write to `/tmp/fluss/data` on the EC2 root volume (gp3)
  - `enable_persistence = true`: Creates separate EBS volumes (PersistentVolumes) for each tablet server pod
- **Replicas**: Number of coordinator and tablet server replicas
- **Storage**: Storage class and size for persistent volumes (only used if `enable_persistence = true`)
- **ZooKeeper**: Connection to ZooKeeper service

**Note**: 
- With `enable_persistence = false`, tablet servers use the root gp3 volume of the EC2 instances. The root volume is configured with 100GB for tablet servers and 50GB for coordinators.
- The EBS CSI driver is automatically installed by Terraform (if `install_ebs_csi_driver = true`) to support gp3 PersistentVolumes. This is required if you enable persistence later.

### Jobs Configuration

The producer and Flink aggregator jobs are configured in `jobs.tf`:

- **Producer**: Writes sensor data at configurable rate
- **Flink Aggregator**: Processes data with 1-minute windows

## Accessing Fluss

After deployment, you can access Fluss coordinator:

```bash
# Port forward to coordinator
kubectl port-forward -n fluss svc/coordinator-server-hs 9124:9124

# In another terminal, test connection
java -cp target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmarks.inspect.FlussMetadataInspector localhost:9124
```

## Monitoring

Check pod status:

```bash
kubectl get pods -n fluss
```

View logs:

```bash
# Producer logs
kubectl logs -n fluss -l app=fluss-producer --tail=50 -f

# Flink aggregator logs
kubectl logs -n fluss -l app=flink-aggregator --tail=50 -f

# Fluss coordinator logs
kubectl logs -n fluss coordinator-server-0 --tail=50 -f
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Note**: This will delete:
- ECR repository and all images
- All Kubernetes resources (Fluss, ZooKeeper, Jobs)
- Namespace

## Troubleshooting

### Jobs Not Starting

1. Check if Fluss coordinator is ready:
   ```bash
   kubectl get pods -n fluss
   kubectl logs -n fluss coordinator-server-0
   ```

2. Verify image is accessible:
   ```bash
   kubectl describe job -n fluss fluss-producer
   ```

3. Check init container logs:
   ```bash
   kubectl logs -n fluss <pod-name> -c wait-for-fluss
   ```

### Image Pull Errors

Ensure:
1. ECR repository exists and image is pushed
2. EKS nodes have IAM role with ECR read permissions
3. Image tag matches `demo_image_tag` in `terraform.tfvars`

### Fluss Not Starting

1. Check ZooKeeper is running:
   ```bash
   kubectl get pods -n fluss -l app=zookeeper
   ```

2. Check Fluss logs:
   ```bash
   kubectl logs -n fluss coordinator-server-0
   kubectl logs -n fluss tablet-server-0
   ```

## Customization

### Add EKS Cluster Creation

If you need to create the EKS cluster, uncomment and configure the EKS module in `main.tf` or add:

```hcl
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # ... configuration
}
```

### Modify Resource Limits

Edit `jobs.tf` to adjust CPU/memory requests and limits for producer and aggregator jobs.

### Change Fluss Configuration

Modify `helm-charts/fluss-values.yaml` or add additional values in `fluss.tf`.

### Node Scheduling

The Helm chart is configured with node selectors and affinity rules:
- **Coordinator pods** will only run on nodes labeled with `fluss-component=coordinator`
- **Tablet server pods** will only run on nodes labeled with `fluss-component=tablet-server`
- Coordinator nodes have a taint (`NoSchedule`) to prevent other pods from running on them

This ensures:
- Coordinator runs on dedicated EC2 instances
- Tablet servers run on dedicated EC2 instances
- No resource contention between components

### EC2 Instance Configuration

Edit `nodes.tf` or set variables in `terraform.tfvars`:
- `coordinator_instance_type`: EC2 instance type for coordinator (default: t3.medium)
- `tablet_server_instance_type`: EC2 instance type for tablet servers (default: t3.medium)
- `coordinator_instance_count`: Number of coordinator instances (default: 1)
- `tablet_server_instance_count`: Number of tablet server instances (default: 3)
- `subnet_ids`: List of subnet IDs where instances will be launched (required)
- `key_name`: SSH key pair name for EC2 access (optional)
- `security_group_ids`: Additional security groups (optional)

