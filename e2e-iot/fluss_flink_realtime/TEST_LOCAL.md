<!--
 Licensed to the Apache Software Foundation (ASF) under one or more
 contributor license agreements.  See the NOTICE file distributed with
 this work for additional information regarding copyright ownership.
 The ASF licenses this file to You under the Apache License, Version 2.0
 (the "License"); you may not use this file except in compliance with
 the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
-->


# Local Testing Guide

This guide explains how to test the Fluss producer and Flink job locally with the minimal schema.

## Prerequisites

Paths in this guide assume the `fluss-benchmarks` repository root. The E2E IoT benchmark lives under `e2e-iot/`; the demo module is at `e2e-iot/fluss_flink_realtime`.

1. **Maven** - For building the JAR
2. **Fluss** - Extracted to `$FLUSS_HOME/` or `fluss-<version>` under the repo root (default version: `0.9.0-incubating`)
3. **Flink 1.20.3** (optional) - For running Flink job locally
4. **Java 11+** - For running Java applications

Set the Fluss version via `default.env.sh` or export `FLUSS_VERSION` before running tests:

```bash
cd e2e-iot
source ./default.env.sh --fluss-version 0.9.0-incubating
export FLUSS_HOME=/path/to/fluss-${FLUSS_VERSION}   # optional
```

## Quick Test (Automated)

Run the automated test script:

```bash
cd e2e-iot/fluss_flink_realtime
./test-local.sh
```

This script will:
1. Build the demo JAR
2. Start Fluss local cluster
3. Create table with 48 buckets
4. Start producer (instance 0, 100K devices)
5. Start Flink aggregation job (if Flink is available)

## Manual Testing (Step-by-Step)

### Step 1: Build the JAR

```bash
cd e2e-iot/fluss_flink_realtime
mvn -f pom.xml clean package
```

### Step 2: Start Fluss Local Cluster

```bash
cd $FLUSS_HOME
./bin/local-cluster.sh start
```

Wait for Fluss to be ready (check coordinator on port 9123):
```bash
# Wait until this succeeds
nc -z localhost 9123
```

### Step 3: Create Table with 48 Buckets

```bash
cd e2e-iot/fluss_flink_realtime
java --add-opens=java.base/java.util=ALL-UNNAMED \
     --add-opens=java.base/java.lang=ALL-UNNAMED \
     --add-opens=java.base/java.nio=ALL-UNNAMED \
     --add-opens=java.base/java.time=ALL-UNNAMED \
     -cp target/fluss-flink-realtime-demo.jar \
     org.apache.fluss.benchmark.e2eplatformaws.setup.CreateTableWithBuckets \
     localhost:9123 iot sensor_readings 48 true
```

### Step 4: Start Producer

**Single instance (100K devices):**
```bash
java --add-opens=java.base/java.util=ALL-UNNAMED \
     --add-opens=java.base/java.lang=ALL-UNNAMED \
     --add-opens=java.base/java.nio=ALL-UNNAMED \
     --add-opens=java.base/java.time=ALL-UNNAMED \
     -cp target/fluss-flink-realtime-demo.jar \
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
     --stats-interval 10
```

**Multiple instances (4 instances, 25K devices each):**

Terminal 1 (Instance 0):
```bash
java --add-opens=java.base/java.util=ALL-UNNAMED \
     --add-opens=java.base/java.lang=ALL-UNNAMED \
     --add-opens=java.base/java.nio=ALL-UNNAMED \
     --add-opens=java.base/java.time=ALL-UNNAMED \
     -cp target/fluss-flink-realtime-demo.jar \
     org.apache.fluss.benchmark.e2eplatformaws.producer.FlussSensorProducerAppMultiInstance \
     --bootstrap localhost:9123 \
     --database iot \
     --table sensor_readings \
     --buckets 48 \
     --total-producers 4 \
     --instance-id 0 \
     --rate 50000 \
     --writer-threads 4
```

Terminal 2 (Instance 1):
```bash
# Same command but --instance-id 1
--instance-id 1
```

Terminal 3 (Instance 2):
```bash
# Same command but --instance-id 2
--instance-id 2
```

Terminal 4 (Instance 3):
```bash
# Same command but --instance-id 3
--instance-id 3
```

### Step 5: Start Flink Job

**If Flink is installed locally:**

```bash
# Start Flink cluster (if not running)
$FLINK_HOME/bin/start-cluster.sh

# Submit Flink job (run from e2e-iot/fluss_flink_realtime)
$FLINK_HOME/bin/flink run \
    -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob \
    target/fluss-flink-realtime-demo.jar \
    --bootstrap localhost:9123 \
    --database iot \
    --table sensor_readings \
    --window-minutes 1
```

**View Flink UI:**
- Open http://localhost:8081 in browser
- Check job status and metrics

### Step 6: Verify Data

**Check Fluss table:**
```bash
java --add-opens=java.base/java.util=ALL-UNNAMED \
     --add-opens=java.base/java.lang=ALL-UNNAMED \
     --add-opens=java.base/java.nio=ALL-UNNAMED \
     --add-opens=java.base/java.time=ALL-UNNAMED \
     -cp target/fluss-flink-realtime-demo.jar \
     org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussTableLogPeek localhost:9123 iot sensor_readings 10
```

**Check Flink job output:**
- The Flink job will print aggregated records every 20,000 records
- Check Flink UI for job metrics and backpressure

## Schema Verification

The producer writes only these 8 fields to Fluss:
- `sensor_id` (INT)
- `sensor_type` (INT)
- `temperature` (DOUBLE)
- `humidity` (DOUBLE)
- `pressure` (DOUBLE)
- `battery_level` (DOUBLE)
- `status` (INT)
- `timestamp` (BIGINT)

The Flink job reads these fields and adds default values for the remaining full sensor schema fields at the sink.

## Cleanup

```bash
# Stop producer (Ctrl+C or kill PID)

# Stop Flink cluster
cd $FLINK_HOME
./bin/stop-cluster.sh

# Stop Fluss cluster
cd $FLUSS_HOME
./bin/local-cluster.sh stop
```

