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
# EKS CLUSTER CREATION USING TERRAFORM AWS MODULES
# ================================================================================
# This configuration uses terraform-aws-modules/eks/aws and terraform-aws-modules/vpc/aws
# to properly handle node joining and avoid manual aws-auth ConfigMap patching
# ================================================================================

# Get available availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC Module - Creates VPC, subnets, NAT gateways, route tables automatically
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.eks_cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  # EKS requires subnets in at least 2 different AZs
  # We use 2 AZs for subnets but configure node groups to use only one AZ for cost savings
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)  # Two AZs (required by EKS)
  # Increased subnet size from /24 (251 IPs) to /20 (4091 IPs) to prevent IP exhaustion
  # This provides ~16x more IP addresses per subnet for pods and nodes
  # Subnets distributed across 2 AZs - EKS requirement
  private_subnets = ["10.0.0.0/20", "10.0.16.0/20"]   # 4091 usable IPs each - AZ 1 and AZ 2
  public_subnets  = ["10.0.32.0/20", "10.0.48.0/20"]  # 4091 usable IPs each - AZ 1 and AZ 2

  enable_nat_gateway   = true
  single_nat_gateway   = true  # Use single NAT gateway to save costs (all nodes in one AZ)
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }

  tags = {
    Name        = "${var.eks_cluster_name}-vpc"
    Project     = "fluss-deployment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Local variables for node group configurations
locals {
  # Coordinator node group configuration
  coordinator_node_group = {
    name           = "coordinator"
    instance_types = [var.coordinator_instance_type]
    capacity_type  = "ON_DEMAND"
    min_size       = var.coordinator_instance_count
    max_size       = var.coordinator_instance_count
    desired_size   = var.coordinator_instance_count
    disk_size      = 50
    disk_type      = "gp3"
    # Let EKS module automatically select the latest compatible AMI release version
    # This ensures compatibility with the cluster Kubernetes version
    subnet_ids     = [module.vpc.private_subnets[0]]  # Use only first AZ subnet

    labels = {
      "fluss-component" = "coordinator"
      "node-type"       = "coordinator"
      workload          = "fluss"
      service           = "coordinator"
    }

    taints = [
      {
        key    = "fluss-component"
        value  = "coordinator"
        effect = "NO_SCHEDULE"
      }
    ]

    tags = {
      Name        = "${var.eks_cluster_name}-coordinator"
      Component   = "coordinator"
      Service     = "fluss"
      Project     = "fluss-deployment"
      Environment = var.environment
    }

    enable_monitoring = false
    iam_role_additional_policies = {
      AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }

  # Tablet server node group configuration
  tablet_server_node_group = {
    name           = "tablet-server"
    instance_types = [var.tablet_server_instance_type]
    capacity_type  = "ON_DEMAND"
    min_size       = var.tablet_server_instance_count
    max_size       = var.tablet_server_instance_count
    desired_size   = var.tablet_server_instance_count
    disk_size      = 100
    disk_type      = "gp3"
    # Let EKS module automatically select the latest compatible AMI release version
    # This ensures compatibility with the cluster Kubernetes version
    subnet_ids     = [module.vpc.private_subnets[0]]  # Use only first AZ subnet

    labels = {
      "fluss-component" = "tablet-server"
      "node-type"       = "tablet-server"
      "node.kubernetes.io/instance-type" = var.tablet_server_instance_type
      "storage-type"    = "nvme"
      workload          = "fluss"
      service           = "tablet-server"
    }

    taints = []

    pre_bootstrap_user_data = <<-EOT
      #!/bin/bash
      # Format and mount NVMe drives for Fluss tablet servers
      
      # Wait for NVMe drives to be available
      # Check for available NVMe devices (different instance types have different numbers)
      NVME_COUNT=0
      MAX_WAIT=60
      WAIT_COUNT=0
      
      while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        NVME_COUNT=$(lsblk -d -n -o NAME | grep -c "^nvme" || echo "0")
        if [ $NVME_COUNT -gt 0 ]; then
          break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
      done
      
      # Format and mount NVMe drives
      # For i7i.8xlarge: typically has 2 NVMe drives (nvme1n1, nvme2n1)
      # For i3en.6xlarge: typically has 2 NVMe drives
      # For r6id.4xlarge: typically has 1 NVMe drive (nvme1n1)
      
      if [ -e /dev/nvme1n1 ]; then
        echo "Setting up NVMe drive /dev/nvme1n1 for Fluss tablet server (all data)..."
        mkfs.ext4 -F /dev/nvme1n1
        mkdir -p /opt/alldata
        mount /dev/nvme1n1 /opt/alldata
        echo "/dev/nvme1n1 /opt/alldata ext4 defaults,noatime 0 2" >> /etc/fstab
        chmod 755 /opt/alldata
        # Set ownership (assuming Fluss runs as UID 1000, adjust if needed)
        chown -R 1000:1000 /opt/alldata || true
        echo "NVMe drive /dev/nvme1n1 mounted to /opt/alldata"
      fi
      
      # Create Fluss data directories under /opt/alldata
      if [ -d /opt/alldata ]; then
        mkdir -p /opt/alldata/fluss/data
        mkdir -p /opt/alldata/fluss/remote-data
        mkdir -p /opt/alldata/fluss/logs
        chown -R 1000:1000 /opt/alldata/fluss || true
        echo "Created Fluss directories: data, remote-data, logs"
      fi
      
      # If second NVMe drive exists, use it for additional storage or leave unused
      if [ -e /dev/nvme2n1 ]; then
        echo "Second NVMe drive /dev/nvme2n1 detected but not configured (using single drive at /opt/alldata)"
      fi
      
      echo "NVMe setup completed for Fluss tablet servers"
    EOT

    tags = {
      Name        = "${var.eks_cluster_name}-tablet-server"
      Component   = "tablet-server"
      Service     = "fluss"
      Project     = "fluss-deployment"
      Environment = var.environment
    }

    enable_monitoring = false
    iam_role_additional_policies = {
      AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }

  # Flink JobManager node group configuration
  flink_jobmanager_node_group = {
    name           = "flink-jobmanager"
    instance_types = [var.flink_jobmanager_instance_type]
    capacity_type  = "ON_DEMAND"
    min_size       = 1
    max_size       = 1
    desired_size   = 1
    disk_size      = 50
    disk_type      = "gp3"
    # Let EKS module automatically select the latest compatible AMI release version
    # This ensures compatibility with the cluster Kubernetes version
    subnet_ids     = [module.vpc.private_subnets[0]]  # Use only first AZ subnet

    labels = {
      "flink-component" = "jobmanager"
      "node-type"       = "flink-jobmanager"
      workload          = "flink"
      service           = "flink-jobmanager"
    }

    taints = [
      {
        key    = "flink-component"
        value  = "jobmanager"
        effect = "NO_SCHEDULE"
      }
    ]

    tags = {
      Name        = "${var.eks_cluster_name}-flink-jobmanager"
      Component   = "flink-jobmanager"
      Service     = "flink"
      Project     = "fluss-deployment"
      Environment = var.environment
    }

    enable_monitoring = false
    iam_role_additional_policies = {
      AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }

  # Flink TaskManager node group configuration (6 nodes)
  flink_taskmanager_node_group = {
    name           = "flink-taskmanager"
    instance_types = [var.flink_taskmanager_instance_type]
    capacity_type  = "ON_DEMAND"
    min_size       = 6
    max_size       = 6
    desired_size   = 6
    disk_size      = 100
    disk_type      = "gp3"
    # Let EKS module automatically select the latest compatible AMI release version
    # This ensures compatibility with the cluster Kubernetes version
    subnet_ids     = [module.vpc.private_subnets[0]]  # Use only first AZ subnet

    labels = {
      "flink-component" = "taskmanager"
      "node-type"       = "flink-taskmanager"
      workload          = "flink"
      service           = "flink-taskmanager"
    }

    taints = [
      {
        key    = "flink-component"
        value  = "taskmanager"
        effect = "NO_SCHEDULE"
      }
    ]

    tags = {
      Name        = "${var.eks_cluster_name}-flink-taskmanager"
      Component   = "flink-taskmanager"
      Service     = "flink"
      Project     = "fluss-deployment"
      Environment = var.environment
    }

    enable_monitoring = false
    iam_role_additional_policies = {
      AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }

  # Producer node group configuration
  producer_node_group = {
    name           = "producer"
    instance_types = [var.producer_instance_type]
    capacity_type  = "ON_DEMAND"
    min_size       = var.producer_instance_count
    max_size       = var.producer_instance_count
    desired_size   = var.producer_instance_count
    disk_size      = 50
    disk_type      = "gp3"
    # Let EKS module automatically select the latest compatible AMI release version
    # This ensures compatibility with the cluster Kubernetes version
    subnet_ids     = [module.vpc.private_subnets[0]]  # Use only first AZ subnet

    labels = {
      "producer-component" = "producer"
      "node-type"          = "producer"
      workload             = "producer"
      service              = "producer"
    }

    taints = [
      {
        key    = "producer-component"
        value  = "producer"
        effect = "NO_SCHEDULE"
      }
    ]

    tags = {
      Name        = "${var.eks_cluster_name}-producer"
      Component   = "producer"
      Service     = "producer"
      Project     = "fluss-deployment"
      Environment = var.environment
    }

    enable_monitoring = false
    iam_role_additional_policies = {
      AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }
}

# EKS Module - Properly handles node joining automatically
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.eks_cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  # EKS requires at least 2 subnets in different AZs
  # Node groups are configured to use only the first AZ subnet for cost savings
  subnet_ids = module.vpc.private_subnets

  # Cluster endpoint access
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Enable IRSA (IAM Roles for Service Accounts) - Required for EBS CSI driver
  enable_irsa = true

  # Cluster addons - Core addons only (EBS CSI will be installed separately)
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # Enable cluster logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # EKS Managed Node Groups - Automatically handles aws-auth ConfigMap
  eks_managed_node_groups = {
    coordinator = local.coordinator_node_group
    tablet_server = local.tablet_server_node_group
    flink_jobmanager = local.flink_jobmanager_node_group
    flink_taskmanager = local.flink_taskmanager_node_group
    producer = local.producer_node_group
  }

  # aws-auth configmap - Managed automatically by the module
  manage_aws_auth_configmap = true

  tags = {
    Name        = var.eks_cluster_name
    Project     = "fluss-deployment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# EBS CSI Driver IRSA (if enabled)
# Created AFTER EKS module to get OIDC provider ARN
module "ebs_csi_irsa" {
  count = var.install_ebs_csi_driver ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.eks_cluster_name}-ebs-csi-driver"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Name        = "${var.eks_cluster_name}-ebs-csi-driver"
    Project     = "fluss-deployment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [module.eks]  # Must wait for OIDC provider
}

# Install EBS CSI driver addon separately (after IRSA role is created)
resource "aws_eks_addon" "ebs_csi_driver" {
  count = var.install_ebs_csi_driver ? 1 : 0

  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa[0].iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update  = "OVERWRITE"

  tags = {
    Name        = "${var.eks_cluster_name}-ebs-csi-driver"
    Project     = "fluss-deployment"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [
    module.ebs_csi_irsa[0],
    module.eks
  ]

  timeouts {
    create = "10m"
    update = "10m"
    delete = "10m"
  }
}

