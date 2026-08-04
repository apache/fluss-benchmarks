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

#!/bin/bash
# IMPORTANT: ECR repositories are NOT managed by Terraform to prevent accidental deletion
# This script is disabled - ECR repositories should be created manually and NOT imported into Terraform state
# If ECR repositories are in Terraform state, terraform destroy will delete them and all images!

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

AWS_REGION=${AWS_REGION:-us-west-2}

echo "=========================================="
echo "ECR Import Script - DISABLED"
echo "=========================================="
echo ""
echo "ECR repositories are NOT managed by Terraform to prevent"
echo "accidental deletion of images during terraform destroy."
echo ""
echo "ECR repositories should be:"
echo "  1. Created manually via AWS CLI/Console"
echo "  2. Images pushed using push-images-to-ecr.sh"
echo "  3. NEVER imported into Terraform state"
echo ""
echo "If ECR repositories exist in Terraform state, remove them with:"
echo "  terraform state rm aws_ecr_repository.demo_app"
echo "  terraform state rm aws_ecr_repository.fluss"
echo "  terraform state rm aws_ecr_lifecycle_policy.demo_app"
echo "  terraform state rm aws_ecr_lifecycle_policy.fluss"
echo ""
echo "Checking if ECR repositories are in Terraform state (they should NOT be)..."
echo ""

# Check if ECR repositories are in state - warn if they are
if terraform state show aws_ecr_repository.demo_app >/dev/null 2>&1; then
  echo "  ⚠ WARNING: aws_ecr_repository.demo_app is in Terraform state!"
  echo "     Remove it with: terraform state rm aws_ecr_repository.demo_app"
else
  echo "  ✓ aws_ecr_repository.demo_app is NOT in state (correct)"
fi

if terraform state show aws_ecr_repository.fluss >/dev/null 2>&1; then
  echo "  ⚠ WARNING: aws_ecr_repository.fluss is in Terraform state!"
  echo "     Remove it with: terraform state rm aws_ecr_repository.fluss"
else
  echo "  ✓ aws_ecr_repository.fluss is NOT in state (correct)"
fi

echo ""
echo "ECR import check complete - no imports performed (by design)."

