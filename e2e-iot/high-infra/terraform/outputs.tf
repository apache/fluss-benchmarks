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

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "coordinator_node_group_id" {
  description = "Coordinator node group ID"
  value       = module.eks.eks_managed_node_groups["coordinator"].node_group_id
}

output "tablet_server_node_group_id" {
  description = "Tablet server node group ID"
  value       = module.eks.eks_managed_node_groups["tablet_server"].node_group_id
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}

output "namespace" {
  description = "Kubernetes namespace"
  value       = var.namespace
}

output "fluss_coordinator_service" {
  description = "Fluss coordinator service name"
  value       = "coordinator-server-hs.${var.namespace}.svc.cluster.local:9124"
}

output "zookeeper_service" {
  description = "ZooKeeper service name"
  value       = "zk-svc.${var.namespace}.svc.cluster.local:2181"
}

output "demo_image_repository" {
  description = "ECR repository URL for demo image (must be set in terraform.tfvars)"
  value       = var.demo_image_repository != "" ? var.demo_image_repository : "Not configured - set demo_image_repository in terraform.tfvars"
}

output "fluss_image_repository" {
  description = "ECR repository URL for Fluss image (must be set in terraform.tfvars)"
  value       = var.use_ecr_for_fluss ? (var.fluss_image_repository != "" ? var.fluss_image_repository : "Not configured - set fluss_image_repository in terraform.tfvars") : "Using Docker Hub: apache/fluss"
}

output "grafana_url" {
  description = "Grafana dashboard URL - Use: kubectl get svc -n monitoring prometheus-grafana"
  value       = "Access Grafana via: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
}

output "grafana_credentials" {
  description = "Grafana login credentials"
  value       = "Username: admin, Password: admin123"
  sensitive   = false
}

output "prometheus_url" {
  description = "Prometheus UI URL"
  value       = "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
}

output "monitoring_namespace" {
  description = "Kubernetes namespace for monitoring"
  value       = "monitoring"
}

