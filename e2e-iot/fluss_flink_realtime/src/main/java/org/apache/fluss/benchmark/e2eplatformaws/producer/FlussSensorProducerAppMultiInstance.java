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

import org.apache.fluss.benchmark.e2eplatformaws.model.SensorDataMinimal;
import org.apache.fluss.client.Connection;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.admin.Admin;
import org.apache.fluss.client.table.Table;
import org.apache.fluss.client.table.writer.UpsertWriter;
import org.apache.fluss.config.ConfigOptions;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.config.MemorySize;
import org.apache.fluss.metadata.DatabaseDescriptor;
import org.apache.fluss.metadata.Schema;
import org.apache.fluss.metadata.TableDescriptor;
import org.apache.fluss.metadata.TablePath;
import org.apache.fluss.row.GenericRow;
import org.apache.fluss.types.DataTypes;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

/**
 * Multi-instance Fluss producer that supports distributed device generation across multiple producer instances.
 * 
 * Features:
 * - Supports 100,000 devices total, distributed across multiple producer instances
 * - Each instance handles a specific device ID range based on instance-id and total-producers
 * - Multiple threads write in parallel to maximize throughput
 * - Each device has its own generator with independent state
 * - Device IDs are hashed to 48 buckets automatically by Fluss (via sensor_id hash)
 * - Rate is distributed evenly across all devices in the instance's range
 */
public final class FlussSensorProducerAppMultiInstance {
    private static final Logger LOG = LoggerFactory.getLogger(FlussSensorProducerAppMultiInstance.class);
    
    // Total number of devices across all producer instances
    private static final int TOTAL_DEVICES = 100_000;

    // Set IPv4-only properties in static initializer to ensure they're set before any class loading
    static {
        System.setProperty("java.net.preferIPv4Stack", "true");
        System.setProperty("java.net.preferIPv4Addresses", "true");
        System.setProperty("java.net.useSystemProxies", "false");
    }

    public static void main(String[] args) throws Exception {
        // Ensure IPv4 properties are set (redundant but safe)
        System.setProperty("java.net.preferIPv4Stack", "true");
        System.setProperty("java.net.preferIPv4Addresses", "true");
        
        ProducerOptions options = ProducerOptions.parse(args);
        LOG.info("Starting multi-instance Fluss producer with options: {}", options);
        
        // Validate instance configuration
        if (options.totalProducers <= 0) {
            throw new IllegalArgumentException("total-producers must be > 0");
        }
        if (options.instanceId < 0 || options.instanceId >= options.totalProducers) {
            throw new IllegalArgumentException(
                    String.format("instance-id must be >= 0 and < total-producers (%d)", options.totalProducers));
        }

        // Calculate device ID range for this instance
        int devicesPerInstance = TOTAL_DEVICES / options.totalProducers;
        int startDeviceId = options.instanceId * devicesPerInstance;
        int endDeviceId = (options.instanceId == options.totalProducers - 1) 
                ? TOTAL_DEVICES  // Last instance gets any remainder
                : (options.instanceId + 1) * devicesPerInstance;
        int deviceCount = endDeviceId - startDeviceId;
        
        LOG.info("Instance {} of {}: Handling devices {} to {} ({} devices)", 
                options.instanceId, options.totalProducers, startDeviceId, endDeviceId - 1, deviceCount);

        Configuration flussConf = new Configuration();
        flussConf.set(ConfigOptions.BOOTSTRAP_SERVERS, Collections.singletonList(options.bootstrap));
        flussConf.set(ConfigOptions.CLIENT_WRITER_BUFFER_MEMORY_SIZE, options.writerBufferSize);
        flussConf.set(ConfigOptions.CLIENT_WRITER_BATCH_SIZE, options.writerBatchSize);
        // Set batch timeout from environment variable (default: 50ms for optimal throughput)
        String batchTimeoutStr = getEnv("CLIENT_WRITER_BATCH_TIMEOUT", "50ms");
        try {
            // Parse duration string like "10ms", "50ms", etc.
            long millis = Long.parseLong(batchTimeoutStr.replaceAll("[^0-9]", ""));
            flussConf.set(ConfigOptions.CLIENT_WRITER_BATCH_TIMEOUT, Duration.ofMillis(millis));
            LOG.info("Set CLIENT_WRITER_BATCH_TIMEOUT to {}ms", millis);
        } catch (Exception e) {
            LOG.warn("Failed to parse CLIENT_WRITER_BATCH_TIMEOUT '{}', using default 50ms", batchTimeoutStr);
            flussConf.set(ConfigOptions.CLIENT_WRITER_BATCH_TIMEOUT, Duration.ofMillis(50));
        }

        
        // Start Prometheus metrics server
        ProducerMetrics metrics = new ProducerMetrics(8080);
        metrics.start();
        LOG.info("Prometheus metrics server started on port 8080");

        TablePath tablePath = TablePath.of(options.database, options.table);

        try (Connection connection = ConnectionFactory.createConnection(flussConf)) {
            ensureSchema(connection, tablePath, options.bucketCount);

            try (Table table = connection.getTable(tablePath)) {
                AtomicBoolean running = new AtomicBoolean(true);
                Runtime.getRuntime()
                        .addShutdownHook(new Thread(() -> shutdown(running), "fluss-producer-shutdown"));

                // Create thread pool for parallel writing
                int numThreads = options.numWriterThreads;
                ExecutorService executor = Executors.newFixedThreadPool(numThreads);
                CountDownLatch completionLatch = new CountDownLatch(numThreads);
                
                // Shared counters for statistics
                LongAdder totalSent = new LongAdder();
                AtomicLong startNano = new AtomicLong(System.nanoTime());
                AtomicLong lastStatsNano = new AtomicLong(startNano.get());
                AtomicLong lastStatsRecords = new AtomicLong(0);
                long statsIntervalNanos = options.statsInterval.toNanos();
                
                // Rate control: distribute rate across threads
                // Each thread should produce: totalRate / numThreads records per second
                double ratePerThread = options.recordsPerSecond > 0 
                        ? (double) options.recordsPerSecond / numThreads 
                        : 0.0;
                long nanosPerRecordPerThread = ratePerThread > 0 
                        ? (long) (TimeUnit.SECONDS.toNanos(1) / ratePerThread)
                        : 0;
                
                LOG.info("Target rate: {} rec/s total, {} rec/s per thread, {} writer threads", 
                        options.recordsPerSecond, String.format(Locale.ROOT, "%.2f", ratePerThread), numThreads);

                // Divide devices among threads
                int devicesPerThread = (deviceCount + numThreads - 1) / numThreads; // Ceiling division
                
                // Start writer threads
                for (int threadId = 0; threadId < numThreads; threadId++) {
                    int threadStartDevice = startDeviceId + threadId * devicesPerThread;
                    int threadEndDevice = Math.min(threadStartDevice + devicesPerThread, endDeviceId);
                    
                    if (threadStartDevice >= endDeviceId) {
                        // No devices for this thread
                        completionLatch.countDown();
                        continue;
                    }
                    
                    final int finalThreadId = threadId;
                    final int finalThreadStartDevice = threadStartDevice;
                    final int finalThreadEndDevice = threadEndDevice;
                    
                    executor.submit(() -> {
                        try {
                            UpsertWriter writer = table.newUpsert().createWriter();
                            DeviceRangeGenerator generator = new DeviceRangeGenerator(
                                    finalThreadStartDevice, 
                                    finalThreadEndDevice);
                            
                            long threadSent = 0;
                            long threadStartNano = System.nanoTime();
                            long stopAtCount = options.totalRecords > 0 ? options.totalRecords : Long.MAX_VALUE;
                            long stopAtTime = options.runDuration.isZero()
                                    ? Long.MAX_VALUE
                                    : System.nanoTime() + options.runDuration.toNanos();
                            
                            LOG.info("[Thread {}] Starting - will stop at {} total records", finalThreadId, stopAtCount);
                            
                            while (running.get() && totalSent.sum() < stopAtCount && System.nanoTime() < stopAtTime) {
                                SensorDataMinimal record = generator.next();
                                writeToFluss(writer, record);
                                threadSent++;
                                totalSent.increment();
                                long currentTotal = totalSent.sum();
                                metrics.recordWrite();

                                if (threadSent % options.flushEvery == 0) {
                                    writer.flush();
                                }

                                // Check if we've reached the total count
                                if (stopAtCount != Long.MAX_VALUE && currentTotal >= stopAtCount) {
                                    LOG.info("[Thread {}] Reached target count of {} records, stopping", finalThreadId, stopAtCount);
                                    break;
                                }
                                
                                maybeLogStats(
                                        finalThreadId,
                                        threadSent,
                                        currentTotal,
                                        startNano,
                                        lastStatsNano,
                                        lastStatsRecords,
                                        statsIntervalNanos,
                                        metrics);

                                // Rate limiting per thread
                                if (nanosPerRecordPerThread > 0) {
                                    long target = threadStartNano + threadSent * nanosPerRecordPerThread;
                                    long wait = target - System.nanoTime();
                                    if (wait > 0) {
                                        TimeUnit.NANOSECONDS.sleep(wait);
                                    }
                                }
                            }

                            writer.flush();
                            LOG.info("[Thread {}] Stopped after emitting {} records", finalThreadId, threadSent);
                        } catch (Exception e) {
                            LOG.error("[Thread {}] Error in writer thread", finalThreadId, e);
                        } finally {
                            completionLatch.countDown();
                        }
                    });
                }

                // Wait for all threads to complete
                completionLatch.await();
                executor.shutdown();
                if (!executor.awaitTermination(30, TimeUnit.SECONDS)) {
                    executor.shutdownNow();
                }

                LOG.info("Producer instance {} stopped after emitting {} records total", 
                        options.instanceId, totalSent.sum());
            }
        } finally {
            metrics.stop();
        }
    }

    private static void shutdown(AtomicBoolean running) {
        LOG.info("Shutdown requested");
        running.set(false);
    }

    private static void maybeLogStats(
            int threadId,
            long threadSent,
            long currentTotal,
            AtomicLong startNano,
            AtomicLong lastStatsNano,
            AtomicLong lastStatsRecords,
            long statsIntervalNanos,
            ProducerMetrics metrics) {
        long now = System.nanoTime();
        long lastNano = lastStatsNano.get();
        if (now - lastNano < statsIntervalNanos) {
            return;
        }
        if (!lastStatsNano.compareAndSet(lastNano, now)) {
            return;
        }
        long recordsAtLast = lastStatsRecords.getAndSet(currentTotal);
        double overallRate = ratePerSecond(currentTotal, now - startNano.get());
        double windowRate = ratePerSecond(currentTotal - recordsAtLast, now - lastNano);
        LOG.info(
                "[Thread {}] Produced {} records (thread: {}, overall ~{} rec/s, last window ~{} rec/s)",
                threadId,
                currentTotal,
                threadSent,
                String.format(Locale.ROOT, "%.0f", overallRate),
                String.format(Locale.ROOT, "%.0f", windowRate));
        metrics.updateStats(currentTotal);
    }

    private static void ensureSchema(Connection connection, TablePath tablePath, int bucketCount)
            throws Exception {
        try (Admin admin = connection.getAdmin()) {
            admin.createDatabase(
                            tablePath.getDatabaseName(),
                            DatabaseDescriptor.builder().comment("IoT demo database").build(),
                            true)
                    .get();

            // Minimal IoT sensor schema (8 columns written to Fluss)
            // Only minimal fields from AVRO schema are stored in Fluss
            Schema schema = Schema.newBuilder()
                    .primaryKey("sensor_id")
                    .column("sensor_id", DataTypes.INT())
                    .column("sensor_type", DataTypes.INT())
                    .column("temperature", DataTypes.DOUBLE())
                    .column("humidity", DataTypes.DOUBLE())
                    .column("pressure", DataTypes.DOUBLE())
                    .column("battery_level", DataTypes.DOUBLE())
                    .column("status", DataTypes.INT())
                    .column("timestamp", DataTypes.BIGINT())
                    .build();

            TableDescriptor descriptor = TableDescriptor.builder()
                    .schema(schema)
                    .comment("Realtime sensor readings - minimal IoT producer schema")
                    .distributedBy(bucketCount, "sensor_id")
                    .build();

            admin.createTable(tablePath, descriptor, true).get();
            LOG.info("Ensured Fluss table {} exists ({} buckets)", tablePath, bucketCount);
        }
    }

    private static void writeToFluss(UpsertWriter writer, SensorDataMinimal data) throws Exception {
        // Schema matching AVRO: sensor_id, sensor_type, temperature, humidity, pressure, 
        //                      battery_level, status, timestamp
        GenericRow row = new GenericRow(8);
        row.setField(0, data.getSensorId());  // INT
        row.setField(1, data.getSensorType());  // INT (1-8)
        row.setField(2, data.getTemperature());
        row.setField(3, data.getHumidity());
        row.setField(4, data.getPressure());
        row.setField(5, data.getBatteryLevel());
        row.setField(6, data.getStatus()); // INT: 1=online, 2=offline, 3=maintenance, 4=error
        row.setField(7, data.getTimestamp()); // LONG: timestamp in milliseconds

        writer.upsert(row);
    }

    private record ProducerOptions(
            String bootstrap,
            String database,
            String table,
            int bucketCount,
            long totalRecords,
            Duration runDuration,
            int recordsPerSecond,
            int flushEvery,
            MemorySize writerBufferSize,
            MemorySize writerBatchSize,
            Duration statsInterval,
            int totalProducers,
            int instanceId,
            int numWriterThreads) {
        private static ProducerOptions parse(String[] args) {
            String bootstrap = "localhost:9124";
            String database = "iot";
            String table = "sensor_readings";
            int bucketCount = 48; // Default to 48 buckets
            long totalRecords = 0L;
            Duration runDuration = Duration.ZERO;
            int recordsPerSecond = getIntEnv("PRODUCER_RATE", 200000);
            int flushEvery = getIntEnv("PRODUCER_FLUSH_EVERY", 200000);
            Duration statsInterval = parseStatsInterval();
            String bufferSizeStr = getEnv("CLIENT_WRITER_BUFFER_MEMORY_SIZE", "2gb");
            String batchSizeStr = getEnv("CLIENT_WRITER_BATCH_SIZE", "128mb");
            MemorySize bufferSize = MemorySize.parse(bufferSizeStr);
            MemorySize batchSize = MemorySize.parse(batchSizeStr);
            int totalProducers = getIntEnv("TOTAL_PRODUCERS", 1);
            int instanceId = getIntEnv("INSTANCE_ID", 0);
            int numWriterThreads = getIntEnv("NUM_WRITER_THREADS", 8);

            for (int i = 0; i < args.length; i++) {
                String option = args[i];
                String inlineValue = null;
                int eqIdx = option.indexOf('=');
                if (eqIdx > 0) {
                    inlineValue = option.substring(eqIdx + 1);
                    option = option.substring(0, eqIdx);
                }

                switch (option) {
                    case "--bootstrap":
                        bootstrap = inlineValue != null ? inlineValue : requireValue(option, args, ++i);
                        break;
                    case "--database":
                        database = inlineValue != null ? inlineValue : requireValue(option, args, ++i);
                        break;
                    case "--table":
                        table = inlineValue != null ? inlineValue : requireValue(option, args, ++i);
                        break;
                    case "--buckets":
                        bucketCount = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--count":
                        totalRecords = Long.parseLong(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--duration":
                        String durationValue = inlineValue != null ? inlineValue : requireValue(option, args, ++i);
                        runDuration = Duration.parse("PT" + durationValue.toUpperCase(Locale.ROOT));
                        break;
                    case "--rate":
                        recordsPerSecond = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--flush":
                        flushEvery = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--stats-interval":
                        statsInterval = parseStatsIntervalValue(
                                inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--total-producers":
                        totalProducers = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--instance-id":
                        instanceId = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--writer-threads":
                        numWriterThreads = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    default:
                        throw new IllegalArgumentException("Unknown argument: " + option);
                }
            }

            return new ProducerOptions(
                    bootstrap,
                    database,
                    table,
                    bucketCount,
                    totalRecords,
                    runDuration,
                    recordsPerSecond,
                    flushEvery,
                    bufferSize,
                    batchSize,
                    statsInterval,
                    totalProducers,
                    instanceId,
                    numWriterThreads);
        }

        private static String requireValue(String option, String[] args, int index) {
            if (index >= args.length) {
                throw new IllegalArgumentException("Missing value for " + option);
            }
            return args[index];
        }
    }

    /**
     * Get integer value from environment variable, or return default if not set or invalid.
     */
    private static int getIntEnv(String envVar, int defaultValue) {
        String value = System.getenv(envVar);
        if (value == null || value.trim().isEmpty()) {
            return defaultValue;
        }
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            LOG.warn("Invalid value for environment variable {}: {}, using default: {}", envVar, value, defaultValue);
            return defaultValue;
        }
    }

    /**
     * Get string value from environment variable, or return default if not set.
     */
    private static String getEnv(String envVar, String defaultValue) {
        String value = System.getenv(envVar);
        if (value == null || value.trim().isEmpty()) {
            return defaultValue;
        }
        return value.trim();
    }

    private static double ratePerSecond(long records, long elapsedNanos) {
        if (elapsedNanos <= 0) {
            return 0d;
        }
        return records / (elapsedNanos / 1_000_000_000d);
    }

    private static Duration parseStatsInterval() {
        String interval = getEnv("PRODUCER_STATS_INTERVAL", "");
        if (!interval.isEmpty()) {
            return parseStatsIntervalValue(interval);
        }
        return Duration.ofSeconds(getIntEnv("PRODUCER_STATS_INTERVAL_SECONDS", 10));
    }

    private static Duration parseStatsIntervalValue(String value) {
        String trimmed = value.trim().toLowerCase(Locale.ROOT);
        if (trimmed.endsWith("ms")) {
            return Duration.ofMillis(Long.parseLong(trimmed.substring(0, trimmed.length() - 2)));
        }
        if (trimmed.endsWith("s")) {
            return Duration.ofSeconds(Long.parseLong(trimmed.substring(0, trimmed.length() - 1)));
        }
        return Duration.ofSeconds(Long.parseLong(trimmed));
    }

    /**
     * Generator for a specific device ID range.
     * Each device has its own independent state and generates data.
     */
    private static final class DeviceRangeGenerator {
        private final Random random = new Random();
        
        // Per-device generators (one Random per device for independent state)
        private final List<DeviceGenerator> deviceGenerators;

        private DeviceRangeGenerator(int startDeviceId, int endDeviceId) {
            // Create a generator for each device in the range
            this.deviceGenerators = new ArrayList<>(endDeviceId - startDeviceId);
            for (int deviceId = startDeviceId; deviceId < endDeviceId; deviceId++) {
                deviceGenerators.add(new DeviceGenerator(deviceId));
            }
        }

        /**
         * Generate next sensor data record from a random device in this range.
         * Device IDs are integers matching minimal schema.
         * Fluss will hash the sensor_id to determine the bucket (0-47).
         */
        private SensorDataMinimal next() {
            DeviceGenerator deviceGen = deviceGenerators.get(random.nextInt(deviceGenerators.size()));
            return deviceGen.next();
        }
    }

    /**
     * Generator for a single device with independent state.
     * Generates data for the minimal producer schema fields only.
     * Flink job will add default values for missing fields at the sink level.
     */
    private static final class DeviceGenerator {
        private final int deviceId;
        
        // Sensor types as integers (matching minimal schema):
        // 1=temperature, 2=humidity, 3=pressure, 4=motion, 5=light, 6=co2, 7=noise, 8=multisensor
        private static final int[] SENSOR_TYPES = {1, 2, 3, 4, 5, 6, 7, 8};
        
        private final Random random;

        private DeviceGenerator(int deviceId) {
            this.deviceId = deviceId;
            // Use device ID as seed for reproducible but independent per-device randomness
            this.random = new Random(deviceId);
        }

        private SensorDataMinimal next() {
            SensorDataMinimal data = new SensorDataMinimal();
            
            // Only fields matching AVRO schema:
            data.setSensorId(deviceId);  // INT: device ID as integer
            data.setSensorType(SENSOR_TYPES[random.nextInt(SENSOR_TYPES.length)]);  // INT: 1-8
            
            // Sensor readings (realistic ranges)
            data.setTemperature(10 + random.nextDouble() * 30);  // 10-40°C
            data.setHumidity(20 + random.nextDouble() * 60);     // 20-80%
            data.setPressure(980 + random.nextDouble() * 50);    // 980-1030 hPa
            
            // Device metrics
            data.setBatteryLevel(20 + random.nextDouble() * 80);  // 20-100%
            
            // Status (1=online, 2=offline, 3=maintenance, 4=error)
            // 85% online, 5% offline, 5% maintenance, 5% error
            int statusRoll = random.nextInt(100);
            if (statusRoll < 85) {
                data.setStatus(1);  // online
            } else if (statusRoll < 90) {
                data.setStatus(2);  // offline
            } else if (statusRoll < 95) {
                data.setStatus(3);  // maintenance
            } else {
                data.setStatus(4);  // error
            }
            
            // Timestamp in milliseconds since epoch
            data.setTimestamp(System.currentTimeMillis());
            
            return data;
        }
    }
}

