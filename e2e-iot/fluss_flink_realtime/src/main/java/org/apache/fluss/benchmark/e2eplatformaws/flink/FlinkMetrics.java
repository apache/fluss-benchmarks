/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.fluss.benchmark.e2eplatformaws.flink;

import org.apache.flink.metrics.Metric;
import org.apache.flink.metrics.MetricGroup;
import org.apache.flink.metrics.Gauge;
import org.apache.flink.metrics.Counter;
import org.apache.flink.metrics.Meter;
import org.apache.flink.runtime.metrics.MetricRegistry;
import org.apache.flink.runtime.metrics.groups.AbstractMetricGroup;
import org.apache.flink.runtime.metrics.scope.ScopeFormat;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.OutputStream;
import java.io.Serializable;
import java.net.InetSocketAddress;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

import com.sun.net.httpserver.HttpServer;

/**
 * Simple Prometheus metrics server for Flink aggregator.
 * Exposes metrics on port 9249 at /metrics endpoint.
 */
public class FlinkMetrics implements Serializable {
    private static final long serialVersionUID = 1L;
    private static final Logger LOG = LoggerFactory.getLogger(FlinkMetrics.class);
    
    final LongAdder recordsIn = new LongAdder();
    final LongAdder recordsOut = new LongAdder();
    final AtomicLong startTime = new AtomicLong(System.currentTimeMillis());
    private final AtomicLong lastUpdateTime = new AtomicLong(System.currentTimeMillis());
    
    // Track additional metrics
    private final AtomicLong eventTimeLag = new AtomicLong(0);
    private final Map<String, Long> bucketOffsets = new ConcurrentHashMap<>();
    private final AtomicLong backpressureTime = new AtomicLong(0);
    
    private HttpServer server;
    private final int port;
    
    public FlinkMetrics(int port) {
        this.port = port;
    }
    
    public void start() throws IOException {
        server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/metrics", this::handleMetrics);
        server.setExecutor(null); // Use default executor
        server.start();
        LOG.info("Flink metrics server started on port {}", port);
    }
    
    public void stop() {
        if (server != null) {
            server.stop(0);
            LOG.info("Flink metrics server stopped");
        }
    }
    
    public void recordInput() {
        recordsIn.increment();
        lastUpdateTime.set(System.currentTimeMillis());
    }
    
    public void recordOutput() {
        recordsOut.increment();
        lastUpdateTime.set(System.currentTimeMillis());
    }
    
    public void updateEventTimeLag(long lagMs) {
        eventTimeLag.set(lagMs);
    }
    
    public void updateBucketOffset(String bucket, long offset) {
        bucketOffsets.put(bucket, offset);
    }
    
    public void updateBackpressure(long backpressureMs) {
        backpressureTime.set(backpressureMs);
    }
    
    public long getRecordsIn() {
        return recordsIn.sum();
    }
    
    public long getStartTime() {
        return startTime.get();
    }
    
    private void handleMetrics(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        long currentTime = System.currentTimeMillis();
        long in = recordsIn.sum();
        long out = recordsOut.sum();
        long elapsedSeconds = (currentTime - startTime.get()) / 1000;
        
        double inRate = elapsedSeconds > 0 ? (double) in / elapsedSeconds : 0.0;
        double outRate = elapsedSeconds > 0 ? (double) out / elapsedSeconds : 0.0;
        
        StringBuilder response = new StringBuilder();
        response.append("# HELP flink_taskmanager_job_task_operator_numRecordsIn Total number of input records\n");
        response.append("# TYPE flink_taskmanager_job_task_operator_numRecordsIn counter\n");
        response.append("flink_taskmanager_job_task_operator_numRecordsIn ").append(in).append("\n");
        
        response.append("# HELP flink_taskmanager_job_task_operator_numRecordsOut Total number of output records\n");
        response.append("# TYPE flink_taskmanager_job_task_operator_numRecordsOut counter\n");
        response.append("flink_taskmanager_job_task_operator_numRecordsOut ").append(out).append("\n");
        
        response.append("# HELP flink_taskmanager_job_task_operator_numRecordsInPerSecond Input records per second\n");
        response.append("# TYPE flink_taskmanager_job_task_operator_numRecordsInPerSecond gauge\n");
        response.append("flink_taskmanager_job_task_operator_numRecordsInPerSecond ").append(String.format("%.2f", inRate)).append("\n");
        
        response.append("# HELP flink_taskmanager_job_task_operator_numRecordsOutPerSecond Output records per second\n");
        response.append("# TYPE flink_taskmanager_job_task_operator_numRecordsOutPerSecond gauge\n");
        response.append("flink_taskmanager_job_task_operator_numRecordsOutPerSecond ").append(String.format("%.2f", outRate)).append("\n");
        
        response.append("# HELP flink_taskmanager_job_task_operator_uptime_seconds Flink job uptime in seconds\n");
        response.append("# TYPE flink_taskmanager_job_task_operator_uptime_seconds gauge\n");
        response.append("flink_taskmanager_job_task_operator_uptime_seconds ").append(elapsedSeconds).append("\n");
        
        // Event Time Lag
        response.append("# HELP flink_taskmanager_job_task_operator_currentFetchEventTimeLag Event time lag in milliseconds\n");
        response.append("# TYPE flink_taskmanager_job_task_operator_currentFetchEventTimeLag gauge\n");
        response.append("flink_taskmanager_job_task_operator_currentFetchEventTimeLag ").append(eventTimeLag.get()).append("\n");
        
        // Current Offset per Bucket
        response.append("# HELP flink_taskmanager_job_task_operator_fluss_reader_bucket_currentOffset Current offset per bucket\n");
        response.append("# TYPE flink_taskmanager_job_task_operator_fluss_reader_bucket_currentOffset gauge\n");
        for (Map.Entry<String, Long> entry : bucketOffsets.entrySet()) {
            response.append("flink_taskmanager_job_task_operator_fluss_reader_bucket_currentOffset{bucket=\"").append(entry.getKey()).append("\"} ").append(entry.getValue()).append("\n");
        }
        
        // Backpressure (estimated based on input/output rate difference)
        long backpressureMs = 0;
        if (inRate > 0 && outRate > 0 && inRate > outRate) {
            // Estimate backpressure: if input rate > output rate, there's backpressure
            // Calculate as milliseconds of backpressure per second
            double rateDiff = inRate - outRate;
            backpressureMs = (long) ((rateDiff / inRate) * 1000); // Convert to ms per second
        }
        response.append("# HELP flink_taskmanager_job_task_backPressuredTimeMsPerSecond Backpressure time in milliseconds per second\n");
        response.append("# TYPE flink_taskmanager_job_task_backPressuredTimeMsPerSecond gauge\n");
        response.append("flink_taskmanager_job_task_backPressuredTimeMsPerSecond ").append(backpressureMs).append("\n");
        
        String responseStr = response.toString();
        exchange.sendResponseHeaders(200, responseStr.length());
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(responseStr.getBytes());
        }
    }
}

