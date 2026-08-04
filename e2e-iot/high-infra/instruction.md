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


# Deployment Instructions

## ⚠️ IMPORTANT: Read Before Deployment

**Before starting any deployment, you MUST review the following documentation:**

1. **[DEPLOY-STEPS.md](./DEPLOY-STEPS.md)** - Complete step-by-step deployment guide
2. **[DEPLOYMENT_FIXES.md](./DEPLOYMENT_FIXES.md)** - Known issues and fixes applied
3. **[k8s/DEPLOYMENT.md](./k8s/DEPLOYMENT.md)** - Detailed Kubernetes deployment guide with NVMe storage verification and multi-instance producer setup

These documents contain critical information about:
- Prerequisites and setup requirements
- Step-by-step deployment procedures
- Common issues and their solutions
- Configuration requirements
- Troubleshooting steps

## Quick Start

If you're familiar with the deployment process, you can proceed directly to:

```bash
cd k8s
./deploy.sh <namespace> <demo-image-repo> <demo-image-tag> <fluss-image-repo>
```

However, **it is strongly recommended** to review the documentation files above, especially:
- If this is your first deployment
- If you're deploying after infrastructure changes
- If you encounter any issues during deployment
- If you're updating configurations

## Documentation Files

### DEPLOY-STEPS.md
Contains:
- Prerequisites checklist
- Complete deployment steps
- Post-deployment verification
- Monitoring setup
- Troubleshooting guide

### DEPLOYMENT_FIXES.md
Contains:
- Known issues and their fixes
- Workarounds for common problems
- Configuration changes applied
- Best practices learned from previous deployments

### k8s/DEPLOYMENT.md
Contains:
- **NVMe storage verification steps** (critical for tablet servers)
- **Multi-instance producer deployment** (8 instances, 2 per node)
- **Flink job deployment with S3 checkpoints**
- Detailed Kubernetes resource verification
- Service access instructions (Flink UI, Grafana, Prometheus)
- Architecture overview
- Comprehensive troubleshooting guide

## Additional Resources
- **[MONITORING.md](./MONITORING.md)** - Monitoring setup and configuration
- **[k8s/jobs/PRODUCER_CONFIG.md](./k8s/jobs/PRODUCER_CONFIG.md)** - Producer optimal configuration and performance tuning
- **[README.md](./README.md)** - General overview and architecture

## Deployment Checklist

Before deploying, ensure:

- [ ] Reviewed `DEPLOY-STEPS.md` for prerequisites
- [ ] Reviewed `DEPLOYMENT_FIXES.md` for known issues
- [ ] Reviewed `k8s/DEPLOYMENT.md` for NVMe storage and multi-instance producer setup
- [ ] Terraform infrastructure is deployed
- [ ] ECR images are built and pushed
- [ ] `kubectl` is configured for the EKS cluster
- [ ] `helm` is installed
- [ ] All required environment variables are set

## Critical Post-Deployment Steps

After deploying Fluss components, **MUST verify** (see **[k8s/DEPLOYMENT.md](./k8s/DEPLOYMENT.md)** for detailed steps):

1. **NVMe Storage Verification** (Step 4 in k8s/DEPLOYMENT.md):
   - Verify tablet server PersistentVolumes are using NVMe paths (`/opt/alldata/fluss/data`)
   - Check tablet server pods have volumes mounted correctly
   - Confirm NVMe drives are mounted on tablet server nodes
   - **Reference:** See `k8s/DEPLOYMENT.md` Step 4 for complete verification commands

2. **Multi-Instance Producer Deployment** (Step 5 in k8s/DEPLOYMENT.md):
   - Deploy using `k8s/jobs/deploy-producer-multi-instance.sh` with 96 buckets
   - Verify 8 producer instances are running (2 per node across 4 nodes)
   - Table must be created with 96 buckets before deploying producers
   - Check producer metrics and throughput
   - **Reference:** See `k8s/DEPLOYMENT.md` Step 5 for deployment and verification

3. **Flink Job Deployment** (Step 6 in k8s/DEPLOYMENT.md):
   - Submit Flink job using `k8s/flink/submit-job-from-image.sh`
   - Verify S3 checkpoints are configured automatically
   - Check Flink job is running and processing data
   - **Reference:** See `k8s/DEPLOYMENT.md` Step 6 for S3 checkpoint verification

## Getting Help

If you encounter issues:
1. Check `DEPLOYMENT_FIXES.md` for known issues
2. Review deployment logs in `k8s/deploy-*.log`
3. Check pod logs: `kubectl logs -n fluss <pod-name>`
4. Verify configuration matches `DEPLOY-STEPS.md`

---

**Remember**: Always refer to `DEPLOY-STEPS.md`, `DEPLOYMENT_FIXES.md`, and `k8s/DEPLOYMENT.md` before deployment to avoid common pitfalls and ensure a smooth deployment process. The `k8s/DEPLOYMENT.md` file contains critical information about NVMe storage verification and multi-instance producer deployment.

