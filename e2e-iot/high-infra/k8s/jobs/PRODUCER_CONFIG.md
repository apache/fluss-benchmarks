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


# Producer Optimal Configuration

This document describes the optimal configuration parameters for the Fluss producer based on performance testing.

## Optimal Settings

### Performance Configuration
- **PRODUCER_RATE**: `200000` records/sec
- **PRODUCER_FLUSH_EVERY**: `5000` records
- **CLIENT_WRITER_BATCH_TIMEOUT**: `90ms` (or `50ms` for lower latency)
- **CLIENT_WRITER_BUFFER_MEMORY_SIZE**: `2gb`
- **CLIENT_WRITER_BATCH_SIZE**: `128mb`

### Resource Configuration
- **PRODUCER_MEMORY_REQUEST**: `4Gi`
- **PRODUCER_MEMORY_LIMIT**: `16Gi`
- **PRODUCER_CPU_REQUEST**: `2000m`
- **PRODUCER_CPU_LIMIT**: `8000m`

### Threading Configuration
- **NUM_WRITER_THREADS**: `48`
- **BUCKETS**: `48`

## Quick Deploy

Use the optimal deployment script:

```bash
cd e2e-iot/high-infra/k8s/jobs
./deploy-producer-optimal.sh
```

Or with custom parameters:

```bash
./deploy-producer-optimal.sh --rate 200000 --flush 5000 --batch-timeout 90ms
```

## Performance Impact

### Batch Timeout
- **10ms**: Low latency but poor throughput (~11,600 ops/sec)
- **50ms**: Good balance (~172,000 ops/sec)
- **90ms**: Higher throughput, slightly higher latency (~187,000+ ops/sec)

### Flush Interval
- **1000 records**: Too frequent, high overhead (~59,000 ops/sec)
- **5000 records**: Optimal balance (~187,000+ ops/sec)
- **20000+ records**: Higher throughput but higher latency

## Default Values

### Java Code Defaults
- `PRODUCER_RATE`: 200,000
- `PRODUCER_FLUSH_EVERY`: 200,000
- `CLIENT_WRITER_BATCH_TIMEOUT`: 10ms (updated to 50ms in code)

### Deploy Script Defaults
- `PRODUCER_RATE`: 200,000
- `PRODUCER_FLUSH_EVERY`: 5,000
- `CLIENT_WRITER_BATCH_TIMEOUT`: 50ms

## Notes

- The optimal configuration balances latency vs throughput
- Batch timeout of 90ms allows more records to accumulate before sending
- Flush interval of 5000 reduces CPU overhead from frequent flushing
- These settings achieved ~187K+ ops/sec in testing


