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


# Producer Throughput Drop Issue - Root Cause Analysis

## Problem Summary

**Date:** December 7, 2025  
**Issue:** Producer throughput dropped from 2M ops/sec to 1.4M ops/sec (and continued declining to ~0.92M ops/sec)  
**Status:** Resolved

## Symptoms

1. **Throughput Degradation:**
   - Expected: 2M ops/sec (8 producers × 250K ops/sec each)
   - Actual: Started at 1.4M ops/sec, dropped to 1.17M ops/sec, then to 0.92M ops/sec
   - Each producer achieving only ~145-150K ops/sec instead of 250K ops/sec

2. **Error Messages in Producer Logs:**
   ```
   [fluss-write-sender-thread-1] WARN org.apache.fluss.client.write.Sender - Get error write response on table bucket TableBucket{tableId=0, bucket=X}, retrying (2147482754 attempts left). Error: LEADER_NOT_AVAILABLE_EXCEPTION. Error Message: Server -1 is not found in metadata cache.
   ```

3. **DNS Resolution Errors:**
   ```
   org.apache.fluss.exception.NetworkException: Disconnected from node tablet-server-X.tablet-server-hs.fluss.svc.cluster.local:9124
   Caused by: java.net.UnknownHostException: tablet-server-X.tablet-server-hs.fluss.svc.cluster.local
   ```

4. **Coordinator Metrics:**
   - Initially showed: `activeTabletServerCount: 0`, `bucketCount: 0`
   - After restart: Eventually showed correct values but metadata cache was stale

## Root Cause

**Stale Metadata Cache in Fluss Coordinator**

The issue occurred after Fluss tablet servers were restarted:

1. **Timeline:**
   - Tablet servers were restarted (tablet-server-2 was newly started ~2 minutes before the issue)
   - Coordinator was restarted to refresh metadata
   - Coordinator initialized and discovered tablet servers via ZooKeeper
   - However, the coordinator's metadata cache became stale/inconsistent

2. **Why It Happened:**
   - When tablet servers restart, their registration in ZooKeeper changes
   - Coordinator reads tablet server information from ZooKeeper during initialization
   - But the coordinator's internal metadata cache (bucket-to-leader mappings) was not properly refreshed
   - Producers query the coordinator for bucket leader information
   - Coordinator returned stale metadata (Server -1 = invalid/not found)
   - Producers couldn't find bucket leaders → retries → reduced throughput

3. **Why ZooKeeper Was NOT the Issue:**
   - ZooKeeper was running fine
   - Coordinator successfully registered with ZooKeeper
   - Tablet servers were properly registered in ZooKeeper
   - The issue was in the coordinator's internal metadata cache, not ZooKeeper

## Investigation Steps

1. **Checked Producer Metrics:**
   - Each producer showing ~145-150K ops/sec instead of 250K
   - Total throughput: ~1.17M ops/sec (should be 2M)

2. **Checked Producer Logs:**
   - Found `LEADER_NOT_AVAILABLE_EXCEPTION` errors
   - "Server -1 is not found in metadata cache" errors

3. **Checked Fluss Coordinator:**
   - Initially showed 0 active tablet servers, 0 buckets
   - After restart, showed 3 tablet servers, 48 buckets, but metadata cache was stale

4. **Checked Tablet Servers:**
   - All 3 tablet servers running
   - `produceLog` requests showing 0.0 ops/sec (not receiving writes)

5. **Identified the Issue:**
   - Coordinator metadata cache was stale
   - Producers couldn't get valid bucket leader information

## Solution

### Step 1: Recreate the Table
Recreated the Fluss table to force metadata refresh:

```bash
cd e2e-iot/high-infra/k8s/jobs
./create-table.sh \
  --namespace fluss \
  --bootstrap coordinator-server-hs.fluss.svc.cluster.local:9124 \
  --database iot \
  --table sensor_readings \
  --buckets 48 \
  --image-repo 343218179954.dkr.ecr.us-west-2.amazonaws.com/fluss-demo \
  --image-tag latest
```

This:
- Dropped the existing table
- Recreated it with 48 buckets
- Forced coordinator to rebuild bucket-to-leader mappings

### Step 2: Restart Producers
Restarted all producer jobs to get fresh metadata:

```bash
kubectl delete jobs -n fluss -l app=fluss-producer
cd e2e-iot/high-infra/k8s/jobs
TOTAL_PRODUCERS=8 PRODUCER_RATE=250000 ./deploy-producer-multi-instance.sh --wait
```

This:
- Deleted existing producer jobs
- Redeployed 8 producer instances
- Producers connected with fresh metadata cache

### Result
- Throughput recovered to expected ~2M ops/sec
- All producers achieving target 250K ops/sec each
- No more `LEADER_NOT_AVAILABLE_EXCEPTION` errors

## Prevention & Recommendations

1. **When Restarting Fluss Components:**
   - If restarting tablet servers, wait for coordinator to fully initialize before restarting producers
   - Monitor coordinator metrics: `fluss_coordinator_activeTabletServerCount`, `fluss_coordinator_bucketCount`
   - Ensure these metrics show correct values before deploying producers

2. **If Throughput Drops:**
   - Check producer logs for `LEADER_NOT_AVAILABLE_EXCEPTION` errors
   - Check coordinator metrics for tablet server and bucket counts
   - If metadata is stale, recreate the table and restart producers

3. **Monitoring:**
   - Set up alerts for:
     - Producer throughput below expected threshold
     - `LEADER_NOT_AVAILABLE_EXCEPTION` errors in producer logs
     - Coordinator showing 0 tablet servers or 0 buckets

4. **Best Practices:**
   - Avoid restarting multiple Fluss components simultaneously
   - Restart order: ZooKeeper → Coordinator → Tablet Servers → Producers
   - Wait for each component to be fully ready before proceeding

## Related Files

- Producer deployment script: `e2e-iot/high-infra/k8s/jobs/deploy-producer-multi-instance.sh`
- Table creation script: `e2e-iot/high-infra/k8s/jobs/create-table.sh`
- Producer job manifest: `e2e-iot/high-infra/k8s/jobs/producer-job.yaml`

## Key Takeaways

- **Not a ZooKeeper issue** - ZooKeeper was functioning correctly
- **Coordinator metadata cache** - The coordinator's internal cache can become stale after restarts
- **Solution is straightforward** - Recreate table and restart producers
- **Prevention** - Proper restart order and monitoring can prevent this issue


