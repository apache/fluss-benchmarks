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

#!/usr/bin/env bash
set -euo pipefail

# Automation script to deploy Fluss on Kind and run the producer + Flink aggregator demo.
# This script automates the steps in kind_cluster_demo.md

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEMO_DIR="${SCRIPT_DIR}"
REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)
cd "${DEMO_DIR}"

KIND_NAME=${KIND_NAME:-fluss-kind}
FLUSS_VERSION="${FLUSS_VERSION:-0.9.0-incubating}"
DEMO_JAR="${DEMO_DIR}/target/fluss-flink-realtime-demo.jar"
FLINK_HOME="${FLINK_HOME:-${REPO_ROOT}/flink-1.20.3}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Fluss + Flink Kind Cluster Demo ===${NC}\n"

# Step 1: Build demo JAR
if [ ! -f "${DEMO_JAR}" ]; then
    echo -e "${YELLOW}[1/6] Building demo JAR...${NC}"
    mvn -f "${DEMO_DIR}/pom.xml" clean package -Dfluss.version="${FLUSS_VERSION}"
else
    echo -e "${GREEN}[1/6] Demo JAR already exists, skipping build${NC}"
fi

# Step 2: Deploy Fluss on Kind
echo -e "\n${YELLOW}[2/6] Deploying Fluss on Kind cluster...${NC}"
if kind get clusters | grep -q "^${KIND_NAME}$"; then
    echo -e "${YELLOW}Kind cluster '${KIND_NAME}' already exists. Delete it first with:${NC}"
    echo -e "  ${RED}kind delete cluster --name ${KIND_NAME}${NC}"
    exit 1
fi

"${SCRIPT_DIR}/k8s/deploy_fluss_kind.sh"

# Wait a bit for services to stabilize
echo -e "\n${YELLOW}Waiting for Fluss to be ready...${NC}"
sleep 10

# Fix: Patch coordinator to advertise IPv4 IP instead of hostname to prevent IPv6 resolution issues
echo -e "\n${YELLOW}Patching coordinator to use IPv4 addresses...${NC}"
kubectl patch statefulset coordinator-server --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command/2", "value": "export FLUSS_SERVER_ID=${POD_NAME##*-} && cp /opt/conf/server.yaml $FLUSS_HOME/conf && echo \"\" >> $FLUSS_HOME/conf/server.yaml && echo \"tablet-server.id: ${FLUSS_SERVER_ID}\" >> $FLUSS_HOME/conf/server.yaml && echo \"bind.listeners: INTERNAL://0.0.0.0:9122, CLIENT://0.0.0.0:9124\" >> $FLUSS_HOME/conf/server.yaml && echo \"advertised.listeners: CLIENT://${POD_IP}:9124\" >> $FLUSS_HOME/conf/server.yaml && bin/coordinator-server.sh start-foreground"}]' >/dev/null 2>&1
# Restart coordinator pod to apply the patch
kubectl delete pod coordinator-server-0 --wait=false >/dev/null 2>&1
# Wait for coordinator to be ready
kubectl wait --for=condition=Ready pod coordinator-server-0 --timeout=60s >/dev/null 2>&1
echo -e "${GREEN}✓ Coordinator patched to advertise IPv4 IP addresses${NC}"

# Set up port forwarding to coordinator service on port 9124
echo -e "\n${YELLOW}Setting up port forwarding to coordinator (port 9124)...${NC}"
kubectl port-forward svc/coordinator-server-hs 9124:9124 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

# Verify Fluss is accessible
echo -e "\n${YELLOW}[3/6] Verifying Fluss connectivity...${NC}"
if ! java -cp "${DEMO_JAR}" \
    org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussMetadataInspector localhost:9124 >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Fluss on localhost:9124${NC}"
    echo -e "${YELLOW}Check Fluss pods: kubectl get pods${NC}"
    kill $PORT_FORWARD_PID 2>/dev/null || true
    exit 1
fi
echo -e "${GREEN}✓ Fluss is accessible on localhost:9124${NC}"

# Step 3: Start Flink cluster
echo -e "\n${YELLOW}[4/6] Starting local Flink cluster...${NC}"
if [ ! -d "${FLINK_HOME}" ]; then
    echo -e "${RED}ERROR: Flink not found at ${FLINK_HOME}${NC}"
    exit 1
fi

if pgrep -f "flink.*standalonesession" >/dev/null; then
    echo -e "${GREEN}Flink cluster already running${NC}"
else
    "${FLINK_HOME}/bin/start-cluster.sh" >/dev/null 2>&1
    sleep 5
    echo -e "${GREEN}✓ Flink cluster started${NC}"
fi

# Step 4: Start producer in background
echo -e "\n${YELLOW}[5/6] Starting producer (background)...${NC}"
PRODUCER_LOG="${DEMO_DIR}/producer.log"
java -jar "${DEMO_JAR}" \
    --bootstrap localhost:9124 \
    --database iot \
    --table sensor_readings \
    --buckets 12 \
    --rate 2000 \
    --flush 5000 \
    --stats-interval 10 \
    > "${PRODUCER_LOG}" 2>&1 &
PRODUCER_PID=$!
echo -e "${GREEN}✓ Producer started (PID: ${PRODUCER_PID}, log: ${PRODUCER_LOG})${NC}"

# Wait a bit for producer to create table and start writing
sleep 5

# Step 5: Submit Flink job
echo -e "\n${YELLOW}[6/6] Submitting Flink aggregation job...${NC}"
FLINK_LOG="${DEMO_DIR}/flink-job.log"
"${FLINK_HOME}/bin/flink run" \
    -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob \
    "${DEMO_JAR}" \
    --bootstrap localhost:9124 \
    --database iot \
    --table sensor_readings \
    --window-minutes 1 \
    > "${FLINK_LOG}" 2>&1 &
FLINK_SUBMIT_PID=$!

# Wait a moment for job submission
sleep 3

# Check if job was submitted successfully
if grep -q "Job has been submitted" "${FLINK_LOG}" 2>/dev/null; then
    JOB_ID=$(grep "Job has been submitted" "${FLINK_LOG}" | grep -oE "JobID [a-f0-9]+" | awk '{print $2}')
    echo -e "${GREEN}✓ Flink job submitted (JobID: ${JOB_ID})${NC}"
    echo -e "${GREEN}  View job status: ${FLINK_HOME}/bin/flink list${NC}"
    echo -e "${GREEN}  View Flink UI: http://localhost:8081${NC}"
else
    echo -e "${RED}ERROR: Flink job submission may have failed. Check ${FLINK_LOG}${NC}"
fi

# Summary
echo -e "\n${GREEN}=== Demo is running! ===${NC}\n"
echo -e "Producer:"
echo -e "  PID: ${PRODUCER_PID}"
echo -e "  Log: tail -f ${PRODUCER_LOG}"
echo -e "  Stop: kill ${PRODUCER_PID}"
echo -e ""
echo -e "Flink Job:"
echo -e "  Log: tail -f ${FLINK_LOG}"
echo -e "  Status: ${FLINK_HOME}/bin/flink list"
echo -e "  UI: http://localhost:8081"
echo -e "  TaskManager logs: tail -f ${FLINK_HOME}/log/flink-*-taskexecutor-*.log"
echo -e ""
echo -e "Fluss (Kind):"
echo -e "  Check pods: kubectl get pods"
echo -e "  Coordinator logs: kubectl logs -l app=fluss-coordinator --tail=50 -f"
echo -e "  Tablet server logs: kubectl logs -l app=fluss-tablet-server --tail=50 -f"
echo -e ""
echo -e "Inspect Fluss data:"
echo -e "  java -cp ${DEMO_JAR} org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussMetadataInspector localhost:9124"
echo -e ""
echo -e "${YELLOW}To stop everything:${NC}"
echo -e "  1. kill ${PRODUCER_PID}"
echo -e "  2. kill ${PORT_FORWARD_PID}  # Stop port forwarding"
echo -e "  3. ${FLINK_HOME}/bin/flink cancel <JobID>"
echo -e "  4. ${FLINK_HOME}/bin/stop-cluster.sh"
echo -e "  5. kind delete cluster --name ${KIND_NAME}"

