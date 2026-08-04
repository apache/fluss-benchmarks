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

# Local test script for Fluss producer and Flink job
# Tests the minimal schema with default values added at sink

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${DEMO_DIR}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Local Fluss + Flink Test ===${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}[1/7] Checking prerequisites...${NC}"
if ! command -v mvn &> /dev/null; then
    echo -e "${RED}ERROR: Maven not found. Please install Maven.${NC}"
    exit 1
fi

FLUSS_VERSION="${FLUSS_VERSION:-0.9.0-incubating}"
FLUSS_DIR="${FLUSS_HOME:-${REPO_ROOT}/fluss-${FLUSS_VERSION}}"
if [ ! -d "${FLUSS_DIR}" ]; then
    echo -e "${RED}ERROR: Fluss ${FLUSS_VERSION} not found at ${FLUSS_DIR}${NC}"
    echo "Extract fluss-${FLUSS_VERSION}.tgz there or set FLUSS_HOME to your Fluss install"
    exit 1
fi
JAR_PATH="${DEMO_DIR}/target/fluss-flink-realtime-demo.jar"

# Build the JAR
echo -e "${YELLOW}[2/7] Building demo JAR...${NC}"
mvn -f "${DEMO_DIR}/pom.xml" clean package -DskipTests -Dfluss.version="${FLUSS_VERSION}"
if [ ! -f "${JAR_PATH}" ]; then
    echo -e "${RED}ERROR: JAR not found at ${JAR_PATH}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ JAR built successfully${NC}"
echo ""

# Start Fluss local cluster
echo -e "${YELLOW}[3/7] Starting Fluss local cluster...${NC}"
if [ -f "${FLUSS_DIR}/bin/local-cluster.sh" ]; then
    # Check if already running
    if pgrep -f "fluss.*coordinator" > /dev/null; then
        echo -e "${YELLOW}Fluss cluster appears to be running. Skipping start.${NC}"
    else
        "${FLUSS_DIR}/bin/local-cluster.sh" start
        echo "Waiting for Fluss to be ready..."
        sleep 10
        # Wait for coordinator to be ready
        for i in {1..30}; do
            if nc -z localhost 9123 2>/dev/null; then
                echo -e "${GREEN}✓ Fluss coordinator is ready${NC}"
                break
            fi
            if [ $i -eq 30 ]; then
                echo -e "${RED}ERROR: Fluss coordinator not ready after 30 seconds${NC}"
                exit 1
            fi
            sleep 1
        done
    fi
else
    echo -e "${RED}ERROR: Fluss local-cluster.sh not found${NC}"
    exit 1
fi
echo ""

# Create table with 48 buckets
echo -e "${YELLOW}[4/7] Creating Fluss table with 48 buckets...${NC}"
java --add-opens=java.base/java.util=ALL-UNNAMED \
     --add-opens=java.base/java.lang=ALL-UNNAMED \
     --add-opens=java.base/java.nio=ALL-UNNAMED \
     --add-opens=java.base/java.time=ALL-UNNAMED \
     -cp "${JAR_PATH}" \
     org.apache.fluss.benchmark.e2eplatformaws.setup.CreateTableWithBuckets \
     localhost:9123 iot sensor_readings 48 true

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Table created successfully${NC}"
else
    echo -e "${RED}ERROR: Failed to create table${NC}"
    exit 1
fi
echo ""

# Verify table exists
echo -e "${YELLOW}[5/7] Verifying table exists...${NC}"
java --add-opens=java.base/java.util=ALL-UNNAMED \
     --add-opens=java.base/java.lang=ALL-UNNAMED \
     --add-opens=java.base/java.nio=ALL-UNNAMED \
     --add-opens=java.base/java.time=ALL-UNNAMED \
     -cp "${JAR_PATH}" \
     org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussMetadataInspector localhost:9123 iot 2>/dev/null | grep -q "sensor_readings" && \
     echo -e "${GREEN}✓ Table verified${NC}" || echo -e "${YELLOW}Warning: Could not verify table${NC}"
echo ""

# Start producer (instance 0 of 1)
echo -e "${YELLOW}[6/7] Starting producer (instance 0 of 1, 100K devices)...${NC}"
echo "Producer will run in background. Press Ctrl+C to stop."
echo ""
java --add-opens=java.base/java.util=ALL-UNNAMED \
     --add-opens=java.base/java.lang=ALL-UNNAMED \
     --add-opens=java.base/java.nio=ALL-UNNAMED \
     --add-opens=java.base/java.time=ALL-UNNAMED \
     -cp "${JAR_PATH}" \
     org.apache.fluss.benchmark.e2eplatformaws.producer.FlussSensorProducerAppMultiInstance \
     --bootstrap localhost:9123 \
     --database iot \
     --table sensor_readings \
     --buckets 48 \
     --total-producers 1 \
     --instance-id 0 \
     --rate 10000 \
     --writer-threads 4 \
     --flush 10000 \
     --stats-interval 10 &
PRODUCER_PID=$!

echo "Producer PID: ${PRODUCER_PID}"
echo "Waiting 10 seconds for producer to start generating data..."
sleep 10
echo ""

# Check if Flink is available
FLINK_DIR="${FLINK_HOME:-${REPO_ROOT}/flink-1.20.3}"
if [ ! -d "${FLINK_DIR}" ]; then
    echo -e "${YELLOW}[7/7] Flink not found at ${FLINK_DIR}${NC}"
    echo "Skipping Flink job. You can run it manually:"
    echo ""
    echo "  ${FLINK_DIR}/bin/flink run \\"
    echo "    -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob \\"
    echo "    ${JAR_PATH} \\"
    echo "    --bootstrap localhost:9123 --database iot --table sensor_readings --window-minutes 1"
    echo ""
    echo -e "${GREEN}✓ Producer is running (PID: ${PRODUCER_PID})${NC}"
    echo "To stop the producer: kill ${PRODUCER_PID}"
    echo "To stop Fluss: ${FLUSS_DIR}/bin/local-cluster.sh stop"
    exit 0
fi

# Start Flink job
echo -e "${YELLOW}[7/7] Starting Flink aggregation job...${NC}"
echo "Flink job will read from Fluss and add default values at sink level"
echo ""

# Check if Flink cluster is running
if ! nc -z localhost 8081 2>/dev/null; then
    echo -e "${YELLOW}Starting Flink cluster...${NC}"
    "${FLINK_DIR}/bin/start-cluster.sh"
    sleep 5
fi

# Submit Flink job
"${FLINK_DIR}/bin/flink run" \
    -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob \
    "${JAR_PATH}" \
    --bootstrap localhost:9123 \
    --database iot \
    --table sensor_readings \
    --window-minutes 1

FLINK_EXIT_CODE=$?

echo ""
echo -e "${GREEN}=== Test Summary ===${NC}"
echo "Producer PID: ${PRODUCER_PID}"
echo "Flink Job Exit Code: ${FLINK_EXIT_CODE}"
echo ""
echo "To stop producer: kill ${PRODUCER_PID}"
echo "To stop Fluss: ${FLUSS_DIR}/bin/local-cluster.sh stop"
echo "To stop Flink: ${FLINK_DIR}/bin/stop-cluster.sh"
echo ""
echo "To view Flink UI: http://localhost:8081"
echo "To check producer logs: Check console output above"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    if kill -0 ${PRODUCER_PID} 2>/dev/null; then
        echo "Stopping producer..."
        kill ${PRODUCER_PID} 2>/dev/null || true
    fi
    echo "Done. Fluss and Flink clusters are still running."
    echo "Stop them manually if needed."
}

trap cleanup EXIT INT TERM

# Wait for user interrupt
echo -e "${GREEN}Test is running. Press Ctrl+C to stop producer and exit.${NC}"
wait ${PRODUCER_PID}

