# Terraform variables for Fluss deployment
# This file contains the actual ECR repository URLs after pushing images

aws_region = "us-west-2"
environment = "dev"
eks_cluster_name = "fluss-eks-cluster"
kubernetes_version = "1.31"  # Match cluster; upgrade to 1.35 when ready (one minor version per apply)
namespace = "fluss"

# Fluss configuration
fluss_version = "0.9.0-incubating"
# ECR repository URL for Fluss image (updated after push-images-to-ecr.sh)
fluss_image_repository = "343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss"
use_ecr_for_fluss = true

# Demo application image (ECR repository URL)
# Updated after push-images-to-ecr.sh
demo_image_repository = "343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo"
demo_image_tag = "latest"

# ZooKeeper configuration
zookeeper_replicas = 1

# Fluss configuration
coordinator_replicas = 1
tablet_server_replicas = 3

# Storage configuration
# Set to false to use root volume (gp3) of EC2 instances instead of separate EBS volumes
enable_persistence = false  # Tablet servers will write to /tmp/fluss/data on root volume
storage_class = "gp3"  # Only used if enable_persistence = true
storage_size = "20Gi"  # Only used if enable_persistence = true

# EBS CSI Driver (for gp3 PersistentVolumes)
# Install EBS CSI driver addon - required if enable_persistence = true
# Even if persistence is disabled, installing it allows future flexibility
install_ebs_csi_driver = true

# EC2 Instance Configuration for Fluss Nodes
# These instances will be added to EKS cluster with specific labels
coordinator_instance_type = "c5.2xlarge"
tablet_server_instance_type = "i7i.8xlarge"
coordinator_instance_count = 1
tablet_server_instance_count = 3

# Flink Instance Configuration
flink_jobmanager_instance_type = "c5.4xlarge"
flink_taskmanager_instance_type = "c5.4xlarge"

# Producer Instance Configuration
producer_instance_type = "c5.2xlarge"
producer_instance_count = 4

# EC2 Instance Configuration
# key_name = "your-key-pair-name"  # Optional: SSH key for EC2 instances
# subnet_ids = ["subnet-xxx", "subnet-yyy"]  # Required: Subnets where instances will be launched
# security_group_ids = ["sg-xxx"]  # Optional: Additional security groups

