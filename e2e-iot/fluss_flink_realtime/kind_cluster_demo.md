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


# Fluss + Flink Demo on Kind Kubernetes Cluster

This guide walks through deploying Fluss on a local Kind cluster and running the producer + Flink aggregator job against it.

## Quick Start (Automated)

For a fully automated setup, run:

```bash
cd e2e-iot/fluss_flink_realtime
./run_kind_demo.sh
```

This script will:
1. Build the demo JAR
2. Deploy Fluss on Kind
3. Start local Flink cluster
4. Start the producer
5. Submit the Flink aggregation job

See the script output for monitoring commands and cleanup instructions.

## Manual Setup (Step-by-Step)

## Prerequisites

- Docker Desktop (or Docker Engine) running
- `kind` CLI installed (`brew install kind` or see https://kind.sigs.k8s.io/)
- `kubectl` CLI installed
- `helm` CLI installed (`brew install helm`)
- Maven installed (for building the demo jar)
- Flink 1.20.3 installed locally (for running Flink jobs)

## Step 1: Build the Demo JAR

From the `fluss-benchmarks` repository root:

```bash
mvn -f e2e-iot/fluss_flink_realtime/pom.xml clean package
```

Output: `e2e-iot/fluss_flink_realtime/target/fluss-flink-realtime-demo.jar`

## Step 2: Deploy Fluss on Kind

From `e2e-iot/fluss_flink_realtime`:

```bash
# Deploy Fluss on Kind (this script creates the cluster, deploys ZooKeeper, and installs Fluss)
./k8s/deploy_fluss_kind.sh
```

This script will:
1. Create a Kind cluster named `fluss-kind`
2. Deploy ZooKeeper
3. Install Fluss via Helm chart
4. Expose Fluss on `localhost:9123` (via port mapping)

Wait for all pods to be ready:

```bash
kubectl get pods -n default
# Wait until all pods show STATUS=Running and READY=1/1
```

Verify Fluss is accessible:

```bash
# Check Fluss service
kubectl get svc -n default | grep fluss

# Test connectivity (should return metadata)
java -cp e2e-iot/fluss_flink_realtime/target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussMetadataInspector localhost:9123
```

## Step 3: Start Local Flink Cluster

From the `fluss-benchmarks` repository root:

```bash
$FLINK_HOME/bin/start-cluster.sh
```

Verify Flink is running:

```bash
# Check Flink Web UI (should be accessible at http://localhost:8081)
curl http://localhost:8081/overview
```

## Step 4: Run the Producer (Terminal 1)

From the `fluss-benchmarks` repository root, start the producer that writes to Fluss on Kind:

```bash
java -jar e2e-iot/fluss_flink_realtime/target/fluss-flink-realtime-demo.jar \
  --bootstrap localhost:9123 \
  --database iot \
  --table sensor_readings \
  --buckets 12 \
  --rate 2000 \
  --flush 5000 \
  --stats-interval 10
```

The producer will:
- Create the `iot.sensor_readings` table in Fluss (if it doesn't exist)
- Continuously generate and upsert sensor data
- Log throughput statistics every 1000 records

**Note:** Keep this running. Press `Ctrl+C` to stop when done.

## Step 5: Run the Flink Aggregation Job (Terminal 2)

From the `fluss-benchmarks` repository root, in a **separate terminal**, submit the Flink job:

```bash
$FLINK_HOME/bin/flink run \
  -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob \
  e2e-iot/fluss_flink_realtime/target/fluss-flink-realtime-demo.jar \
  --bootstrap localhost:9123 \
  --database iot \
  --table sensor_readings \
  --window-minutes 1
```

The Flink job will:
- Read changelog events from the Fluss primary-key table
- Filter for INSERT/UPDATE_AFTER events
- Aggregate by sensor ID in 1-minute tumbling windows
- Print aggregated results to TaskManager logs

## Step 6: Monitor the Pipeline

### View Flink Job Status

```bash
# List running jobs
$FLINK_HOME/bin/flink list

# View job details in Web UI
open http://localhost:8081
```

### View Flink TaskManager Logs

```bash
# Find the TaskManager log file
tail -f $FLINK_HOME/log/flink-*-taskexecutor-*.log

# Or view aggregated output
grep "SensorAggregate" $FLINK_HOME/log/flink-*-taskexecutor-*.log
```

### Inspect Fluss Data

```bash
# List databases
java -cp e2e-iot/fluss_flink_realtime/target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussMetadataInspector localhost:9123

# Peek at change log (while producer is running)
java --add-opens=java.base/java.nio=ALL-UNNAMED \
  -cp e2e-iot/fluss_flink_realtime/target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussTableLogPeek localhost:9123 iot sensor_readings 10

# Peek at primary-key snapshot
java --add-opens=java.base/java.nio=ALL-UNNAMED \
  -cp e2e-iot/fluss_flink_realtime/target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussPrimaryKeySnapshotPeek localhost:9123 iot sensor_readings 10
```

### View Fluss Pod Logs

```bash
# Coordinator logs
kubectl logs -n default -l app=fluss-coordinator --tail=50 -f

# Tablet server logs
kubectl logs -n default -l app=fluss-tablet-server --tail=50 -f
```

## Step 7: Cleanup

### Stop the Producer and Flink Job

1. Press `Ctrl+C` in the producer terminal (Terminal 1)
2. Cancel the Flink job:
   ```bash
   $FLINK_HOME/bin/flink cancel <JobID>
   # Or list and cancel: $FLINK_HOME/bin/flink list
   ```

### Stop Local Flink Cluster

```bash
$FLINK_HOME/bin/stop-cluster.sh
```

### Delete Kind Cluster

```bash
# Delete the entire Kind cluster (this removes all Fluss pods and data)
kind delete cluster --name fluss-kind
```

Or use the cleanup script if available:

```bash
# If you have a cleanup script
./cleanup_fluss_kind.sh
```

## Troubleshooting

### Fluss Not Accessible on localhost:9123

```bash
# Check if port mapping is correct
kubectl get svc -n default | grep fluss

# Check if Fluss pods are running
kubectl get pods -n default | grep fluss

# Check Fluss coordinator logs
kubectl logs -n default -l app=fluss-coordinator --tail=100
```

### Flink Job Fails to Connect

- Verify Fluss is accessible: `java -cp ... FlussMetadataInspector localhost:9123`
- Check Flink TaskManager logs for connection errors
- Ensure the bootstrap address is `localhost:9123` (not `localhost:9124`)

### Producer Not Writing Data

- Check producer logs for errors
- Verify Fluss table exists: `FlussMetadataInspector localhost:9123 iot`
- Check Fluss tablet server logs: `kubectl logs -l app=fluss-tablet-server --tail=50`

### Flink Job Shows No Output

- Ensure producer is running and generating data
- Check Flink TaskManager logs for errors
- Verify the job is reading from the correct table: `--database iot --table sensor_readings`
- Check if watermarks are advancing (may need to wait for window to close)

## Architecture Overview

```
┌─────────────────┐
│  Producer App   │ (Local JVM)
│  (Terminal 1)   │
└────────┬────────┘
         │ writes via Fluss Java SDK
         ▼
┌─────────────────────────────────┐
│  Kind Cluster                   │
│  ┌───────────────────────────┐ │
│  │ Fluss Coordinator         │ │
│  │ (port 9123 → localhost)   │ │
│  └───────────────────────────┘ │
│  ┌───────────────────────────┐ │
│  │ Fluss Tablet Servers (x3) │ │
│  │ - Stores primary-key data │ │
│  │ - Maintains change log    │ │
│  └───────────────────────────┘ │
│  ┌───────────────────────────┐ │
│  │ ZooKeeper                 │ │
│  └───────────────────────────┘ │
└────────┬─────────────────────────┘
         │ reads changelog stream
         ▼
┌─────────────────┐
│  Flink Job      │ (Local Flink Cluster)
│  (Terminal 2)   │
│  - Aggregates   │
│  - Prints       │
└─────────────────┘
```

## Next Steps

- Increase producer rate: `--rate 5000` or `--rate 10000`
- Adjust window size: `--window-minutes 5` for 5-minute windows
- Scale Fluss tablet servers: Edit Helm values and upgrade
- Add more Flink jobs reading from the same Fluss table
- Write Flink output to another Fluss table or external sink

