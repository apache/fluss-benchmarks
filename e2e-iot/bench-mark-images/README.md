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


<!--
  Benchmark Diagrams Documentation
  =================================
  
  This folder contains performance benchmark diagrams from the 2 million rows per second test run.
  Diagrams are numbered in sequence (10-deployment first, then 1-9) to show the progression
  of benchmark analysis from architecture overview to detailed performance metrics.
  
  Each diagram includes:
  - What it shows (metrics and data displayed)
  - What to look for (key performance indicators)
  - Insights about system behavior
-->

# Benchmark Diagrams

This folder contains performance benchmark diagrams from the 2 million rows per second test run. The diagrams are numbered in sequence to show the progression of the benchmark analysis.

## Diagram Sequence

### 10. Deployment Diagram (`10-Fluss Deployment.png`)

**Purpose:** Shows the complete architecture and deployment topology of the benchmark setup.

**What it shows:**
- **Infrastructure Components:**
  - AWS EKS cluster with multiple node groups
  - Fluss coordinator (1 instance)
  - Fluss tablet servers (3 instances)
  - Flink JobManager (1 instance)
  - Flink TaskManagers (6 instances)
  - Producer nodes (4 nodes with 8 producer instances)
  - Monitoring stack (Prometheus + Grafana)
  
- **Network Architecture:**
  - VPC with public and private subnets
  - Load balancers and service endpoints
  - Inter-component communication paths
  
- **Data Flow:**
  - Producer → Fluss Tablet Servers
  - Fluss → Flink (via Fluss catalog)
  - Flink → Aggregated Output
  
- **Storage:**
  - S3 buckets for Flink checkpoints
  - NVMe storage for tablet servers
  - EBS volumes for persistent data

**Key Insights:**
- Demonstrates the distributed nature of the setup
- Shows how data flows through the system
- Illustrates the separation of compute and storage layers
- Highlights the scalability of the architecture

---

### 1. Producer Throughput (`1-Fluss-Producer.png`)

**Purpose:** Monitors the data generation rate from all producer instances.

**What it shows:**
- **Total Records Per Second:** Aggregated rate from all 8 producer instances
- **Per-Instance Rates:** Individual producer instance throughput
- **Total Records:** Cumulative count of records generated
- **Time Series:** Shows throughput over the benchmark duration

**Key Metrics:**
- Target: 2,000,000 records/second (250K per instance × 8)
- Actual sustained rate during benchmark
- Rate stability and consistency
- Any rate fluctuations or drops

**What to look for:**
- Consistent rate at or near 2M records/sec
- Minimal fluctuations indicating stable generation
- All 8 instances contributing equally
- No rate degradation over time

---

### 2. Flink Consumer (`2-flink-consumer.png`)

**Purpose:** Shows how Flink consumes data from the Fluss table.

**What it shows:**
- **Consumer Throughput:** Rate at which Flink reads from Fluss
- **Records In:** Number of records consumed per second
- **Consumer Lag:** Delay between data production and consumption
- **Partition Distribution:** How data is distributed across Flink subtasks

**Key Metrics:**
- Input records per second (should match producer rate)
- Consumer lag (should be minimal, < 1 second)
- Number of active consumers/subtasks
- Throughput per subtask

**What to look for:**
- Consumer rate matching producer rate (~2M records/sec)
- Low and stable consumer lag
- Even distribution across Flink subtasks
- No backpressure indicators

---

### 3. Flink Overall Operator Throughput (`3-flink-overall-operator-throughput.png`)

**Purpose:** Shows throughput across all Flink operators in the pipeline.

**What it shows:**
- **Operator-Level Metrics:**
  - FlussChangelogFilter throughput
  - FlussSensorReadingMapper throughput
  - TumblingWindowAggregation throughput
  - FlussAggregatorSink throughput
  
- **Records In/Out per Operator:** Shows data flow through each stage
- **Operator Utilization:** CPU and memory usage per operator
- **Parallelism Distribution:** How work is distributed across subtasks

**Key Metrics:**
- Records in per second for each operator
- Records out per second for each operator
- Operator busy percentage
- Throughput bottlenecks (if any)

**What to look for:**
- Consistent throughput across all operators
- No significant drops between operators (indicating no data loss)
- Balanced operator utilization
- Identification of any bottleneck operators

---

### 4. Flink End-to-End Data Lag (`4-flink-end-to-end-data-lag.png`)

**Purpose:** Measures the latency from data production to final aggregation output.

**What it shows:**
- **Event Time Lag:** Difference between event timestamp and processing time
- **Processing Latency:** Time taken for data to flow through Flink pipeline
- **Window Processing Delay:** Delay in window aggregation completion
- **End-to-End Latency:** Total time from producer to sink

**Key Metrics:**
- Average event time lag (milliseconds)
- P95/P99 event time lag
- Processing time latency
- Window completion delay

**What to look for:**
- Low and stable event time lag (< 1 second)
- Consistent processing latency
- No lag spikes indicating bottlenecks
- Sub-second end-to-end latency

---

### 5. Flink Back Pressure (`5-flink-back-pressure.png`)

**Purpose:** Monitors backpressure indicators to identify bottlenecks in the Flink pipeline.

**What it shows:**
- **Backpressure Status:** Per-operator backpressure indicators
- **Operator Busy Percentage:** CPU utilization per operator
- **Queue Sizes:** Input/output queue sizes for each operator
- **Idle Time:** Operator idle time (inverse of busy percentage)

**Key Metrics:**
- Backpressure status (OK, LOW, HIGH)
- Operator busy percentage (should be < 100%)
- Input/output buffer utilization
- Downstream operator blocking indicators

**What to look for:**
- No backpressure (all operators showing OK status)
- Balanced operator busy percentages
- No operators stuck at 100% busy
- Healthy buffer utilization

---

### 6. Fluss Tablet Server Throughput (`5-fluss-tablet-server-throughput.png`)

**Purpose:** Shows the throughput and performance of Fluss tablet servers handling writes.

**What it shows:**
- **Messages In Rate:** Rate at which tablet servers receive messages
- **Bytes In/Out Rate:** Data transfer rates to/from tablet servers
- **Write Throughput:** Aggregate write performance across all 3 tablet servers
- **Per-Server Metrics:** Individual tablet server performance

**Key Metrics:**
- Messages per second (should match producer rate)
- Bytes per second (incoming writes)
- Replication bytes per second
- Per-tablet-server distribution

**What to look for:**
- Sustained 2M messages/second across tablet servers
- Even distribution across 3 tablet servers
- High write throughput
- No performance degradation

---

### 7. Fluss Tablet Server Request by Type (`6-Fluss_tablet-server-request-by-type.png`)

**Purpose:** Breaks down tablet server requests by operation type to understand workload patterns.

**What it shows:**
- **Request Types:**
  - `produceLog`: Write operations (should be highest)
  - `fetchLogClient`: Read operations from Flink
  - `putKv`: Key-value operations
  - Other request types
  
- **Request Rates:** Requests per second per type
- **Request Distribution:** Percentage breakdown of request types
- **Per-Server Breakdown:** Request distribution across tablet servers

**Key Metrics:**
- ProduceLog requests/sec (write operations)
- FetchLogClient requests/sec (read operations from Flink)
- Request rate per tablet server
- Request type distribution

**What to look for:**
- High produceLog rate (matching producer write rate)
- Moderate fetchLogClient rate (matching Flink read rate)
- Balanced request distribution across tablet servers
- No unusual request patterns

---

### 8. Fluss Tablet Server CPU (`7-Fluss-tablet-server-CPU.png`)

**Purpose:** Monitors CPU utilization of tablet servers to ensure they're not bottlenecked.

**What it shows:**
- **CPU Usage:** CPU utilization percentage per tablet server
- **CPU Load:** System load average
- **JVM CPU:** Java process CPU usage
- **CPU Trends:** CPU usage over time

**Key Metrics:**
- Average CPU usage per tablet server
- Peak CPU usage
- CPU load average
- JVM CPU time

**What to look for:**
- Moderate CPU usage (50-80% is healthy)
- No CPU saturation (100% indicates bottleneck)
- Balanced CPU across all 3 tablet servers
- Stable CPU usage without spikes

---

### 9. Flink Aggregation Input (`8-Flink_aggregation-In.png`)

**Purpose:** Shows the input rate to the Flink aggregation operators (window and sink).

**What it shows:**
- **Aggregation Input Rate:** Records per second entering aggregation operators
- **Window Input:** Records entering tumbling window operator
- **Key Distribution:** Distribution of records by sensor_id
- **Input Stability:** Consistency of input rate over time

**Key Metrics:**
- Records per second entering aggregation
- Records per window (should be ~2M per minute)
- Input rate stability
- Key distribution evenness

**What to look for:**
- Consistent input rate (~2M records/sec)
- Stable input without drops
- Even key distribution
- No input rate spikes or gaps

---

### 10. Flink Aggregation Output (`9-Flink-aggregation-out.png`)

**Purpose:** Shows the output rate from Flink aggregation (aggregated results per window).

**What it shows:**
- **Aggregation Output Rate:** Aggregated records per second
- **Window Output:** Number of aggregates produced per window
- **Output Stability:** Consistency of output rate
- **Aggregation Efficiency:** Ratio of input to output records

**Key Metrics:**
- Aggregated records per second (~1,667/sec = 100K devices / 60 seconds)
- Records per window (should be ~100K aggregates per 1-minute window)
- Output rate stability
- Aggregation ratio (input:output should be ~1200:1 for 1-minute windows)

**What to look for:**
- Consistent output rate (~1,667 aggregates/sec)
- One aggregate per device per window
- Stable output without gaps
- Proper aggregation (many input records → one output per device)

---

## Benchmark Summary

These diagrams collectively demonstrate:

1. **Producer Performance:** All 8 instances generating data at target rate (2M records/sec)
2. **Fluss Performance:** Tablet servers handling writes efficiently with balanced load
3. **Flink Performance:** Real-time processing with low latency and no backpressure
4. **End-to-End Latency:** Sub-second processing from producer to aggregated output
5. **System Stability:** Consistent performance throughout the benchmark duration
6. **Scalability:** System handling 2M records/sec with room for growth

## Key Performance Indicators

- **Throughput:** Sustained 2,000,000 records/second
- **Latency:** Sub-second end-to-end processing
- **Availability:** No data loss, no backpressure
- **Efficiency:** Balanced resource utilization across all components
- **Scalability:** Linear scaling with additional resources

