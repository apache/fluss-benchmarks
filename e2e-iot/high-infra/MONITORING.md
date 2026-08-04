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


# Fluss & Flink Monitoring Setup

This document describes the monitoring infrastructure for the Fluss deployment, including Prometheus metrics collection and Grafana dashboards.

## Overview

The monitoring stack includes:
- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **ServiceMonitors/PodMonitors**: Automatic service discovery for Prometheus scraping

## Components Monitored

### 1. Fluss Coordinator & Tablet Servers
- **Metrics Port**: 9249
- **Metrics Path**: `/metrics`
- **Metrics Exposed**: 
  - Request rates
  - Latency metrics
  - Write operations
  - Client connections

### 2. Flink Aggregator Job
- **Metrics Port**: 9249
- **Metrics Path**: `/metrics`
- **Metrics Exposed**:
  - Input records rate (`flink_taskmanager_job_task_operator_numRecordsIn`)
  - Output records rate (`flink_taskmanager_job_task_operator_numRecordsOut`)
  - Consumer lag (`flink_taskmanager_job_task_operator_fluss_consumer_lag`)
  - Backpressure metrics
  - Throughput metrics

### 3. Producer Job
- **Metrics Port**: 8080 (if custom metrics endpoint is added)
- **Metrics Path**: `/metrics`
- **Metrics Exposed**:
  - Records written (`fluss_client_writer_records_total`)
  - Write latency (`fluss_client_writer_sendLatencyMs`)
  - Write rate

## Accessing Grafana

### Option 1: Port Forward (Recommended for Development)
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```
Then access: http://localhost:3000
- Username: `admin`
- Password: `admin123`

### Option 2: LoadBalancer (if configured)
```bash
kubectl get svc -n monitoring prometheus-grafana
```
Access the external LoadBalancer URL on port 80.

## Accessing Prometheus

### Port Forward
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```
Then access: http://localhost:9090

## Grafana Dashboards

### Fluss & Flink Monitoring Dashboard
The main dashboard includes:

1. **Producer Metrics**
   - Records rate (per second)
   - Total records written
   - Write latency (p95, p99)

2. **Flink Aggregator Metrics**
   - Input records rate
   - Output records rate
   - Consumer lag (with alerting)
   - Backpressure metrics

3. **Fluss Server Metrics**
   - Coordinator request rate
   - Tablet server write rate

## Key Metrics to Monitor

### Producer Metrics
- `fluss_client_writer_records_total`: Total records written
- `fluss_client_writer_sendLatencyMs`: Write latency histogram
- Rate: `rate(fluss_client_writer_records_total[5m])`

### Flink Aggregator Metrics
- `flink_taskmanager_job_task_operator_numRecordsIn`: Input records
- `flink_taskmanager_job_task_operator_numRecordsOut`: Output records
- `flink_taskmanager_job_task_operator_fluss_consumer_lag`: Consumer lag
- Rate: `rate(flink_taskmanager_job_task_operator_numRecordsIn[5m])`

### Consumer Lag Alert
The dashboard includes an alert for high consumer lag (>10,000 records). This indicates the Flink aggregator is falling behind the producer.

## Prometheus Queries

### Producer Throughput
```promql
sum(rate(fluss_client_writer_records_total[5m])) by (instance)
```

### Flink Input Rate
```promql
sum(rate(flink_taskmanager_job_task_operator_numRecordsIn[5m])) by (job_name, task_name)
```

### Consumer Lag
```promql
flink_taskmanager_job_task_operator_fluss_consumer_lag
```

### Producer Latency (p95)
```promql
histogram_quantile(0.95, sum(rate(fluss_client_writer_sendLatencyMs_bucket[5m])) by (le, instance))
```

## Configuration

### Fluss Prometheus Metrics
Configured via Helm `--set` / `configurationOverrides` when deploying Fluss (see `k8s/deploy.sh`):
```yaml
configurationOverrides:
  metrics.reporter.prometheus.class: org.apache.fluss.metrics.prometheus.PrometheusReporterPlugin
  metrics.reporter.prometheus.port: "9249"
  metrics.reporter: prometheus
```

### Flink Prometheus Metrics
Configured via environment variables in `jobs.tf`:
```hcl
env {
  name  = "FLINK_METRICS_REPORTERS"
  value = "prom"
}
env {
  name  = "FLINK_METRICS_REPORTER_PROM_CLASS"
  value = "org.apache.flink.metrics.prometheus.PrometheusReporter"
}
env {
  name  = "FLINK_METRICS_REPORTER_PROM_PORT"
  value = "9249"
}
```

## Troubleshooting

### Metrics Not Appearing
1. Check if pods have Prometheus annotations:
   ```bash
   kubectl get pods -n <namespace> -o yaml | grep prometheus.io
   ```

2. Check ServiceMonitor/PodMonitor resources:
   ```bash
   kubectl get servicemonitor -n <namespace>
   kubectl get podmonitor -n <namespace>
   ```

3. Check Prometheus targets:
   - Access Prometheus UI
   - Go to Status > Targets
   - Verify all targets are "UP"

### Flink Metrics Not Available
If Flink metrics are not appearing, ensure:
1. Flink Prometheus reporter JAR is in the classpath
2. Environment variables are set correctly
3. Port 9249 is accessible from Prometheus

### Producer Metrics Not Available
The producer is a standalone Java application. To expose metrics:
1. Add a simple HTTP metrics endpoint
2. Use Fluss client metrics (if available)
3. Export metrics via JMX and use JMX exporter

## Custom Metrics

To add custom metrics to the producer:
1. Use a metrics library (Micrometer, Prometheus client)
2. Expose metrics on an HTTP endpoint
3. Update the ServiceMonitor/PodMonitor to scrape the endpoint

Example using Micrometer:
```java
MeterRegistry registry = new PrometheusMeterRegistry(PrometheusConfig.DEFAULT);
Counter recordsCounter = Counter.builder("producer.records.total")
    .description("Total records produced")
    .register(registry);
```

## Resources

- Prometheus: 2Gi memory, 1 CPU (requests)
- Grafana: Included in kube-prometheus-stack
- Retention: 30 days

## Security Notes

⚠️ **Production Recommendations**:
- Change default Grafana password
- Use TLS for Grafana and Prometheus
- Restrict access via network policies
- Use RBAC for Prometheus access

