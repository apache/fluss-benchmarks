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


# Fluss Coordinator & Tablet Server Metrics Setup

## Overview

This document explains how to populate metrics for Fluss Coordinator and Tablet Servers in the Grafana dashboard.

## Current Configuration

### ✅ ServiceMonitors Configured
- **Coordinator**: `servicemonitors.yaml` includes `fluss-coordinator-metrics`
- **Tablet Servers**: `servicemonitors.yaml` includes `fluss-tablet-metrics`
- Both scrape port `9249`, path `/metrics`, interval `30s`

### ✅ Dashboard Panels Added
The dashboard now includes panels for:

**Coordinator Metrics:**
- Request Rate (requests/sec)
- Error Rate (errors/sec)
- Active Tablet Server Count
- Table Count
- Bucket Count
- Request Latency (p95)

**Tablet Server Metrics:**
- Messages In Rate (messages/sec)
- Bytes In/Out Rate (bytes/sec)
- Replication Rates (bytes/sec)
- Leader/Replica Counts

## How to Verify Metrics Are Being Scraped

### Step 1: Check ServiceMonitors
```bash
kubectl get servicemonitor -n fluss
kubectl describe servicemonitor -n fluss fluss-coordinator-metrics
kubectl describe servicemonitor -n fluss fluss-tablet-metrics
```

### Step 2: Check Prometheus Targets
1. Port-forward Prometheus:
   ```bash
   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
   ```
2. Open http://localhost:9090
3. Go to **Status > Targets**
4. Look for targets with labels:
   - `job="fluss/fluss-coordinator-metrics"`
   - `job="fluss/fluss-tablet-metrics"`
5. Verify they show as **UP** (green)

### Step 3: Query Metrics in Prometheus
In Prometheus UI, try these queries to find exact metric names:

**Find all Fluss coordinator metrics:**
```promql
{job=~"fluss.*coordinator.*"}
```

**Find all Fluss tablet metrics:**
```promql
{job=~"fluss.*tablet.*"}
```

**List all available metrics:**
```promql
{__name__=~"fluss.*"}
```

## Finding Exact Metric Names

Fluss metrics may be exposed with different naming conventions. Common patterns:

1. **CamelCase**: `fluss_coordinator_requestsPerSecond`
2. **Snake_case**: `fluss_coordinator_requests_per_second`
3. **With component prefix**: `fluss_coordinator_server_requests_per_second`

The dashboard queries include fallbacks for common patterns, but you may need to adjust based on actual metric names.

### How to Check Actual Metric Names

1. **Directly query Fluss metrics endpoint:**
   ```bash
   # Get coordinator pod
   COORD_POD=$(kubectl get pod -n fluss -l app.kubernetes.io/component=coordinator -o jsonpath='{.items[0].metadata.name}')
   
   # Port-forward metrics
   kubectl port-forward -n fluss $COORD_POD 9249:9249
   
   # Query metrics
   curl http://localhost:9249/metrics | grep fluss
   ```

2. **Check Prometheus metrics explorer:**
   - In Prometheus UI, go to **Graph**
   - Type `fluss` and use autocomplete to see available metrics

## Updating Dashboard Queries

If metrics don't appear, update the queries in the dashboard:

1. **Edit the dashboard JSON:**
   ```bash
   vim e2e-iot/high-infra/k8s/monitoring/fluss-flink-dashboard.json
   ```

2. **Find the panel** (e.g., "Fluss Coordinator - Request Rate")

3. **Update the `expr` field** with the correct metric name from Prometheus

4. **Redeploy dashboard:**
   ```bash
   cd e2e-iot/high-infra/k8s/monitoring
   ./deploy-dashboard.sh
   ```

## Common Issues

### Issue: Flink/Producer Metrics Work but Coordinator/Tablet Metrics Are Empty

**Root cause (fixed in helm chart):** Fluss servers did not enable the Prometheus metrics reporter, and
Kubernetes Services/StatefulSets did not expose port `9249` named `metrics`. ServiceMonitors reference
`port: metrics` — without that port on the Service, Prometheus has no scrape target.

**Fix:** Re-deploy Fluss with the updated helm chart (`high-infra/helm-charts/fluss`):
```bash
cd high-infra/k8s
# Re-apply PodMonitors (includes coordinator + tablet)
kubectl apply -f monitoring/podmonitors.yaml
kubectl apply -f monitoring/servicemonitors.yaml

# Upgrade Fluss (uses vendored chart with metrics support)
source ../default.env.sh --fluss-version 0.9.0-incubating
helm upgrade fluss ../helm-charts/fluss -n fluss \
  --reuse-values \
  --set configurationOverrides."metrics\.reporters"="prometheus" \
  --set configurationOverrides."metrics\.reporter\.prometheus\.port"="9249"

# Restart pods so they pick up the new server.yaml + metrics port
kubectl rollout restart sts/coordinator-server sts/tablet-server -n fluss
```

**Verify metrics endpoint directly:**
```bash
COORD_POD=$(kubectl get pod -n fluss -l app.kubernetes.io/component=coordinator -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n fluss "$COORD_POD" -- wget -qO- http://localhost:9249/metrics | grep fluss_coordinator | head
```

### Issue: Metrics Not Appearing
**Solution:**
1. Verify ServiceMonitor selector matches Service labels:
   ```bash
   kubectl get svc -n fluss -l app.kubernetes.io/component=coordinator
   kubectl get svc -n fluss -l app.kubernetes.io/component=tablet-server
   ```

2. Check if services have `metrics` port defined:
   ```bash
   kubectl get svc -n fluss coordinator-server-hs -o yaml | grep -A 5 ports
   ```

3. Verify pods expose metrics on port 9249:
   ```bash
   kubectl get pod -n fluss coordinator-server-0 -o yaml | grep -A 10 ports
   ```

### Issue: Wrong Metric Names
**Solution:**
1. Query Prometheus directly to find exact names
2. Update dashboard JSON with correct names
3. Redeploy dashboard

### Issue: ServiceMonitor Not Picking Up Services
**Solution:**
1. Check ServiceMonitor namespace matches Service namespace
2. Verify label selectors match exactly
3. Check Prometheus operator is running:
   ```bash
   kubectl get pods -n monitoring | grep prometheus-operator
   ```

## Expected Metrics

Based on Fluss source code, these metrics should be available:

### Coordinator Metrics:
- `requestsPerSecond` / `requests_per_second`
- `errorsPerSecond` / `errors_per_second`
- `activeTabletServerCount` / `active_tablet_server_count`
- `tableCount` / `table_count`
- `bucketCount` / `bucket_count`
- `totalTimeMs` / `total_time_ms` (histogram for latency)

### Tablet Server Metrics:
- `messagesInPerSecond` / `messages_in_per_second`
- `bytesInPerSecond` / `bytes_in_per_second`
- `bytesOutPerSecond` / `bytes_out_per_second`
- `replicationBytesInPerSecond` / `replication_bytes_in_per_second`
- `replicationBytesOutPerSecond` / `replication_bytes_out_per_second`
- `leaderCount` / `leader_count`
- `replicaCount` / `replica_count`

## Next Steps

1. Deploy the updated dashboard:
   ```bash
   cd e2e-iot/high-infra/k8s/monitoring
   ./deploy-dashboard.sh
   ```

2. Verify metrics appear in Grafana

3. If metrics don't appear, check Prometheus targets and update metric names as needed

4. Adjust queries based on actual metric names exposed by Fluss
