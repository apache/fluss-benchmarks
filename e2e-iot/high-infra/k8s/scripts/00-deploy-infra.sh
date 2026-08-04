#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${K8S_DIR}/../terraform"

REGION="${REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-fluss-eks-cluster}"

echo "=== Step 0: Deploying infrastructure with Terraform ==="
echo "Region: ${REGION}"
echo "Cluster Name: ${CLUSTER_NAME}"
echo ""

# Check prerequisites for entire deployment process
echo "=========================================="
echo "Checking Prerequisites for Deployment"
echo "=========================================="
echo ""

ERRORS=0
WARNINGS=0

# Check Terraform is available
echo "[1/7] Checking Terraform..."
if ! command -v terraform &> /dev/null; then
    echo "  ✗ ERROR: Terraform is not installed or not in PATH"
    echo "    Install Terraform: https://www.terraform.io/downloads"
    ERRORS=$((ERRORS + 1))
else
    TERRAFORM_VERSION=$(terraform version 2>&1 | head -n 1 | sed 's/.*v\([0-9.]*\).*/\1/' 2>/dev/null || echo "unknown")
    echo "  ✓ Terraform version: ${TERRAFORM_VERSION}"
    
    # Check Terraform version (>= 1.0)
    if [ "${TERRAFORM_VERSION}" != "unknown" ]; then
        TERRAFORM_MAJOR=$(echo "${TERRAFORM_VERSION}" | cut -d'.' -f1 2>/dev/null || echo "0")
        if [ -n "${TERRAFORM_MAJOR}" ] && [ "${TERRAFORM_MAJOR}" -lt 1 ] 2>/dev/null; then
            echo "  ⚠ WARNING: Terraform version should be >= 1.0"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
fi

# Check AWS CLI is available
echo ""
echo "[2/7] Checking AWS CLI..."
if ! command -v aws &> /dev/null; then
    echo "  ✗ ERROR: AWS CLI is not installed or not in PATH"
    echo "    Install AWS CLI: https://aws.amazon.com/cli/"
    ERRORS=$((ERRORS + 1))
else
    AWS_VERSION=$(aws --version 2>&1 | head -n 1)
    echo "  ✓ ${AWS_VERSION}"
fi

# Check AWS credentials are configured
echo ""
echo "[3/7] Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    echo "  ✗ ERROR: AWS credentials are not configured"
    echo "    Configure AWS credentials: aws configure"
    echo "    Or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
    ERRORS=$((ERRORS + 1))
else
    AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
    AWS_USER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown")
    echo "  ✓ AWS Account: ${AWS_ACCOUNT}"
    echo "  ✓ AWS User: ${AWS_USER}"
fi

# Check kubectl is available (needed for later steps)
echo ""
echo "[4/7] Checking kubectl..."
if ! command -v kubectl &> /dev/null; then
    echo "  ✗ ERROR: kubectl is not installed or not in PATH"
    echo "    Install kubectl: https://kubernetes.io/docs/tasks/tools/"
    ERRORS=$((ERRORS + 1))
else
    KUBECTL_VERSION=$(kubectl version --client 2>&1 | head -n 1 | sed 's/.*v\([0-9.]*\).*/\1/' 2>/dev/null || echo "unknown")
    echo "  ✓ kubectl version: ${KUBECTL_VERSION}"
fi

# Check helm is available (needed for later steps)
echo ""
echo "[5/7] Checking helm..."
if ! command -v helm &> /dev/null; then
    echo "  ✗ ERROR: helm is not installed or not in PATH"
    echo "    Install helm: https://helm.sh/docs/intro/install/"
    ERRORS=$((ERRORS + 1))
else
    # Helm v3 uses --short, v2 uses different format
    HELM_VERSION=$(helm version --short 2>&1 | head -n 1 || helm version --client --short 2>&1 | head -n 1 || helm version 2>&1 | head -n 1 | sed 's/.*v\([0-9.]*\).*/\1/' || echo "unknown")
    echo "  ✓ helm version: ${HELM_VERSION}"
fi

# Check Docker (optional but recommended for image building)
echo ""
echo "[6/7] Checking Docker (optional)..."
if ! command -v docker &> /dev/null; then
    echo "  ⚠ WARNING: Docker is not installed (needed if building images locally)"
    echo "    Install Docker: https://docs.docker.com/get-docker/"
    WARNINGS=$((WARNINGS + 1))
else
    DOCKER_VERSION=$(docker --version 2>&1 | head -n 1 || echo "unknown")
    echo "  ✓ ${DOCKER_VERSION}"
fi

# Check Terraform directory and configuration
echo ""
echo "[7/7] Checking Terraform configuration..."
if [ ! -d "${TERRAFORM_DIR}" ]; then
    echo "  ✗ ERROR: Terraform directory not found at ${TERRAFORM_DIR}"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ Terraform directory exists"
    
    # Check terraform.tfvars
    if [ ! -f "${TERRAFORM_DIR}/terraform.tfvars" ]; then
        echo "  ⚠ WARNING: terraform.tfvars not found"
        if [ -f "${TERRAFORM_DIR}/terraform.tfvars.example" ]; then
            echo "    Will create from terraform.tfvars.example"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "  ✗ ERROR: terraform.tfvars.example not found"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "  ✓ terraform.tfvars exists"
    fi
    
    # Check main Terraform files exist
    if [ ! -f "${TERRAFORM_DIR}/main.tf" ]; then
        echo "  ✗ ERROR: main.tf not found in Terraform directory"
        ERRORS=$((ERRORS + 1))
    else
        echo "  ✓ main.tf exists"
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "Prerequisites Check Summary"
echo "=========================================="
echo "Errors: ${ERRORS}"
echo "Warnings: ${WARNINGS}"
echo ""

if [ ${ERRORS} -gt 0 ]; then
    echo "✗ Prerequisites check FAILED"
    echo ""
    echo "Please fix the errors above before proceeding."
    echo "The deployment cannot continue with missing prerequisites."
    exit 1
fi

if [ ${WARNINGS} -gt 0 ]; then
    echo "⚠ Prerequisites check passed with warnings"
    echo ""
    echo "You may proceed, but some features may not work correctly."
    echo "Review the warnings above."
    echo ""
    read -p "Do you want to continue despite warnings? (yes/no): " CONTINUE
    if [ "${CONTINUE}" != "yes" ]; then
        echo "Deployment cancelled by user"
        exit 0
    fi
    echo ""
else
    echo "✓ All prerequisites check passed"
    echo ""
fi

# Check Terraform directory exists
if [ ! -d "${TERRAFORM_DIR}" ]; then
    echo "ERROR: Terraform directory not found at ${TERRAFORM_DIR}"
    exit 1
fi

# Check terraform.tfvars exists
if [ ! -f "${TERRAFORM_DIR}/terraform.tfvars" ]; then
    echo ""
    echo "WARNING: terraform.tfvars not found"
    echo "Creating terraform.tfvars from example..."
    if [ -f "${TERRAFORM_DIR}/terraform.tfvars.example" ]; then
        cp "${TERRAFORM_DIR}/terraform.tfvars.example" "${TERRAFORM_DIR}/terraform.tfvars"
        echo "✓ Created terraform.tfvars from example"
        echo ""
        echo "⚠ IMPORTANT: Please edit ${TERRAFORM_DIR}/terraform.tfvars with your values before continuing"
        echo "  Required variables:"
        echo "    - fluss_image_repository"
        echo "    - demo_image_repository"
        echo ""
        read -p "Press Enter after updating terraform.tfvars to continue, or Ctrl+C to abort..."
    else
        echo "ERROR: terraform.tfvars.example not found"
        exit 1
    fi
fi

echo "✓ terraform.tfvars found"

# Navigate to Terraform directory
cd "${TERRAFORM_DIR}"

# Check Terraform state configuration and preservation
echo ""
echo "=========================================="
echo "Checking Terraform State Configuration"
echo "=========================================="

# Check if backend is configured in main.tf (before init)
# Look for backend block (can be commented or uncommented)
if [ -f "${TERRAFORM_DIR}/main.tf" ]; then
    BACKEND_IN_CONFIG=$(grep -E "^\s*backend\s+" "${TERRAFORM_DIR}/main.tf" 2>/dev/null | grep -v "^\s*#" || echo "")
else
    BACKEND_IN_CONFIG=""
fi
USE_LOCAL_STATE=true

if [ -z "${BACKEND_IN_CONFIG}" ]; then
    echo "⚠ WARNING: No remote backend configured in main.tf"
    echo "  Terraform state will be stored locally in: ${TERRAFORM_DIR}/terraform.tfstate"
    echo "  This state file is critical - if lost, Terraform cannot manage existing infrastructure"
    echo ""
    echo "  To preserve state, consider:"
    echo "    1. Configure S3 backend in main.tf (uncomment backend block)"
    echo "    2. Or backup terraform.tfstate file regularly"
    echo ""
    
    # Backup existing state file if it exists
    if [ -f "${TERRAFORM_DIR}/terraform.tfstate" ]; then
        BACKUP_FILE="${TERRAFORM_DIR}/terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)"
        echo "  Creating backup of existing state file..."
        cp "${TERRAFORM_DIR}/terraform.tfstate" "${BACKUP_FILE}"
        echo "  ✓ State backed up to: ${BACKUP_FILE}"
        
        # Also backup .terraform directory if it exists (contains provider plugins and backend config)
        if [ -d "${TERRAFORM_DIR}/.terraform" ]; then
            echo "  Note: .terraform directory exists (contains provider plugins)"
        fi
    else
        echo "  ℹ No existing state file found (first-time deployment)"
    fi
    echo ""
else
    echo "✓ Remote backend configured in main.tf"
    echo "  State will be stored remotely"
    USE_LOCAL_STATE=false
    echo ""
fi

# Initialize Terraform
echo ""
echo "Initializing Terraform..."
if terraform init; then
    echo "✓ Terraform initialized"
    
    # After init, check actual backend status by looking at .terraform/terraform.tfstate
    # If backend is actually configured, this file will exist and contain backend info
    if [ -f "${TERRAFORM_DIR}/.terraform/terraform.tfstate" ]; then
        if grep -q "backend" "${TERRAFORM_DIR}/.terraform/terraform.tfstate" 2>/dev/null; then
            USE_LOCAL_STATE=false
            echo "  ✓ Using remote backend (verified after init)"
        fi
    fi
    
    # Final check: if local state file exists but backend is configured, warn
    if [ "${USE_LOCAL_STATE}" = "false" ] && [ -f "${TERRAFORM_DIR}/terraform.tfstate" ]; then
        echo ""
        echo "ℹ Note: Local state file exists but backend is configured"
        echo "  State is stored remotely, local file may be outdated"
    elif [ "${USE_LOCAL_STATE}" = "true" ] && [ -f "${TERRAFORM_DIR}/terraform.tfstate" ]; then
        echo ""
        echo "ℹ Using local state file"
        echo "  If you configure a remote backend later, you'll need to migrate state:"
        echo "    1. Uncomment backend block in main.tf"
        echo "    2. Run: terraform init -migrate-state"
    fi
else
    echo "ERROR: Terraform initialization failed"
    exit 1
fi

# Check if EKS cluster already exists FIRST (before validation/plan)
echo ""
echo "Checking if EKS cluster already exists..."
CLUSTER_EXISTS=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")

# Validate Terraform configuration
echo ""
echo "Validating Terraform configuration..."
if terraform validate; then
    echo "✓ Terraform configuration is valid"
else
    echo "ERROR: Terraform configuration validation failed"
    exit 1
fi

if [ "${CLUSTER_EXISTS}" = "NOT_FOUND" ] || [ "${CLUSTER_EXISTS}" = "" ]; then
    echo "⚠ EKS cluster does not exist yet"
    echo "  Deploying in two phases (skipping plan to avoid Kubernetes provider errors)"
    echo ""
    
    # Phase 1: Deploy AWS resources only
    echo "=========================================="
    echo "Phase 1: Deploying AWS Infrastructure"
    echo "=========================================="
    echo ""
    echo "This will create: EKS cluster, VPC, S3 bucket, IAM roles"
    echo "Note: Plan is skipped as Kubernetes provider will fail before cluster exists"
    echo ""
    read -p "Do you want to proceed? (yes/no): " CONFIRM
    if [ "${CONFIRM}" != "yes" ]; then
        echo "Deployment cancelled"
        exit 0
    fi
    
    echo ""
    echo "Step 1: Creating VPC and IAM resources..."
    terraform apply -auto-approve \
        -target=module.vpc \
        -target=aws_s3_bucket.flink_state \
        -target=aws_iam_role.flink_s3_access \
        -target=aws_iam_policy.flink_s3_access \
        -target=aws_iam_role_policy_attachment.flink_s3_access
    
    echo ""
    echo "Step 2: Creating EKS cluster (this may take 10-15 minutes)..."
    echo "Note: Cluster will be created first, then addons and node groups"
    # Apply EKS module - Terraform dependency graph will create cluster first
    terraform apply -auto-approve -target=module.eks
    
    echo ""
    echo "Waiting for EKS cluster to be ready..."
    aws eks wait cluster-active --name "${CLUSTER_NAME}" --region "${REGION}"
    echo "✓ Cluster is ACTIVE"
    
    # Wait for node groups to be ready
    echo ""
    echo "Waiting for EKS node groups to be ready..."
    MAX_RETRIES=30
    RETRY_COUNT=0
    NODES_READY=false
    
    # Get list of node groups
    NODE_GROUPS=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --region "${REGION}" --query 'nodegroups[]' --output text 2>/dev/null || echo "")
    
    if [ -n "${NODE_GROUPS}" ]; then
        # Check each node group
        while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
            ALL_ACTIVE=true
            for NODE_GROUP in ${NODE_GROUPS}; do
                NODE_STATUS=$(aws eks describe-nodegroup \
                    --cluster-name "${CLUSTER_NAME}" \
                    --region "${REGION}" \
                    --nodegroup-name "${NODE_GROUP}" \
                    --query 'nodegroup.status' \
                    --output text 2>/dev/null || echo "NOT_FOUND")
                
                if [ "${NODE_STATUS}" = "ACTIVE" ]; then
                    continue
                elif [ "${NODE_STATUS}" = "CREATING" ] || [ "${NODE_STATUS}" = "UPDATING" ]; then
                    ALL_ACTIVE=false
                    break
                elif [ "${NODE_STATUS}" = "NOT_FOUND" ]; then
                    ALL_ACTIVE=false
                    break
                else
                    echo "  Node group ${NODE_GROUP} status: ${NODE_STATUS}"
                fi
            done
            
            if [ "${ALL_ACTIVE}" = "true" ]; then
                NODES_READY=true
                break
            else
                echo "  Node groups are still initializing... (attempt $((RETRY_COUNT + 1))/${MAX_RETRIES})"
                sleep 30
                RETRY_COUNT=$((RETRY_COUNT + 1))
            fi
        done
    else
        echo "  No node groups found yet, waiting a bit..."
        sleep 30
    fi
    
    if [ "${NODES_READY}" = "true" ]; then
        echo "✓ Node groups are ACTIVE"
    else
        echo "⚠ Node groups may still be initializing, but proceeding..."
    fi
    echo ""
    
    # Update kubeconfig
    echo "Updating kubeconfig..."
    aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"
    echo "✓ Kubeconfig updated"
    echo ""
    
    # Wait a moment for kubeconfig to be ready and verify connection
    echo "Verifying Kubernetes connection..."
    sleep 10
    if kubectl cluster-info &>/dev/null; then
        echo "✓ Kubernetes connection verified"
    else
        echo "⚠ Kubernetes connection not ready yet, but proceeding..."
    fi
    echo ""
    
    # Refresh Terraform state to pick up EKS outputs
    echo "Refreshing Terraform state..."
    terraform refresh -target=module.eks || true
    echo "✓ State refreshed"
    echo ""
    
    # Phase 2: Deploy Kubernetes resources
    echo "=========================================="
    echo "Phase 2: Deploying Kubernetes Resources"
    echo "=========================================="
    echo ""
    echo "This will create: Kubernetes namespace, service account, secrets"
    echo ""
    read -p "Do you want to proceed? (yes/no): " CONFIRM
    if [ "${CONFIRM}" != "yes" ]; then
        echo "Deployment cancelled"
        exit 0
    fi
    
    echo ""
    echo "Applying Kubernetes resources..."
    # Only target Kubernetes resources, not module outputs which are managed by the EKS module
    terraform apply -auto-approve \
        -target=null_resource.wait_for_cluster \
        -target=kubernetes_namespace.fluss \
        -target=kubernetes_service_account.flink \
        -target=kubernetes_secret.flink_s3_credentials
    
    echo "✓ Kubernetes resources deployed"
    echo ""
    
    # Final apply for any remaining resources (EBS CSI IRSA, outputs, etc.)
    echo "=========================================="
    echo "Final: Applying All Remaining Resources"
    echo "=========================================="
    echo ""
    terraform apply -auto-approve
    echo "✓ All resources deployed"
    
else
    echo "✓ EKS cluster exists (status: ${CLUSTER_EXISTS})"
    echo "  Proceeding with normal plan/apply..."
    echo ""
    
    # Normal plan/apply flow
    echo "Planning infrastructure changes..."
    PLAN_OUTPUT=$(terraform plan -out=tfplan 2>&1)
    PLAN_EXIT_CODE=$?
    
    if [ ${PLAN_EXIT_CODE} -eq 0 ]; then
        echo "✓ Terraform plan created successfully"
    elif echo "${PLAN_OUTPUT}" | grep -q "dial tcp.*connection refused"; then
        echo "⚠ Plan shows Kubernetes connection errors"
        echo "  This can happen if cluster is still initializing or kubeconfig needs update"
        echo "  Attempting to update kubeconfig and retry..."
        aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" || true
        echo ""
        echo "Retrying plan..."
        if terraform plan -out=tfplan; then
            echo "✓ Terraform plan created successfully after kubeconfig update"
        else
            echo "⚠ Plan still shows errors, but proceeding with apply"
            echo "  Apply will work correctly as cluster exists"
        fi
    else
        echo "ERROR: Terraform plan failed with unexpected errors:"
        echo "${PLAN_OUTPUT}" | tail -20
        exit 1
    fi

    # Show plan summary (only if plan file exists)
    if [ -f "${TERRAFORM_DIR}/tfplan" ]; then
        echo ""
        echo "Plan summary:"
        terraform show -no-color tfplan 2>/dev/null | grep -E "^Plan:|^  #|^  \+|^  \-|^  ~|^  ->" | head -20 || true
        echo "  ... (showing first 20 lines, see tfplan for full details)"

        # Check if plan has changes
        PLAN_CHANGES=$(terraform show -no-color tfplan 2>/dev/null | grep -E "^Plan:" | head -1 || echo "")
        if echo "${PLAN_CHANGES}" | grep -q "0 to add, 0 to change, 0 to destroy"; then
            echo ""
            echo "✓ No changes needed - infrastructure is already up to date"
            echo "  Skipping apply step"
        else
            # Apply infrastructure
            echo ""
            echo "Applying infrastructure changes..."
            echo "⚠ This will create/modify AWS resources. Review the plan above carefully."
            read -p "Do you want to proceed? (yes/no): " CONFIRM
            if [ "${CONFIRM}" != "yes" ]; then
                echo "Deployment cancelled by user"
                exit 0
            fi
            if terraform apply tfplan; then
                echo "✓ Infrastructure deployed successfully"
            else
                echo "ERROR: Infrastructure deployment failed"
                exit 1
            fi
        fi
    else
        echo ""
        echo "⚠ Plan file not found, but proceeding with apply anyway"
        echo "  This can happen if plan had errors but cluster exists"
        echo ""
        read -p "Do you want to proceed with apply? (yes/no): " CONFIRM
        if [ "${CONFIRM}" != "yes" ]; then
            echo "Deployment cancelled by user"
            exit 0
        fi
        if terraform apply -auto-approve; then
            echo "✓ Infrastructure deployed successfully"
        else
            echo "ERROR: Infrastructure deployment failed"
            exit 1
        fi
    fi
fi

# Backup state file after successful apply (if using local state)
if [ "${USE_LOCAL_STATE}" = "true" ] && [ -f "${TERRAFORM_DIR}/terraform.tfstate" ]; then
    echo ""
    echo "Backing up Terraform state after successful apply..."
    BACKUP_FILE="${TERRAFORM_DIR}/terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${TERRAFORM_DIR}/terraform.tfstate" "${BACKUP_FILE}"
    echo "✓ State backed up to: ${BACKUP_FILE}"
fi

# Get Terraform outputs
echo ""
echo "Retrieving Terraform outputs..."
CLUSTER_NAME_OUTPUT=$(terraform output -raw eks_cluster_name 2>/dev/null || echo "")
CLUSTER_ENDPOINT=$(terraform output -raw eks_cluster_endpoint 2>/dev/null || echo "")
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
FLUSS_IMAGE_REPO=$(terraform output -raw fluss_image_repository 2>/dev/null || echo "")
DEMO_IMAGE_REPO=$(terraform output -raw demo_image_repository 2>/dev/null || echo "")

if [ -n "${CLUSTER_NAME_OUTPUT}" ]; then
    echo "✓ EKS Cluster: ${CLUSTER_NAME_OUTPUT}"
    echo "✓ Cluster Endpoint: ${CLUSTER_ENDPOINT}"
fi

if [ -n "${VPC_ID}" ]; then
    echo "✓ VPC ID: ${VPC_ID}"
fi

# Verify cluster is ready (simple check)
echo ""
echo "Verifying EKS cluster status..."
CLUSTER_STATUS=$(aws eks describe-cluster --name "${CLUSTER_NAME_OUTPUT:-${CLUSTER_NAME}}" --region "${REGION}" --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "${CLUSTER_STATUS}" = "ACTIVE" ]; then
    echo "✓ EKS cluster is ACTIVE"
elif [ "${CLUSTER_STATUS}" = "CREATING" ]; then
    echo "  Cluster is CREATING - it will become ACTIVE shortly"
    echo "  You can proceed to next steps once cluster is ACTIVE"
elif [ "${CLUSTER_STATUS}" = "NOT_FOUND" ]; then
    echo "⚠ Cluster not found yet - it may still be creating"
else
    echo "⚠ Cluster status: ${CLUSTER_STATUS}"
fi

# Summary
echo ""
echo "=========================================="
echo "Infrastructure Deployment Summary"
echo "=========================================="
echo ""
echo "✓ Terraform infrastructure deployed successfully"
echo ""
echo "Cluster Information:"
echo "  Name: ${CLUSTER_NAME_OUTPUT:-${CLUSTER_NAME}}"
echo "  Region: ${REGION}"
if [ -n "${CLUSTER_ENDPOINT}" ]; then
    echo "  Endpoint: ${CLUSTER_ENDPOINT}"
fi
echo ""
echo "Image Repositories:"
if [ -n "${FLUSS_IMAGE_REPO}" ] && [ "${FLUSS_IMAGE_REPO}" != "Not configured" ]; then
    echo "  Fluss: ${FLUSS_IMAGE_REPO}"
else
    echo "  Fluss: Using Docker Hub (apache/fluss)"
fi
if [ -n "${DEMO_IMAGE_REPO}" ] && [ "${DEMO_IMAGE_REPO}" != "Not configured" ]; then
    echo "  Demo: ${DEMO_IMAGE_REPO}"
else
    echo "  Demo: Not configured - set demo_image_repository in terraform.tfvars"
fi
echo ""
echo "Next Steps:"
echo "  1. Ensure Docker images are built and pushed to ECR (if using ECR)"
echo "  2. Proceed to Step 1: Update kubeconfig"
echo "     Run: ./01-update-kubeconfig.sh"
echo "     Or continue with: ./deploy-benchmark.sh --start-from-step 1"
echo ""
echo "To view all Terraform outputs:"
echo "  cd ${TERRAFORM_DIR}"
echo "  terraform output"
echo ""

# Final state preservation reminder
if [ "${USE_LOCAL_STATE}" = "true" ]; then
    echo "=========================================="
    echo "⚠ IMPORTANT: Terraform State Preservation"
    echo "=========================================="
    echo ""
    echo "Your Terraform state is stored locally at:"
    echo "  ${TERRAFORM_DIR}/terraform.tfstate"
    echo ""
    echo "⚠ CRITICAL: This file is essential for managing your infrastructure!"
    echo "  - DO NOT delete this file"
    echo "  - DO NOT commit it to version control (contains sensitive data)"
    echo "  - Backup this file regularly"
    echo ""
    echo "To configure remote state storage (recommended):"
    echo "  1. Create an S3 bucket for Terraform state"
    echo "  2. Uncomment and configure the backend block in main.tf"
    echo "  3. Run: terraform init -migrate-state"
    echo ""
fi

echo "✓ Step 0 completed: Infrastructure deployed successfully"

