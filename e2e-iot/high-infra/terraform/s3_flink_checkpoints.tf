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

# ================================================================================
# S3 BUCKET FOR FLINK CHECKPOINTS AND SAVEPOINTS
# ================================================================================
# This configuration creates an S3 bucket for Flink state storage with proper
# IAM permissions using IRSA (IAM Roles for Service Accounts)
# ================================================================================

# S3 bucket names are globally unique; add a stable random suffix to avoid collisions
# with other AWS accounts using the same default cluster naming convention.
resource "random_id" "flink_state_bucket" {
  keepers = {
    cluster_name = var.eks_cluster_name
    account_id   = data.aws_caller_identity.current.account_id
    environment  = var.environment
  }
  byte_length = 4
}

# S3 Bucket for Flink Checkpoints and Savepoints
resource "aws_s3_bucket" "flink_state" {
  bucket = "${var.eks_cluster_name}-flink-state-${data.aws_caller_identity.current.account_id}-${random_id.flink_state_bucket.hex}"

  force_destroy = true  # Allow terraform destroy to delete bucket even with objects/versions

  tags = {
    Name        = "${var.eks_cluster_name}-flink-state"
    Project     = "fluss-deployment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "flink_state" {
  bucket = aws_s3_bucket.flink_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flink_state" {
  bucket = aws_s3_bucket.flink_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "flink_state" {
  bucket = aws_s3_bucket.flink_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Lifecycle policy for cost savings - delete old checkpoints
resource "aws_s3_bucket_lifecycle_configuration" "flink_state" {
  bucket = aws_s3_bucket.flink_state.id

  rule {
    id     = "delete-old-checkpoints"
    status = "Enabled"

    filter {
      prefix = "flink-checkpoints/${var.eks_cluster_name}/"
    }

    expiration {
      days = 7  # Delete checkpoints after 7 days
    }

    noncurrent_version_expiration {
      noncurrent_days = 3
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "delete-old-savepoints"
    status = "Enabled"

    filter {
      prefix = "flink-savepoints/${var.eks_cluster_name}/"
    }

    expiration {
      days = 30  # Keep savepoints longer (30 days)
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# IAM Policy for Flink S3 Access
resource "aws_iam_policy" "flink_s3_access" {
  name        = "${var.eks_cluster_name}-flink-s3-policy"
  description = "S3 permissions for Flink checkpoints and savepoints"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.flink_state.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.flink_state.arn}/*"
        ]
      }
    ]
  })

  tags = {
    Name        = "${var.eks_cluster_name}-flink-s3-policy"
    Project     = "fluss-deployment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# IAM Role for Flink Service Account (IRSA)
resource "aws_iam_role" "flink_s3_access" {
  name = "${var.eks_cluster_name}-flink-s3-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:${var.namespace}:flink"
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.eks_cluster_name}-flink-s3-access"
    Project     = "fluss-deployment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Attach S3 policy to IAM role
resource "aws_iam_role_policy_attachment" "flink_s3_access" {
  role       = aws_iam_role.flink_s3_access.name
  policy_arn = aws_iam_policy.flink_s3_access.arn
}

# Wait for EKS cluster to be fully ready before creating Kubernetes resources
# This ensures the Kubernetes API is accessible before Terraform tries to connect
resource "null_resource" "wait_for_cluster" {
  depends_on = [module.eks.cluster_id]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for EKS cluster to be ready..."
      aws eks wait cluster-active \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} || true
      echo "Cluster is ready"
    EOT
  }

  triggers = {
    cluster_id = module.eks.cluster_id
  }
}

# Create namespace for Flink service account
# Depends on EKS cluster being created and ready
resource "kubernetes_namespace" "fluss" {
  depends_on = [
    module.eks.cluster_id,
    module.eks.cluster_endpoint,
    null_resource.wait_for_cluster  # Wait for cluster to be fully ready
  ]

  metadata {
    name = var.namespace
    labels = {
      Project     = "fluss-deployment"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Kubernetes Service Account for Flink with IRSA annotation
resource "kubernetes_service_account" "flink" {
  depends_on = [kubernetes_namespace.fluss]
  
  metadata {
    name      = "flink"
    namespace = var.namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.flink_s3_access.arn
    }
    labels = {
      app       = "flink"
      component = "flink"
    }
  }
}

# Outputs
output "flink_s3_bucket_name" {
  description = "S3 bucket name for Flink checkpoints"
  value       = aws_s3_bucket.flink_state.id
}

output "flink_s3_bucket_arn" {
  description = "S3 bucket ARN for Flink checkpoints"
  value       = aws_s3_bucket.flink_state.arn
}

output "flink_s3_checkpoint_path" {
  description = "S3 path for Flink checkpoints"
  value       = "s3://${aws_s3_bucket.flink_state.id}/flink-checkpoints/${var.eks_cluster_name}/"
}

output "flink_s3_savepoint_path" {
  description = "S3 path for Flink savepoints"
  value       = "s3://${aws_s3_bucket.flink_state.id}/flink-savepoints/${var.eks_cluster_name}/"
}

output "flink_iam_role_arn" {
  description = "IAM role ARN for Flink S3 access"
  value       = aws_iam_role.flink_s3_access.arn
}

