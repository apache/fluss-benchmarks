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


# Fluss Writer / Table Scan Commands

Working directory for all commands:

```
cd e2e-iot/fluss_flink_realtime
```

## 1. Build the demo jar

```
mvn -f pom.xml clean package
```

Output artifact:
```
target/fluss-flink-realtime-demo.jar
```

## 2. Start / stop Fluss local cluster

Set the Fluss version via `default.env.sh` and point `FLUSS_HOME` at the extracted directory:

```bash
source ../../default.env.sh --fluss-version 0.9.0-incubating
export FLUSS_HOME=/path/to/fluss-${FLUSS_VERSION}
```

Start:
```
$FLUSS_HOME/bin/local-cluster.sh start
```

Stop:
```
$FLUSS_HOME/bin/local-cluster.sh stop
```

## 3. Producer commands

Continuous stream (Ctrl+C to stop):
```
java -jar target/fluss-flink-realtime-demo.jar \
  --bootstrap localhost:9123 \
  --database iot \
  --table sensor_readings \
  --buckets 12 \
  --rate 2000 \
  --flush 5000 \
  --stats-interval 10   # log throughput every 10 seconds (optional)
```

Limit by count or duration:
```
java -jar target/fluss-flink-realtime-demo.jar \
  --bootstrap localhost:9123 --database iot --table sensor_readings --count 50000

java -jar target/fluss-flink-realtime-demo.jar \
  --bootstrap localhost:9123 --database iot --table sensor_readings --duration 5M
```
Add `--stats-interval <seconds>` (or env `PRODUCER_STATS_INTERVAL_SECONDS`) to control how often the producer logs overall/windowed throughput.

## 4. Flink SQL client (metadata check)

```
$FLINK_HOME/bin/sql-client.sh -e "CREATE CATALOG fluss WITH ('type'='fluss','bootstrap.servers'='localhost:9123'); \
  USE CATALOG fluss; SHOW DATABASES;"
```

## 5. CLI helpers bundled in the jar

### List databases / tables
```
java -cp target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussMetadataInspector localhost:9123
```
Optional single database:
```
java -cp target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussMetadataInspector localhost:9123 iot
```

### Peek change log records

```
java --add-opens=java.base/java.nio=ALL-UNNAMED \
  -cp target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussTableLogPeek localhost:9123 iot sensor_readings 5
```
(Change `5` to print more/less records.)

### Peek primary-key snapshot rows

```
java --add-opens=java.base/java.nio=ALL-UNNAMED \
  -cp target/fluss-flink-realtime-demo.jar \
  org.apache.fluss.benchmark.e2eplatformaws.inspect.FlussPrimaryKeySnapshotPeek localhost:9123 iot sensor_readings 5
```
(Reads current table snapshot; only supports non-partitioned primary-key tables.)

## 6. Flink aggregation job

(Requires Flink cluster running in `flink-1.20.3`)
```
$FLINK_HOME/bin/flink run \
  -c org.apache.fluss.benchmark.e2eplatformaws.flink.FlinkSensorAggregatorJob \
  target/fluss-flink-realtime-demo.jar \
  --bootstrap localhost:9123 --database iot --table sensor_readings --window-minutes 1
```
