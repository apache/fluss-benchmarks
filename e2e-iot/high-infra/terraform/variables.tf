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

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster to create"
  type        = string
  default     = "fluss-eks-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster (must be a currently EKS-supported version)"
  type        = string
  default     = "1.35"
}

variable "namespace" {
  description = "Kubernetes namespace for Fluss deployment"
  type        = string
  default     = "fluss"
}

variable "fluss_version" {
  description = "Fluss version to deploy"
  type        = string
  default     = "0.9.0-incubating"
}

variable "fluss_image_repository" {
  description = "Fluss Docker image repository (ECR URL or Docker Hub)"
  type        = string
  default     = "" # Will be set to ECR URL if use_ecr_for_fluss is true
}

variable "use_ecr_for_fluss" {
  description = "Use ECR repository for Fluss image instead of Docker Hub"
  type        = bool
  default     = true
}

variable "demo_image_repository" {
  description = "ECR repository for demo application image (fluss-demo)"
  type        = string
  default     = ""
}

variable "demo_image_tag" {
  description = "Tag for demo application image"
  type        = string
  default     = "latest"
}

variable "zookeeper_replicas" {
  description = "Number of ZooKeeper replicas"
  type        = number
  default     = 1
}

variable "coordinator_replicas" {
  description = "Number of Fluss coordinator replicas"
  type        = number
  default     = 1
}

variable "tablet_server_replicas" {
  description = "Number of Fluss tablet server replicas"
  type        = number
  default     = 3
}

variable "enable_persistence" {
  description = "Enable persistent volumes for Fluss. If false, uses root volume (emptyDir). If true, requires EBS CSI driver."
  type        = bool
  default     = false
}

variable "install_ebs_csi_driver" {
  description = "Install EBS CSI driver addon (required for gp3 PersistentVolumes if enable_persistence = true)"
  type        = bool
  default     = true
}

variable "storage_class" {
  description = "Storage class for persistent volumes"
  type        = string
  default     = "gp3"
}

variable "storage_size" {
  description = "Storage size for persistent volumes (e.g., 20Gi)"
  type        = string
  default     = "20Gi"
}

variable "coordinator_instance_type" {
  description = "EC2 instance type for Fluss coordinator"
  type        = string
  default     = "c5.2xlarge"
}

variable "tablet_server_instance_type" {
  description = "EC2 instance type for Fluss tablet servers (should have NVMe local storage like i7i.8xlarge, i3en.6xlarge, or r6id.4xlarge)"
  type        = string
  default     = "i7i.8xlarge"
}

variable "coordinator_instance_count" {
  description = "Number of coordinator instances"
  type        = number
  default     = 1
}

variable "tablet_server_instance_count" {
  description = "Number of tablet server instances"
  type        = number
  default     = 3
}

variable "producer_instance_type" {
  description = "EC2 instance type for producer nodes"
  type        = string
  default     = "c5.2xlarge"
}

variable "producer_instance_count" {
  description = "Number of producer instances"
  type        = number
  default     = 1
}

variable "flink_jobmanager_instance_type" {
  description = "EC2 instance type for Flink JobManager nodes"
  type        = string
  default     = "c5.4xlarge"
}

variable "flink_taskmanager_instance_type" {
  description = "EC2 instance type for Flink TaskManager nodes"
  type        = string
  default     = "c5.4xlarge"
}

variable "key_name" {
  description = "AWS Key Pair name for EC2 instances"
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "List of subnet IDs for EC2 instances (should be private subnets)"
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "List of security group IDs for EC2 instances"
  type        = list(string)
  default     = []
}

