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


# Fluss + Flink Demo Verification Steps

## Prerequisites
- Kind cluster will be created automatically
- Docker must be running
- kubectl must be installed
- Maven must be installed (for building JAR)

## Step-by-Step Instructions

**Note:** Paths assume the `fluss-benchmarks` repository root. The E2E IoT benchmark lives under `e2e-iot/`; the demo module is at `e2e-iot/fluss_flink_realtime`.

### Step 1: Deploy Fluss on Kind Cluster
This script will:
- Create a new Kind cluster
- Deploy Fluss coordinator and tablet servers
- Patch coordinator to use IPv4 addresses
- Wait for services to be ready

```bash
cd e2e-iot/fluss_flink_realtime
./run_kind_demo.sh
```

**Expected output:**
- Kind cluster created
- Fluss pods running (coordinator-server-0, tablet-server-0, tablet-server-1, tablet-server-2)
- Coordinator patched to advertise IPv4 IP addresses
- Fluss accessible on localhost:9123

**Wait for:** All Fluss pods to be in `Running` state:
```bash
kubectl get pods
# Should show coordinator-server-0 and tablet-server-* pods as Running
```

---

### Step 2: Build and Deploy Producer + Flink Aggregator Jobs
This script will:
- Build the demo JAR (if needed)
- Build Docker image with all fixes
- Load image into Kind cluster
- Deploy producer and Flink aggregator as Kubernetes Jobs

```bash
cd e2e-iot/fluss_flink_realtime
./k8s/deploy_k8s_jobs.sh
```

**Expected output:**
- JAR built successfully
- Docker image built
- Image loaded into Kind
- Producer job created
- Flink aggregator job created

---

### Step 3: Verify Everything is Running

#### Check Job Status
```bash
kubectl get jobs
# Should show:
# - fluss-producer: 1/1 completions
# - flink-aggregator: 1/1 completions (or Running)
```

#### Check Pod Status
```bash
kubectl get pods
# Should show:
# - fluss-producer-*: Running or Completed
# - flink-aggregator-*: Running
# - coordinator-server-0: Running
# - tablet-server-*: Running
```

#### Check Producer Logs
```bash
kubectl logs -l app=fluss-producer --tail=50 -f
```

**Expected output:**
- "Producer started"
- "Writing sensor data..."
- Statistics showing records written
- No IPv6 errors
- No connection errors

#### Check Flink Aggregator Logs
```bash
kubectl logs -l app=flink-aggregator --tail=50 -f
```

**Expected output:**
- "Flink Sensor Aggregation Job started"
- "Resolved coordinator-server-hs.default.svc.cluster.local to IPv4 via DNS: 10.244.x.x"
- Windowed aggregation results like:
  ```
  SensorAggregate{sensorId=sensor-000001, window=[2025-11-18T...], avgTemp=20.5, ...}
  ```
- No `InaccessibleObjectException` errors
- No `ClassNotFoundException` errors
- Job running continuously

---

### Step 4: Monitor Aggregation Results

Watch the Flink aggregator output:
```bash
kubectl logs -l app=flink-aggregator -f | grep "SensorAggregate"
```

**Expected:** Continuous stream of aggregated sensor data with:
- Sensor IDs
- Time windows (1-minute intervals)
- Average temperature, humidity, pressure, battery
- Sensor status (ONLINE, OFFLINE, DEGRADED, MAINTENANCE)

---

### Step 5: Verify Fixes Applied

#### Check IPv4 Configuration
```bash
kubectl logs -l app=flink-aggregator | grep -i "ipv4\|resolved"
# Should show IPv4 resolution messages
```

#### Check Java Module Opens
```bash
kubectl logs -l app=flink-aggregator | grep "entrypoint"
# Should show: --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.time=ALL-UNNAMED
```

#### Check Coordinator Advertised Listeners
```bash
kubectl logs coordinator-server-0 | grep "advertised.listeners"
# Should show: advertised.listeners: CLIENT://10.244.x.x:9124 (IPv4 IP, not hostname)
```

---

## Troubleshooting

### If producer fails:
1. Check logs: `kubectl logs -l app=fluss-producer`
2. Check coordinator: `kubectl logs coordinator-server-0`
3. Verify coordinator is ready: `kubectl get pod coordinator-server-0`

### If Flink aggregator fails:
1. Check logs: `kubectl logs -l app=flink-aggregator`
2. Look for specific error messages
3. Verify all pods are running: `kubectl get pods`

### If you see IPv6 errors:
1. Verify coordinator patch: `kubectl get statefulset coordinator-server -o yaml | grep advertised`
2. Check entrypoint.sh has IPv4 properties
3. Restart coordinator: `kubectl delete pod coordinator-server-0`

### If you see ClassNotFoundException:
1. Rebuild JAR: `cd e2e-iot/fluss_flink_realtime && mvn -f pom.xml clean package`
2. Rebuild Docker image: `cd e2e-iot/fluss_flink_realtime && docker build -t fluss-demo:latest .`
3. Reload into Kind: `kind load docker-image fluss-demo:latest --name fluss-kind`
4. Redeploy jobs: `cd e2e-iot/fluss_flink_realtime && kubectl delete job fluss-producer flink-aggregator && ./k8s/deploy_k8s_jobs.sh`

---

## Cleanup

To stop and clean up everything:

```bash
# Delete Kubernetes jobs
kubectl delete job fluss-producer flink-aggregator

# Delete Kind cluster (this removes everything)
kind delete cluster --name fluss-kind
```

---

## Success Criteria

✅ All pods running without errors
✅ Producer writing data continuously
✅ Flink aggregator processing and outputting windowed aggregations
✅ No IPv6 connection errors
✅ No Java module access errors
✅ No missing class errors
✅ Aggregation results appearing every minute

