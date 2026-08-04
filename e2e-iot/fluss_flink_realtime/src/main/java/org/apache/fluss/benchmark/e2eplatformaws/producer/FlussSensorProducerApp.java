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

import org.apache.fluss.benchmark.e2eplatformaws.model.SensorData;
import org.apache.fluss.benchmark.e2eplatformaws.model.SensorData.MetaData;
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
import org.apache.fluss.row.BinaryString;
import org.apache.fluss.row.GenericRow;
import org.apache.fluss.row.TimestampLtz;
import org.apache.fluss.types.DataTypes;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Simple Fluss producer that continuously writes randomly generated sensor data into a primary key
 * table. The schema mirrors the IoT pipeline that previously used Pulsar.
 */
public final class FlussSensorProducerApp {
    private static final Logger LOG = LoggerFactory.getLogger(FlussSensorProducerApp.class);

    // Set IPv4-only properties in static initializer to ensure they're set before any class loading
    static {
        System.setProperty("java.net.preferIPv4Stack", "true");
        System.setProperty("java.net.preferIPv4Addresses", "true");
        // Disable IPv6 completely
        System.setProperty("java.net.useSystemProxies", "false");
    }

    public static void main(String[] args) throws Exception {
        // Ensure IPv4 properties are set (redundant but safe)
        System.setProperty("java.net.preferIPv4Stack", "true");
        System.setProperty("java.net.preferIPv4Addresses", "true");
        
        ProducerOptions options = ProducerOptions.parse(args);
        LOG.info("Starting Fluss producer with options: {}", options);

        Configuration flussConf = new Configuration();
        flussConf.set(ConfigOptions.BOOTSTRAP_SERVERS, Collections.singletonList(options.bootstrap));
        flussConf.set(ConfigOptions.CLIENT_WRITER_BUFFER_MEMORY_SIZE, options.writerBufferSize);
        flussConf.set(ConfigOptions.CLIENT_WRITER_BATCH_SIZE, options.writerBatchSize);
        
        // Start Prometheus metrics server
        ProducerMetrics metrics = new ProducerMetrics(8080);
        metrics.start();
        LOG.info("Prometheus metrics server started on port 8080");

        TablePath tablePath = TablePath.of(options.database, options.table);

        try (Connection connection = ConnectionFactory.createConnection(flussConf)) {
            ensureSchema(connection, tablePath, options.bucketCount);

            try (Table table = connection.getTable(tablePath)) {
                UpsertWriter writer = table.newUpsert().createWriter();
                AtomicBoolean running = new AtomicBoolean(true);
                Runtime.getRuntime()
                        .addShutdownHook(new Thread(() -> shutdown(writer, running), "fluss-producer-shutdown"));

                RandomSensorDataGenerator generator =
                        new RandomSensorDataGenerator(options.sensorPoolSize, options.statusValues);

                long sent = 0;
                long startNano = System.nanoTime();
                long lastStatsNano = startNano;
                long lastStatsRecords = 0;
                long statsIntervalNanos = options.statsInterval.toNanos();
                long nanosPerRecord = options.recordsPerSecond > 0
                        ? TimeUnit.SECONDS.toNanos(1) / options.recordsPerSecond
                        : 0;
                long stopAtCount = options.totalRecords > 0 ? options.totalRecords : Long.MAX_VALUE;
                long stopAtTime = options.runDuration.isZero()
                        ? Long.MAX_VALUE
                        : System.nanoTime() + options.runDuration.toNanos();

                while (running.get() && sent < stopAtCount && System.nanoTime() < stopAtTime) {
                    SensorData record = generator.next();
                    writeToFluss(writer, record);
                    sent++;
                    metrics.recordWrite(); // Record metric

                    if (sent % options.flushEvery == 0) {
                        writer.flush();
                        LOG.debug("Flushed {} records", sent);
                    }

                    long now = System.nanoTime();
                    if (now - lastStatsNano >= statsIntervalNanos) {
                        double overallRate = ratePerSecond(sent, now - startNano);
                        double windowRate = ratePerSecond(sent - lastStatsRecords, now - lastStatsNano);
                        LOG.info(
                                "Produced {} records (overall ~{} rec/s, last window ~{} rec/s)",
                                sent,
                                String.format(Locale.ROOT, "%.0f", overallRate),
                                String.format(Locale.ROOT, "%.0f", windowRate));
                        lastStatsNano = now;
                        lastStatsRecords = sent;
                        metrics.updateStats(sent);
                    }

                    if (nanosPerRecord > 0) {
                        long target = startNano + sent * nanosPerRecord;
                        long wait = target - System.nanoTime();
                        if (wait > 0) {
                            TimeUnit.NANOSECONDS.sleep(wait);
                        }
                    }
                }

                writer.flush();
                LOG.info("Producer stopped after emitting {} records", sent);
            }
        } finally {
            metrics.stop();
        }
    }

    private static void shutdown(UpsertWriter writer, AtomicBoolean running) {
        LOG.info("Shutdown requested – flushing pending records");
        running.set(false);
        try {
            writer.flush();
        } catch (Exception e) {
            LOG.warn("Unable to flush writer during shutdown", e);
        }
    }

    private static void ensureSchema(Connection connection, TablePath tablePath, int bucketCount)
            throws Exception {
        try (Admin admin = connection.getAdmin()) {
            admin.createDatabase(
                            tablePath.getDatabaseName(),
                            DatabaseDescriptor.builder().comment("IoT demo database").build(),
                            true)
                    .get();

            Schema schema = Schema.newBuilder()
                    .primaryKey("sensor_id")
                    .column("sensor_id", DataTypes.STRING())
                    .column("sensor_type", DataTypes.STRING())
                    .column("location", DataTypes.STRING())
                    .column("temperature", DataTypes.DOUBLE())
                    .column("humidity", DataTypes.DOUBLE())
                    .column("pressure", DataTypes.DOUBLE())
                    .column("battery_level", DataTypes.DOUBLE())
                    .column("status", DataTypes.STRING())
                    .column("event_time", DataTypes.TIMESTAMP_LTZ())
                    .column("manufacturer", DataTypes.STRING())
                    .column("model", DataTypes.STRING())
                    .column("firmware_version", DataTypes.STRING())
                    .column("latitude", DataTypes.DOUBLE())
                    .column("longitude", DataTypes.DOUBLE())
                    .build();

            TableDescriptor descriptor = TableDescriptor.builder()
                    .schema(schema)
                    .comment("Realtime sensor readings")
                    .distributedBy(bucketCount, "sensor_id")
                    .build();

            admin.createTable(tablePath, descriptor, true).get();
            LOG.info("Ensured Fluss table {} exists ({} buckets)", tablePath, bucketCount);
        }
    }

    private static void writeToFluss(UpsertWriter writer, SensorData data) throws Exception {
        GenericRow row = new GenericRow(14);
        row.setField(0, BinaryString.fromString(data.getSensorId()));
        row.setField(1, BinaryString.fromString(nonNull(data.getSensorType())));
        row.setField(2, BinaryString.fromString(nonNull(data.getLocation())));
        row.setField(3, data.getTemperature());
        row.setField(4, data.getHumidity());
        row.setField(5, data.getPressure());
        row.setField(6, data.getBatteryLevel());
        row.setField(7, BinaryString.fromString(nonNull(data.getStatus())));
        row.setField(8, TimestampLtz.fromInstant(data.getEventTime()));

        MetaData meta = data.getMetadata();
        if (meta != null) {
            row.setField(9, BinaryString.fromString(nonNull(meta.getManufacturer())));
            row.setField(10, BinaryString.fromString(nonNull(meta.getModel())));
            row.setField(11, BinaryString.fromString(nonNull(meta.getFirmwareVersion())));
            row.setField(12, meta.getLatitude());
            row.setField(13, meta.getLongitude());
        } else {
            row.setField(9, null);
            row.setField(10, null);
            row.setField(11, null);
            row.setField(12, null);
            row.setField(13, null);
        }

        writer.upsert(row);
    }

    private static String nonNull(String value) {
        return value == null ? "" : value;
    }

    private record ProducerOptions(
            String bootstrap,
            String database,
            String table,
            int bucketCount,
            int sensorPoolSize,
            long totalRecords,
            Duration runDuration,
            int recordsPerSecond,
            int flushEvery,
            MemorySize writerBufferSize,
            MemorySize writerBatchSize,
            Duration statsInterval,
            List<String> statusValues) {
        private static ProducerOptions parse(String[] args) {
            String bootstrap = "localhost:9124";
            String database = "iot";
            String table = "sensor_readings";
            int bucketCount = 12;
            int sensorPool = 10_000;
            long totalRecords = 0L;
            Duration runDuration = Duration.ZERO;
            // Check environment variable first, then use default
            int recordsPerSecond = getIntEnv("PRODUCER_RATE", 5000);
            int flushEvery = getIntEnv("PRODUCER_FLUSH_EVERY", 5000);
            Duration statsInterval = parseStatsInterval();
            // Read buffer and batch sizes from environment variables
            String bufferSizeStr = getEnv("CLIENT_WRITER_BUFFER_MEMORY_SIZE", "32mb");
            String batchSizeStr = getEnv("CLIENT_WRITER_BATCH_SIZE", "4mb");
            MemorySize bufferSize = MemorySize.parse(bufferSizeStr);
            MemorySize batchSize = MemorySize.parse(batchSizeStr);
            List<String> statuses = List.of("ONLINE", "OFFLINE", "MAINTENANCE", "DEGRADED");

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
                    case "--sensors":
                        sensorPool = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--count":
                        totalRecords = Long.parseLong(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--duration":
                        String durationValue = inlineValue != null ? inlineValue : requireValue(option, args, ++i);
                        runDuration = Duration.parse("PT" + durationValue.toUpperCase(Locale.ROOT));
                        break;
                    case "--rate":
                        // Command-line argument overrides environment variable
                        recordsPerSecond = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--flush":
                        // Command-line argument overrides environment variable
                        flushEvery = Integer.parseInt(inlineValue != null ? inlineValue : requireValue(option, args, ++i));
                        break;
                    case "--stats-interval":
                        statsInterval = parseStatsIntervalValue(
                                inlineValue != null ? inlineValue : requireValue(option, args, ++i));
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
                    sensorPool,
                    totalRecords,
                    runDuration,
                    recordsPerSecond,
                    flushEvery,
                    bufferSize,
                    batchSize,
                    statsInterval,
                    statuses);
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

    private static final class RandomSensorDataGenerator {
        private final List<String> sensorIds;
        private final List<String> sensorTypes = List.of(
                "temperature_sensor",
                "humidity_sensor",
                "pressure_sensor",
                "motion_sensor",
                "light_sensor",
                "co2_sensor",
                "noise_sensor",
                "multisensor");
        private final List<String> locations = List.of("site-nyc-1", "site-sfo-2", "site-lon-1", "site-sin-3");
        private final List<String> manufacturers = List.of("AcmeSensors", "FluxTech", "IoTica", "HyperLoop");
        private final List<String> models = List.of("X100", "A12", "S9", "M5");
        private final List<String> firmwareVersions = List.of("1.0.0", "1.1.3", "2.0.1");
        private final List<String> statusValues;
        private final Random random = new Random();

        private RandomSensorDataGenerator(int poolSize, List<String> statusValues) {
            this.sensorIds = new ArrayList<>(poolSize);
            this.statusValues = statusValues;
            for (int i = 0; i < poolSize; i++) {
                sensorIds.add(String.format(Locale.ROOT, "sensor-%06d", i));
            }
        }

        private SensorData next() {
            String sensorId = sensorIds.get(random.nextInt(sensorIds.size()));
            String sensorType = sensorTypes.get(random.nextInt(sensorTypes.size()));
            String location = locations.get(random.nextInt(locations.size()));
            double temperature = 10 + random.nextDouble() * 20;
            double humidity = 30 + random.nextDouble() * 50;
            double pressure = 990 + random.nextDouble() * 40;
            double batteryLevel = 20 + random.nextDouble() * 80;
            String status = statusValues.get(random.nextInt(statusValues.size()));
            Instant eventTime = Instant.now();

            double latitude = 30 + random.nextDouble() * 20;
            double longitude = -120 + random.nextDouble() * 60;
            MetaData meta = new MetaData(
                    manufacturers.get(random.nextInt(manufacturers.size())),
                    models.get(random.nextInt(models.size())),
                    firmwareVersions.get(random.nextInt(firmwareVersions.size())),
                    latitude,
                    longitude);

            return new SensorData(
                    sensorId,
                    sensorType,
                    location,
                    temperature,
                    humidity,
                    pressure,
                    batteryLevel,
                    status,
                    eventTime,
                    meta);
        }
    }
}
