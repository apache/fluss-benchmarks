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
set -e

# Build and Push Fluss Flink Demo Docker Image to AWS ECR
# This script builds the Flink demo JAR and pushes it to ECR

echo "======================================"
echo "Fluss Flink Demo - Build and Push to ECR"
echo "======================================"
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
AWS_REGION=${AWS_REGION:-us-west-2}
# Try to get AWS account ID from AWS CLI if not set
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [ -z "${AWS_ACCOUNT_ID}" ]; then
        echo "ERROR: AWS_ACCOUNT_ID is not set and could not be determined from AWS CLI"
        echo "Please set it with: export AWS_ACCOUNT_ID=your-account-id"
        exit 1
    fi
fi
ECR_REPOSITORY="fluss-demo"
IMAGE_TAG=${IMAGE_TAG:-latest}
FLUSS_VERSION="${FLUSS_VERSION:-0.9.0-incubating}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go up from k8s/flink to 2-million-messages-per-second directory
# k8s/flink -> k8s -> high-infra -> 2-million-messages-per-second
DEMO_BASE_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo -e "${YELLOW}Configuration:${NC}"
echo "  AWS Region: ${AWS_REGION}"
echo "  AWS Account: ${AWS_ACCOUNT_ID}"
echo "  ECR Repository: ${ECR_REPOSITORY}"
echo "  Image Tag: ${IMAGE_TAG}"
echo "  Fluss Version: ${FLUSS_VERSION}"
echo "  Platform: linux/amd64"
echo "  Demo Base Dir: ${DEMO_BASE_DIR}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker is not installed or not running${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker daemon is not running${NC}"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All prerequisites met${NC}"
echo ""

# Check if demo source exists
DEMO_DIR="${DEMO_BASE_DIR}/fluss_flink_realtime"
if [ ! -d "${DEMO_DIR}" ]; then
    echo -e "${RED}❌ Demo directory not found: ${DEMO_DIR}${NC}"
    exit 1
fi

# Find the JAR file (may have version suffix)
JAR_FILE=$(find "${DEMO_DIR}/target" -name "fluss-flink-realtime-demo*.jar" -type f | head -1)

# Check if JAR exists or needs to be built
if [ -z "${JAR_FILE}" ] || [ ! -f "${JAR_FILE}" ]; then
    echo -e "${YELLOW}JAR not found, building it first...${NC}"
    cd "${DEMO_DIR}"
    mvn clean package -DskipTests -Dfluss.version="${FLUSS_VERSION}"
    cd "${SCRIPT_DIR}"
    JAR_FILE=$(find "${DEMO_DIR}/target" -name "fluss-flink-realtime-demo*.jar" -type f | head -1)
fi

if [ -z "${JAR_FILE}" ] || [ ! -f "${JAR_FILE}" ]; then
    echo -e "${RED}❌ JAR file not found after build${NC}"
    exit 1
fi

echo -e "${GREEN}✅ JAR file ready: ${JAR_FILE}${NC}"
echo ""

# Build the Docker image
echo -e "${YELLOW}Building Docker image for linux/amd64...${NC}"
echo "This may take 5-10 minutes..."
echo ""

cd "${SCRIPT_DIR}"

# Copy JAR to build context (rename to standard name)
cp "${JAR_FILE}" ./fluss-flink-realtime-demo.jar

# Build using the simple Dockerfile with buildx for cross-platform
BUILDER_NAME="fluss-multiplatform"
echo "Setting up Docker buildx for cross-platform build..."
if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
    echo "Creating buildx builder..."
    docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use --bootstrap 2>/dev/null || true
else
    docker buildx use "${BUILDER_NAME}" 2>/dev/null || true
fi

# Capture timestamp once to use consistently
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "Building Flink image with embedded JAR..."
docker buildx build --builder "${BUILDER_NAME}" --platform linux/amd64 --load \
  -t ${ECR_REPOSITORY}:${IMAGE_TAG} \
  -t ${ECR_REPOSITORY}:${TIMESTAMP} \
  -f Dockerfile.simple \
  .

# Cleanup
rm -f ./fluss-flink-realtime-demo.jar

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Docker image built successfully${NC}"
else
    echo -e "${RED}❌ Docker build failed${NC}"
    exit 1
fi

echo ""

# Get ECR login token
echo -e "${YELLOW}Authenticating with ECR...${NC}"
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ ECR authentication successful${NC}"
else
    echo -e "${RED}❌ ECR authentication failed${NC}"
    exit 1
fi

echo ""

# Check if ECR repository exists
echo -e "${YELLOW}Checking if ECR repository exists...${NC}"
if ! aws ecr describe-repositories --repository-names ${ECR_REPOSITORY} --region ${AWS_REGION} &> /dev/null; then
    echo -e "${YELLOW}⚠️  ECR repository '${ECR_REPOSITORY}' does not exist${NC}"
    echo -e "${YELLOW}Creating ECR repository...${NC}"
    
    aws ecr create-repository \
      --repository-name ${ECR_REPOSITORY} \
      --region ${AWS_REGION} \
      --image-scanning-configuration scanOnPush=true
    
    echo -e "${GREEN}✅ ECR repository created${NC}"
else
    echo -e "${GREEN}✅ ECR repository exists${NC}"
fi

echo ""

# Tag image for ECR
ECR_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"
echo -e "${YELLOW}Tagging image for ECR...${NC}"
docker tag ${ECR_REPOSITORY}:${IMAGE_TAG} ${ECR_IMAGE}:${IMAGE_TAG}
docker tag ${ECR_REPOSITORY}:${TIMESTAMP} ${ECR_IMAGE}:${TIMESTAMP}
# Also tag as latest (matching reference repository)
if [ "${IMAGE_TAG}" != "latest" ]; then
    docker tag ${ECR_REPOSITORY}:${IMAGE_TAG} ${ECR_IMAGE}:latest
fi

echo -e "${GREEN}✅ Image tagged${NC}"
echo ""

# Push to ECR
echo -e "${YELLOW}Pushing image to ECR...${NC}"
docker push ${ECR_IMAGE}:${IMAGE_TAG}
docker push ${ECR_IMAGE}:${TIMESTAMP}
# Also push as latest if tagged
if [ "${IMAGE_TAG}" != "latest" ]; then
    docker push ${ECR_IMAGE}:latest
fi

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Image pushed successfully${NC}"
else
    echo -e "${RED}❌ Image push failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}======================================"
echo "✅ Build and Push Complete!"
echo "======================================${NC}"
echo ""

echo -e "${YELLOW}Image Details:${NC}"
echo "  Repository: ${ECR_IMAGE}"
echo "  Tags: ${IMAGE_TAG}, ${TIMESTAMP}"
echo ""

echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Update flink-jobmanager.yaml and flink-taskmanager.yaml to use:"
echo "     image: ${ECR_IMAGE}:${IMAGE_TAG}"
echo "  2. Apply the updated deployments"
echo "  3. Submit job using Flink CLI with local:// path"
echo ""

