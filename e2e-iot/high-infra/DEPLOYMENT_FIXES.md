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


# Deployment Fixes Documentation

## Issues Fixed

### 1. Grafana Dashboard Not Deployed

**Problem:**
- The `deploy.sh` script was applying the Grafana dashboard ConfigMap but not importing it via the Grafana API
- This meant the dashboard ConfigMap existed but wasn't visible in Grafana UI
- Users had to manually run `deploy-dashboard.sh` separately

**Root Cause:**
- The `deploy.sh` script only ran `kubectl apply` on the ConfigMap
- Grafana's auto-discovery can be slow or unreliable
- The separate `deploy-dashboard.sh` script imports via API for immediate visibility

**Fix Applied:**
- Updated `deploy.sh` step 8 to:
  1. Apply the ConfigMap (as before)
  2. Wait for Grafana pod to be ready
  3. Extract dashboard JSON from ConfigMap
  4. Import dashboard via Grafana REST API (`/api/dashboards/db`)
  5. Verify import success

**Location:**
- File: `k8s/deploy.sh`
- Step: `[8/9] Deploying Grafana dashboard...`

**Result:**
- Dashboard is now automatically imported and visible immediately after deployment
- Falls back gracefully if Grafana pod isn't ready or API import fails

---

### 2. Producer Deployment Issues

**Problem 1: JAR Path Incorrect**
- Initial JAR path: `/app/fluss-flink-realtime-demo.jar`
- Issue: The `fluss-demo` Docker image places the JAR at `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
- Error: `Error: Unable to access jarfile /app/fluss-flink-realtime-demo.jar`

**Fix:**
- Updated `producer-job.yaml` args to use: `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`

**Problem 2: Entrypoint Script Missing**
- Initial command: `/app/entrypoint.sh`
- Issue: The `fluss-demo` Docker image doesn't include an entrypoint script
- Error: `exec: "/app/entrypoint.sh": stat /app/entrypoint.sh: no such file or directory`

**Fix:**
- Updated `producer-job.yaml` command to: `java` (direct execution)
- Updated args to: `-jar /opt/flink/usrlib/fluss-flink-realtime-demo.jar`

**Problem 3: InitContainer Environment Variable Substitution**
- Initial setup: Used `${COORD_HOST}` and `${COORD_PORT}` environment variables
- Issue: `envsubst` was replacing these variables before Kubernetes could inject them
- Error: `nc -zv "" ""` (empty hostname and port)

**Fix:**
- Hardcoded coordinator hostname in initContainer script: `coordinator-server-hs.fluss.svc.cluster.local:9124`
- This avoids `envsubst` substitution issues

**Problem 4: Missing Environment Variable Defaults**
- Issue: When `deploy.sh` runs without setting producer environment variables, `envsubst` leaves literal `${PRODUCER_RATE}` etc. in the YAML
- Error: Kubernetes rejects the YAML with invalid resource values

**Fix:**
- Updated `deploy.sh` step 6 to set default values for all producer environment variables before applying `producer-job.yaml`
- Defaults match those in `deploy-producer.sh`:
  - `PRODUCER_RATE=2000`
  - `PRODUCER_FLUSH_EVERY=20000`
  - `PRODUCER_STATS_EVERY=1000`
  - `CLIENT_WRITER_BUFFER_MEMORY_SIZE=128mb`
  - `CLIENT_WRITER_BATCH_SIZE=16mb`
  - `PRODUCER_MEMORY_REQUEST=2Gi`
  - `PRODUCER_MEMORY_LIMIT=8Gi`
  - `PRODUCER_CPU_REQUEST=1000m`
  - `PRODUCER_CPU_LIMIT=4000m`
  - `BOOTSTRAP=coordinator-server-hs.fluss.svc.cluster.local:9124`
  - `DATABASE=iot`
  - `TABLE=sensor_readings`
  - `BUCKETS=12`

**Location:**
- File: `k8s/jobs/producer-job.yaml` (JAR path, command fixes)
- File: `k8s/deploy.sh` (default values)
- File: `k8s/jobs/deploy-producer.sh` (already had defaults)

**Result:**
- Producer job can be deployed via `deploy.sh` without manual configuration
- Producer job can also be deployed via `deploy-producer.sh` with custom values
- Both methods work reliably

---

## Summary of Changes

### Files Modified:

1. **`k8s/deploy.sh`**
   - Added Grafana API import step after ConfigMap deployment
   - Added default environment variable values for producer deployment
   - Updated step numbering (now 9 steps instead of 8)

2. **`k8s/jobs/producer-job.yaml`**
   - Fixed JAR path: `/app/fluss-flink-realtime-demo.jar` → `/opt/flink/usrlib/fluss-flink-realtime-demo.jar`
   - Fixed command: `/app/entrypoint.sh` → `java`
   - Fixed initContainer: Hardcoded coordinator hostname

### Files Already Correct:

- **`k8s/jobs/deploy-producer.sh`**: Already had proper defaults and error handling
- **`k8s/monitoring/deploy-dashboard.sh`**: Already had API import logic

---

## Testing

To verify the fixes:

1. **Dashboard Deployment:**
   ```bash
   cd e2e-iot/high-infra/k8s
   ./deploy.sh fluss <demo-image-repo> latest <fluss-image-repo>
   # Wait for deployment to complete
   kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
   # Open http://localhost:3000 and verify "Fluss & Flink Monitoring Dashboard" is visible
   ```

2. **Producer Deployment:**
   ```bash
   # Via deploy.sh (uses defaults)
   cd e2e-iot/high-infra/k8s
   ./deploy.sh fluss <demo-image-repo> latest <fluss-image-repo>
   # Check producer pod
   kubectl get pods -n fluss -l app=fluss-producer
   kubectl logs -n fluss -l app=fluss-producer
   
   # Via deploy-producer.sh (custom values)
   cd e2e-iot/high-infra/k8s/jobs
   ./deploy-producer.sh --rate 20000 --buckets 3
   ```

---

## Future Improvements

1. **Dashboard Auto-Discovery:**
   - Consider using Grafana's sidecar pattern for automatic dashboard discovery
   - This would eliminate the need for API import

2. **Producer Configuration:**
   - Consider using a ConfigMap for producer configuration instead of environment variables
   - This would make configuration changes easier without redeploying

3. **Error Handling:**
   - Add retry logic for Grafana API import
   - Add validation for producer environment variables before deployment

