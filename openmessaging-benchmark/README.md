# OpenMessaging Benchmark for Apache Fluss

A benchmark suite based on the [OpenMessaging Benchmark](https://openmessaging.cloud/docs/benchmarks/) (OMB) framework for measuring the performance of [Apache Fluss (Incubating)](https://github.com/apache/fluss).

## Project Structure

```
openmessaging-benchmark/
├── driver-api/              # Benchmark driver interface
├── benchmark-framework/     # Core benchmarking engine
├── driver-fluss/            # Fluss driver implementation
│   └── config/fluss.yaml    # Fluss driver configuration
├── package/                 # Assembly and packaging
├── bin/                     # Launcher scripts
├── workloads/               # Workload definitions
├── payload/                 # Pre-generated payload data files
└── etc/                     # Shared build config (checkstyle, spotbugs, etc.)
```

## Prerequisites

- Java 8+ (Java 11+ recommended for Arrow format)
- Maven 3.8.6+
- A running Apache Fluss cluster

## Build

```bash
cd openmessaging-benchmark
mvn clean package -DskipTests
```

## Usage

### Local Mode

Run the benchmark on a single machine:

```bash
bin/benchmark-local \
    -d driver-fluss/config/fluss.yaml \
    workloads/1-topic-1-partition-1kb.yaml
```

### Distributed Mode

Start worker processes on each worker node:

```bash
bin/benchmark-worker
```

Then run the benchmark from the driver node:

```bash
bin/benchmark \
    -d driver-fluss/config/fluss.yaml \
    -w http://worker1:8080,http://worker2:8080 \
    workloads/1-topic-16-partitions-1kb.yaml
```

### CLI Options

| Option | Description |
|--------|-------------|
| `-d, --drivers` | Driver config file(s), e.g. `driver-fluss/config/fluss.yaml` |
| `-w, --workers` | Comma-separated worker addresses for distributed mode |
| `-wf, --workers-file` | YAML file containing worker addresses |
| `-o, --output` | Output directory for JSON results |
| `-c, --csv` | Convert JSON results in a directory to CSV |

## Configuration

### Driver Configuration (`driver-fluss/config/fluss.yaml`)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `bootstrapServers` | Fluss cluster address | `localhost:9123` |
| `schema` | Row schema (first field must be `long` for E2E timestamp) | `long-int-int-string-string` |
| `logFormat` | Log format: `ARROW` or `INDEXED` | `ARROW` |
| `writerAcks` | Writer acknowledgment mode | `all` |
| `writerBatchSize` | Writer batch size | `1mb` |
| `writerBufferMemory` | Writer buffer memory | `32mb` |
| `writerBatchTimeoutMs` | Writer batch timeout in milliseconds | `100` |
| `projectFields` | Consumer field projection (`all` or field indices like `0/1/2`) | `all` |
| `prefetchNum` | Consumer prefetch count | `4` |
| `fetchMaxBytes` | Consumer max fetch bytes | `16mb` |
| `clientNettyThreads` | Number of Netty client threads | `1` |

### Workload Configuration (`workloads/`)

| Parameter | Description |
|-----------|-------------|
| `topics` | Number of topics |
| `partitionsPerTopic` | Partitions per topic |
| `messageSize` | Message size in bytes |
| `producersPerTopic` | Number of producers per topic |
| `consumerPerSubscription` | Number of consumers per subscription |
| `producerRate` | Target produce rate (msg/s), `0` for auto-discovery |
| `testDurationMinutes` | Benchmark test duration |
| `warmupDurationMinutes` | Warmup duration before measurement |
| `useRandomizedPayloads` | Whether to use randomized payloads |
| `randomBytesRatio` | Ratio of random bytes in payload |

## Metrics

The benchmark collects and reports the following metrics every 10 seconds:

| Metric | Unit | Description |
|--------|------|-------------|
| Publish Rate | msg/s | Messages published per second |
| Publish Throughput | MB/s | Bytes published per second |
| Consume Rate | msg/s | Messages consumed per second |
| Consume Throughput | MB/s | Bytes consumed per second |
| Publish Latency | ms | Latency from send call to ack (avg, P50, P99, P99.9, max) |
| Publish Delay Latency | us | Delay between intended and actual send time |
| End-to-End Latency | ms | Latency from publish to consume |
| Backlog | count | Unconsumed message count |

Results are written to a JSON file (e.g. `1-topic-1-partition-1kb-Fluss-2026-04-26-20-44-27.json`) containing per-interval time series and aggregated percentiles for all metrics.

## License

Apache License, Version 2.0
