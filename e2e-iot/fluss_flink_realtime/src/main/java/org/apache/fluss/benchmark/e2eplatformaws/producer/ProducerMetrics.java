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

package org.apache.fluss.benchmark.e2eplatformaws.producer;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

import com.sun.net.httpserver.HttpServer;

/**
 * Simple Prometheus metrics server for the producer.
 * Exposes metrics on port 8080 at /metrics endpoint.
 */
public class ProducerMetrics {
    private static final Logger LOG = LoggerFactory.getLogger(ProducerMetrics.class);
    
    private final LongAdder totalRecords = new LongAdder();
    private final AtomicLong startTime = new AtomicLong(System.currentTimeMillis());
    private final AtomicLong lastStatsTime = new AtomicLong(System.currentTimeMillis());
    private final AtomicLong lastStatsRecords = new AtomicLong(0);
    
    private HttpServer server;
    private final int port;
    
    public ProducerMetrics(int port) {
        this.port = port;
    }
    
    public void start() throws IOException {
        // Bind to 0.0.0.0 to make it accessible from outside the container
        server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/metrics", this::handleMetrics);
        server.setExecutor(null); // Use default executor
        server.start();
        LOG.info("Producer metrics server started on port {} (bound to 0.0.0.0)", port);
    }
    
    public void stop() {
        if (server != null) {
            server.stop(0);
            LOG.info("Producer metrics server stopped");
        }
    }
    
    public void recordWrite() {
        totalRecords.increment();
    }
    
    public void updateStats(long records) {
        lastStatsRecords.set(records);
        lastStatsTime.set(System.currentTimeMillis());
    }
    
    private void handleMetrics(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        long currentTime = System.currentTimeMillis();
        long total = totalRecords.sum();
        double elapsedSeconds = (currentTime - startTime.get()) / 1000.0;
        double windowElapsedSeconds = (currentTime - lastStatsTime.get()) / 1000.0;
        long windowRecords = Math.max(0, total - lastStatsRecords.get());

        double overallRate = elapsedSeconds > 0 ? total / elapsedSeconds : 0.0;
        double windowRate = windowElapsedSeconds > 0 ? windowRecords / windowElapsedSeconds : 0.0;
        
        StringBuilder response = new StringBuilder();
        response.append("# HELP fluss_producer_records_total Total number of records written to Fluss\n");
        response.append("# TYPE fluss_producer_records_total counter\n");
        response.append("fluss_producer_records_total ").append(total).append("\n");
        
        response.append("# HELP fluss_producer_records_per_second Overall records per second\n");
        response.append("# TYPE fluss_producer_records_per_second gauge\n");
        response.append("fluss_producer_records_per_second ").append(String.format("%.2f", overallRate)).append("\n");
        
        response.append("# HELP fluss_producer_records_per_second_window Records per second in last window\n");
        response.append("# TYPE fluss_producer_records_per_second_window gauge\n");
        response.append("fluss_producer_records_per_second_window ").append(String.format("%.2f", windowRate)).append("\n");
        
        response.append("# HELP fluss_producer_uptime_seconds Producer uptime in seconds\n");
        response.append("# TYPE fluss_producer_uptime_seconds gauge\n");
        response.append("fluss_producer_uptime_seconds ").append((long) elapsedSeconds).append("\n");
        
        String responseStr = response.toString();
        exchange.sendResponseHeaders(200, responseStr.length());
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(responseStr.getBytes());
        }
    }
}

