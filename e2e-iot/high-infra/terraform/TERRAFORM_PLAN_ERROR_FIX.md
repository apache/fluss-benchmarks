# Terraform Plan Error Fix - Kubernetes Provider Connection

## Issue

When running `terraform plan` for the first time (before EKS cluster exists), you may see errors like:

```
Error: Get "http://localhost/api/v1/namespaces/fluss": dial tcp [::1]:80: connect: connection refused
Error: Get "http://localhost/api/v1/namespaces/kube-system/configmaps/aws-auth": dial tcp [::1]:80: connect: connection refused
```

## Root Cause

Terraform tries to validate the Kubernetes provider configuration during the `plan` phase. Since the EKS cluster doesn't exist yet, `module.eks.cluster_endpoint` is unknown, and Terraform may default to `localhost`, causing connection errors.

## Solution

The configuration has been updated to:

1. **Added `depends_on` to Kubernetes resources** - Ensures resources wait for EKS cluster to be created
2. **Added `null_resource` wait** - Waits for cluster to be fully active before creating Kubernetes resources

## Workaround for First-Time Deployment

### Option 1: Proceed with Apply (Recommended)

Even if `terraform plan` shows Kubernetes connection errors, you can proceed with `terraform apply`. The errors are expected during plan when the cluster doesn't exist yet. During apply:

1. EKS cluster will be created first
2. `null_resource.wait_for_cluster` will wait for cluster to be ready
3. Kubernetes resources will be created after cluster is ready

**Command:**
```bash
# Plan will show errors, but proceed anyway
terraform plan -out=tfplan

# Apply will work correctly
terraform apply tfplan
```

### Option 2: Two-Phase Deployment

If you want to avoid plan errors, deploy in two phases:

**Phase 1: Create EKS Cluster Only**
```bash
# Comment out Kubernetes resources temporarily in s3_flink_checkpoints.tf
# Then run:
terraform apply -target=module.eks
```

**Phase 2: Create Kubernetes Resources**
```bash
# Uncomment Kubernetes resources
# Then run:
terraform apply
```

### Option 3: Use `-target` Flag

Target only AWS resources first, then Kubernetes resources:

```bash
# First, create EKS cluster and AWS resources
terraform apply -target=module.eks -target=module.vpc -target=aws_s3_bucket.flink_state

# Then create Kubernetes resources
terraform apply
```

## Fixed Configuration

The following changes were made:

1. **Added `null_resource.wait_for_cluster`** - Waits for EKS cluster to be active
2. **Updated `kubernetes_namespace.fluss` dependencies** - Now depends on cluster readiness
3. **Added proper dependency chain** - Ensures correct order of resource creation

## Verification

After successful deployment, verify:

```bash
# Check cluster status
aws eks describe-cluster --name <cluster-name> --region us-west-2 --query 'cluster.status'

# Check Kubernetes namespace
kubectl get namespace fluss

# Check Terraform state
terraform state list
```

## Notes

- **Warnings about deprecated `inline_policy`** - These are warnings from the EKS module, not errors. They can be ignored or will be fixed in future module versions.
- **First-time deployment** - Expect Kubernetes connection errors during plan on first deployment
- **Subsequent plans** - After cluster exists, plan should work without errors

## Related Files

- `s3_flink_checkpoints.tf` - Contains Kubernetes namespace and service account resources
- `main.tf` - Contains Kubernetes provider configuration
- `eks_cluster.tf` - Contains EKS cluster module

