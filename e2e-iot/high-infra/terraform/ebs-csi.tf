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

# EBS CSI Driver for gp3 storage support
# Note: EBS CSI driver is now configured in eks_cluster.tf as part of cluster_addons
# This file is kept for backward compatibility but the addon is managed by the EKS module

# Output
output "ebs_csi_driver_installed" {
  description = "Whether EBS CSI driver addon is installed"
  value       = var.install_ebs_csi_driver
}

output "ebs_csi_driver_role_arn" {
  description = "IAM role ARN for EBS CSI driver"
  value       = var.install_ebs_csi_driver ? module.ebs_csi_irsa[0].iam_role_arn : null
}

