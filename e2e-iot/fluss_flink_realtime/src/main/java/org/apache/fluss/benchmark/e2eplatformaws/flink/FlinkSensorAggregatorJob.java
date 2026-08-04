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

import org.apache.fluss.benchmark.e2eplatformaws.model.SensorData;
import org.apache.flink.api.common.functions.AggregateFunction;
import org.apache.flink.api.common.functions.RichMapFunction;
import org.apache.flink.configuration.Configuration;
import org.apache.flink.metrics.Counter;
import org.apache.flink.metrics.Gauge;
import org.apache.flink.metrics.MetricGroup;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.datastream.SingleOutputStreamOperator;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.sink.RichSinkFunction;
import org.apache.flink.streaming.api.functions.windowing.ProcessWindowFunction;
import org.apache.flink.streaming.api.windowing.assigners.TumblingProcessingTimeWindows;
import org.apache.flink.streaming.api.windowing.time.Time;
import org.apache.flink.streaming.api.windowing.windows.TimeWindow;
import org.apache.flink.table.api.EnvironmentSettings;
import org.apache.flink.table.api.Table;
import org.apache.flink.table.api.bridge.java.StreamTableEnvironment;
import org.apache.flink.table.data.StringData;
import org.apache.flink.table.data.TimestampData;
import org.apache.flink.types.Row;
import org.apache.flink.types.RowKind;
import org.apache.flink.util.Collector;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.time.Instant;
import java.util.Locale;
import java.util.Objects;

/**
 * Flink streaming job that reads the primary-key table written by {@link
 * org.apache.fluss.benchmark.e2eplatformaws.producer.FlussSensorProducerApp}, performs tumbling-window aggregations, and
 * prints the results. The logic mirrors the Pulsar → Flink → ClickHouse path from the original
 * RealtimeDataPlatform example but uses Fluss as both the source and storage.
 */
public final class FlinkSensorAggregatorJob {
    private static final Logger LOG = LoggerFactory.getLogger(FlinkSensorAggregatorJob.class);

    // Set IPv4-only properties in static initializer to ensure they're set before any class loading
    static {
        System.setProperty("java.net.preferIPv4Stack", "true");
        System.setProperty("java.net.preferIPv4Addresses", "true");
    }

    public static void main(String[] args) throws Exception {
        // Ensure IPv4 properties are set
        System.setProperty("java.net.preferIPv4Stack", "true");
        System.setProperty("java.net.preferIPv4Addresses", "true");
        
        JobOptions options = JobOptions.parse(args);
        LOG.info("Starting Flink aggregation job with options: {}", options);

        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        // Enable checkpoints for fault tolerance
        // Checkpoint configuration is set in flink-conf.yaml
        // Using scan.startup.mode='latest' in table query to start from latest position
        EnvironmentSettings settings = EnvironmentSettings.newInstance().inStreamingMode().build();
        StreamTableEnvironment tEnv = StreamTableEnvironment.create(env, settings);

        String catalogDdl = String.format(
                Locale.ROOT,
                "CREATE CATALOG %s WITH (\n"
                        + "  'type' = 'fluss',\n"
                        + "  'bootstrap.servers' = '%s',\n"
                        + "  'default-database' = '%s'\n)",
                options.catalog,
                options.bootstrap,
                options.database);
        tEnv.executeSql(catalogDdl);
        tEnv.executeSql("USE CATALOG " + options.catalog);
        tEnv.executeSql("USE " + options.database);

        // Read from table with scan.startup.mode='latest' to start from latest position
        // instead of reading from the beginning
        String tableQuery = String.format(
                Locale.ROOT,
                "SELECT * FROM %s /*+ OPTIONS('scan.startup.mode' = 'latest') */",
                options.table);
        Table sourceTable = tEnv.sqlQuery(tableQuery);
        DataStream<Row> changelogStream = tEnv.toChangelogStream(sourceTable);

        // Filter for only INSERT and UPDATE_AFTER events (ignore UPDATE_BEFORE and DELETE)
        DataStream<Row> rowStream = changelogStream.filter(row -> {
            RowKind kind = row.getKind();
            return kind == RowKind.INSERT || kind == RowKind.UPDATE_AFTER;
        })
        .name("FlussChangelogFilter");

        // Use RichMapFunction to access Flink's built-in metrics API
        DataStream<SensorReading> sensorStream = rowStream
                .map(new RichMapFunction<Row, SensorReading>() {
                    private transient Counter recordsInCounter;
                    private transient MetricGroup customMetricsGroup;
                    
                    // Gauge implementation for event time lag
                    final class EventTimeLagGauge implements Gauge<Long> {
                        private volatile long lagMs = 0L;
                        
                        public void update(long lagMs) {
                            this.lagMs = lagMs;
                        }
                        
                        @Override
                        public Long getValue() {
                            return lagMs;
                        }
                    }
                    
                    private transient EventTimeLagGauge eventTimeLagGauge;
                    
                    @Override
                    public void open(Configuration parameters) throws Exception {
                        super.open(parameters);
                        // Get metric group for this operator
                        MetricGroup metricGroup = getRuntimeContext().getMetricGroup();
                        
                        // Create custom metrics group
                        customMetricsGroup = metricGroup.addGroup("fluss_aggregator");
                        
                        // Register counter for input records
                        recordsInCounter = customMetricsGroup.counter("records_in");
                        
                        // Register gauge for event time lag
                        eventTimeLagGauge = new EventTimeLagGauge();
                        customMetricsGroup.gauge("event_time_lag_ms", eventTimeLagGauge);
                    }
                    
                    @Override
                    public SensorReading map(Row reading) throws Exception {
                        // Increment input counter
                        recordsInCounter.inc();
                        
                        SensorReading sensorReading = FlinkSensorAggregatorJob.toSensorReading(reading);
                        
                        // Calculate event time lag (difference between event time and current time)
                        long eventTimeMs = sensorReading.eventTime.toEpochMilli();
                        long currentTimeMs = System.currentTimeMillis();
                        long lagMs = currentTimeMs - eventTimeMs;
                        eventTimeLagGauge.update(lagMs);
                        
                        return sensorReading;
                    }
                })
                .name("FlussSensorReadingMapper");

        // Windowing is now based on PROCESSING TIME. Watermarks are not needed.
        // Use incremental aggregation with ProcessWindowFunction for window metadata
        // Disable chaining to allow better parallelism distribution
        SingleOutputStreamOperator<SensorAggregate> aggregates = sensorStream
                .keyBy(reading -> reading.sensorId)
                .window(TumblingProcessingTimeWindows.of(Time.minutes(options.windowMinutes)))
                .aggregate(new SensorAggregateFunction(), new WindowEnricher())
                .name("TumblingWindowAggregation")
                .disableChaining();  // Disable chaining to allow better resource utilization

        aggregates
                .disableChaining()  // Disable chaining to separate window and sink operators
                .name("FlussAggregatorSink")  // Name the sink operator for metrics
                .addSink(new RichSinkFunction<SensorAggregate>() {
            private transient Counter recordsOutCounter;
            private transient MetricGroup customMetricsGroup;
            private transient long recordCount = 0L;
            private static final long PRINT_INTERVAL = 20000L; // Print every 20000 aggregates
            
            @Override
            public void open(Configuration parameters) throws Exception {
                super.open(parameters);
                // Get metric group for this sink
                MetricGroup metricGroup = getRuntimeContext().getMetricGroup();
                
                // Create custom metrics group
                customMetricsGroup = metricGroup.addGroup("fluss_aggregator");
                
                // Register counter for output records
                recordsOutCounter = customMetricsGroup.counter("records_out");
            }
            
            @Override
            public void invoke(SensorAggregate value, Context context) throws Exception {
                // Increment record count and counter for every record
                recordCount++;
                recordsOutCounter.inc();
                
                // Only log when actually needed (lazy evaluation)
                // This reduces overhead for 99.995% of records
                if (recordCount % PRINT_INTERVAL == 0) {
                    // Convert only when printing to avoid unnecessary work
                    SensorRecord fullRecord = toSensorRecord(value);
                    // Use LOG instead of System.out.println for async, non-blocking logging
                    LOG.info("Aggregate #{}: {} | Full Record: {}", recordCount, value, fullRecord);
                }
            }
        })
        .disableChaining();  // Ensure sink doesn't chain with downstream operators

        env.execute("Fluss Sensor Aggregation Job");
    }

    /**
     * Convert Fluss Row to SensorReading.
     * Fluss table schema: sensor_id (INT), sensor_type (INT), temperature, humidity, pressure, 
     *                     battery_level, status (INT), timestamp (BIGINT)
     */
    private static SensorReading toSensorReading(Row row) {
        // Read fields from Fluss table (minimal schema)
        int sensorIdInt = asInt(row.getField(0));
        int sensorTypeInt = asInt(row.getField(1));
        double temperature = asDouble(row.getField(2));
        double humidity = asDouble(row.getField(3));
        double pressure = asDouble(row.getField(4));
        double battery = asDouble(row.getField(5));
        int statusInt = asInt(row.getField(6));
        long timestamp = asLong(row.getField(7));
        
        // Convert to SensorReading format
        String sensorId = "sensor_" + sensorIdInt;
        String sensorType = getSensorTypeString(sensorTypeInt);
        String location = "site_" + String.format("%03d", (sensorIdInt % 100) + 1);
        String status = statusInt == 1 ? "ONLINE" : statusInt == 2 ? "OFFLINE" : 
                       statusInt == 3 ? "MAINTENANCE" : "ERROR";
        Instant eventTime = Instant.ofEpochMilli(timestamp);
        
        // Create metadata with default values (matching the full IoT sensor schema)
        SensorData.MetaData meta = new SensorData.MetaData(
            "AcmeSensors",  // manufacturer - default
            "X100",         // model - default
            "1.0.0",        // firmware - default
            0.0,            // latitude - default
            0.0             // longitude - default
        );
        
        return new SensorReading(sensorId, sensorType, location, temperature, humidity, pressure, battery, status, eventTime, meta);
    }
    
    /**
     * Convert SensorAggregate to SensorRecord with all fields (adding defaults matching the full IoT sensor schema).
     * This creates a full SensorRecord that can be written to ClickHouse or other sinks.
     */
    private static SensorRecord toSensorRecord(SensorAggregate aggregate) {
        SensorRecord record = new SensorRecord();
        
        // Extract sensor ID from aggregate (format: "sensor_12345")
        String sensorIdStr = aggregate.sensorId;
        int sensorIdInt = sensorIdStr.startsWith("sensor_") ? 
            Integer.parseInt(sensorIdStr.substring(7)) : 0;
        
        // Device identifiers (matching the full IoT sensor schema)
        record.device_id = sensorIdStr;
        record.device_type = aggregate.sensorType;
        record.customer_id = "customer_0001"; // Default value
        record.site_id = "site_" + String.format("%03d", (sensorIdInt % 100) + 1);
        
        // Location data - defaults (matching the full IoT sensor schema)
        record.latitude = 0.0;
        record.longitude = 0.0;
        record.altitude = 0.0;
        
        // Sensor readings from aggregate
        record.temperature = aggregate.avgTemperature;
        record.humidity = aggregate.avgHumidity;
        record.pressure = aggregate.avgPressure;
        
        // Additional sensor readings - defaults (matching the full IoT sensor schema)
        record.co2_level = 400.0;
        record.noise_level = 50.0;
        record.light_level = 500.0;
        record.motion_detected = 0;
        
        // Device metrics
        record.battery_level = aggregate.avgBatteryLevel;
        
        // Device metrics - defaults (matching the full IoT sensor schema)
        record.signal_strength = -50.0;
        record.memory_usage = 50.0;
        record.cpu_usage = 30.0;
        
        // Status - convert from string to int
        int statusInt = aggregate.latestStatus.equals("ONLINE") ? 1 :
                       aggregate.latestStatus.equals("OFFLINE") ? 2 :
                       aggregate.latestStatus.equals("MAINTENANCE") ? 3 : 4;
        record.status = statusInt;
        record.error_count = 0; // Default value
        
        // Network metrics - defaults (matching the full IoT sensor schema)
        record.packets_sent = 0L;
        record.packets_received = 0L;
        record.bytes_sent = 0L;
        record.bytes_received = 0L;
        
        return record;
    }
    
    /**
     * Convert integer sensor type to string (matching the full IoT sensor schema).
     * 1=temperature, 2=humidity, 3=pressure, 4=motion, 5=light, 6=co2, 7=noise, 8=multisensor
     */
    private static String getSensorTypeString(int sensorType) {
        switch (sensorType) {
            case 1: return "temperature_sensor";
            case 2: return "humidity_sensor";
            case 3: return "pressure_sensor";
            case 4: return "motion_sensor";
            case 5: return "light_sensor";
            case 6: return "co2_sensor";
            case 7: return "noise_sensor";
            case 8: return "multisensor";
            default: return "sensor_type_" + sensorType;
        }
    }
    
    private static int asInt(Object value) {
        if (value == null) {
            return 0;
        }
        if (value instanceof Number) {
            return ((Number) value).intValue();
        }
        return Integer.parseInt(value.toString());
    }
    
    private static long asLong(Object value) {
        if (value == null) {
            return 0L;
        }
        if (value instanceof Number) {
            return ((Number) value).longValue();
        }
        return Long.parseLong(value.toString());
    }

    private static double asDouble(Object value) {
        if (value == null) {
            return 0D;
        }
        if (value instanceof Number) {
            return ((Number) value).doubleValue();
        }
        return Double.parseDouble(value.toString());
    }

    private static String asString(Object field) {
        if (field == null) {
            return null;
        }
        if (field instanceof String) {
            return (String) field;
        }
        if (field instanceof StringData) {
            return field.toString();
        }
        return Objects.toString(field, null);
    }

    private static Instant asInstant(Object field) {
        if (field instanceof Instant) {
            return (Instant) field;
        }
        if (field instanceof TimestampData) {
            return ((TimestampData) field).toInstant();
        }
        if (field instanceof java.sql.Timestamp) {
            return ((java.sql.Timestamp) field).toInstant();
        }
        throw new IllegalArgumentException("Unsupported timestamp type: " + field);
    }

    private record JobOptions(String bootstrap, String database, String table, String catalog, int windowMinutes) {
        private static JobOptions parse(String[] args) {
            String bootstrap = "localhost:9124";
            String database = "iot";
            String table = "sensor_readings";
            String catalog = "fluss";
            int window = 1;

            for (int i = 0; i < args.length; i++) {
                switch (args[i]) {
                    case "--bootstrap":
                        bootstrap = args[++i];
                        break;
                    case "--database":
                        database = args[++i];
                        break;
                    case "--table":
                        table = args[++i];
                        break;
                    case "--catalog":
                        catalog = args[++i];
                        break;
                    case "--window-minutes":
                        window = Integer.parseInt(args[++i]);
                        break;
                    default:
                        throw new IllegalArgumentException("Unknown argument: " + args[i]);
                }
            }

            return new JobOptions(bootstrap, database, table, catalog, window);
        }
    }

    private static class SensorReading implements java.io.Serializable {
        private static final long serialVersionUID = 1L;
        final String sensorId;
        final String sensorType;
        final String location;
        final double temperature;
        final double humidity;
        final double pressure;
        final double batteryLevel;
        final String status;
        final Instant eventTime;
        final SensorData.MetaData metadata;

        SensorReading(String sensorId, String sensorType, String location,
                     double temperature, double humidity, double pressure,
                     double batteryLevel, String status, Instant eventTime,
                     SensorData.MetaData metadata) {
            this.sensorId = sensorId;
            this.sensorType = sensorType;
            this.location = location;
            this.temperature = temperature;
            this.humidity = humidity;
            this.pressure = pressure;
            this.batteryLevel = batteryLevel;
            this.status = status;
            this.eventTime = eventTime;
            this.metadata = metadata;
        }
    }

    private static class SensorAggregateFunction
            implements AggregateFunction<SensorReading, SensorAccumulator, SensorAccumulator> {

        @Override
        public SensorAccumulator createAccumulator() {
            return new SensorAccumulator();
        }

        @Override
        public SensorAccumulator add(SensorReading value, SensorAccumulator accumulator) {
            // Initialize on first record (avoid repeated null checks)
            if (accumulator.count == 0) {
                accumulator.sensorId = value.sensorId;
                accumulator.sensorType = value.sensorType;
                accumulator.location = value.location;
                accumulator.metadata = value.metadata;
                // Initialize min/max with first values to avoid Double.MAX_VALUE comparisons
                accumulator.temperatureMin = value.temperature;
                accumulator.temperatureMax = value.temperature;
                accumulator.humidityMin = value.humidity;
                accumulator.humidityMax = value.humidity;
                accumulator.pressureMin = value.pressure;
                accumulator.pressureMax = value.pressure;
                accumulator.batteryMin = value.batteryLevel;
                accumulator.batteryMax = value.batteryLevel;
                accumulator.latestEventTime = value.eventTime;
                accumulator.latestStatus = value.status;
            } else {
                // Optimized min/max comparisons (avoid Math.min/max overhead)
                double temp = value.temperature;
                if (temp < accumulator.temperatureMin) accumulator.temperatureMin = temp;
                else if (temp > accumulator.temperatureMax) accumulator.temperatureMax = temp;
                
                double hum = value.humidity;
                if (hum < accumulator.humidityMin) accumulator.humidityMin = hum;
                else if (hum > accumulator.humidityMax) accumulator.humidityMax = hum;
                
                double press = value.pressure;
                if (press < accumulator.pressureMin) accumulator.pressureMin = press;
                else if (press > accumulator.pressureMax) accumulator.pressureMax = press;
                
                double bat = value.batteryLevel;
                if (bat < accumulator.batteryMin) accumulator.batteryMin = bat;
                else if (bat > accumulator.batteryMax) accumulator.batteryMax = bat;
                
                // Update latest event time only if newer
                if (value.eventTime.isAfter(accumulator.latestEventTime)) {
                    accumulator.latestEventTime = value.eventTime;
                    accumulator.latestStatus = value.status;
                }
            }

            accumulator.count++;
            accumulator.temperatureSum += value.temperature;
            accumulator.humiditySum += value.humidity;
            accumulator.pressureSum += value.pressure;
            accumulator.batterySum += value.batteryLevel;
            
            return accumulator;
        }

        @Override
        public SensorAccumulator merge(SensorAccumulator a, SensorAccumulator b) {
            if (a.count == 0) {
                return b;
            }
            if (b.count == 0) {
                return a;
            }

            SensorAccumulator result = new SensorAccumulator();
            result.sensorId = a.sensorId;
            result.sensorType = a.sensorType;
            result.location = a.location;
            result.metadata = a.metadata;

            result.count = a.count + b.count;

            result.temperatureSum = a.temperatureSum + b.temperatureSum;
            result.temperatureMin = Math.min(a.temperatureMin, b.temperatureMin);
            result.temperatureMax = Math.max(a.temperatureMax, b.temperatureMax);

            result.humiditySum = a.humiditySum + b.humiditySum;
            result.humidityMin = Math.min(a.humidityMin, b.humidityMin);
            result.humidityMax = Math.max(a.humidityMax, b.humidityMax);

            result.pressureSum = a.pressureSum + b.pressureSum;
            result.pressureMin = Math.min(a.pressureMin, b.pressureMin);
            result.pressureMax = Math.max(a.pressureMax, b.pressureMax);

            result.batterySum = a.batterySum + b.batterySum;
            result.batteryMin = Math.min(a.batteryMin, b.batteryMin);
            result.batteryMax = Math.max(a.batteryMax, b.batteryMax);

            if (a.latestEventTime != null && b.latestEventTime != null) {
                if (a.latestEventTime.isAfter(b.latestEventTime)) {
                    result.latestEventTime = a.latestEventTime;
                    result.latestStatus = a.latestStatus;
                } else {
                    result.latestEventTime = b.latestEventTime;
                    result.latestStatus = b.latestStatus;
                }
            } else if (a.latestEventTime != null) {
                result.latestEventTime = a.latestEventTime;
                result.latestStatus = a.latestStatus;
            } else {
                result.latestEventTime = b.latestEventTime;
                result.latestStatus = b.latestStatus;
            }
            return result;
        }

        @Override
        public SensorAccumulator getResult(SensorAccumulator accumulator) {
            return accumulator;
        }
    }

    private static class WindowEnricher extends ProcessWindowFunction<
            SensorAccumulator, SensorAggregate, String, TimeWindow> {
        @Override
        public void process(String key, Context context, Iterable<SensorAccumulator> elements, Collector<SensorAggregate> out) {
            SensorAccumulator accumulator = elements.iterator().next();
            if (accumulator.count == 0) {
                return;
            }
            
            // Optimized: Calculate averages once and reuse
            long count = accumulator.count;
            double invCount = 1.0 / count;  // Use multiplication instead of division
            double avgTemp = accumulator.temperatureSum * invCount;
            double avgHumidity = accumulator.humiditySum * invCount;
            double avgPressure = accumulator.pressureSum * invCount;
            double avgBattery = accumulator.batterySum * invCount;

            // Create aggregate object directly (avoid intermediate variables)
            SensorAggregate aggregate = new SensorAggregate(
                    key,
                    accumulator.sensorType,
                    accumulator.location,
                    context.window().getStart(),
                    context.window().getEnd(),
                    avgTemp,
                    accumulator.temperatureMin,
                    accumulator.temperatureMax,
                    avgHumidity,
                    accumulator.humidityMin,
                    accumulator.humidityMax,
                    avgPressure,
                    accumulator.pressureMin,
                    accumulator.pressureMax,
                    avgBattery,
                    accumulator.batteryMin,
                    accumulator.batteryMax,
                    accumulator.latestStatus,
                    accumulator.latestEventTime == null ? 0L : accumulator.latestEventTime.toEpochMilli(),
                    accumulator.metadata);
            out.collect(aggregate);
        }
    }

    private static final class SensorAccumulator implements java.io.Serializable {
        private static final long serialVersionUID = 1L;
        private String sensorId;
        private String sensorType;
        private String location;
        private SensorData.MetaData metadata;
        private long count = 0L;

        private double temperatureSum = 0D;
        private double temperatureMin = Double.POSITIVE_INFINITY;
        private double temperatureMax = Double.NEGATIVE_INFINITY;

        private double humiditySum = 0D;
        private double humidityMin = Double.POSITIVE_INFINITY;
        private double humidityMax = Double.NEGATIVE_INFINITY;

        private double pressureSum = 0D;
        private double pressureMin = Double.POSITIVE_INFINITY;
        private double pressureMax = Double.NEGATIVE_INFINITY;

        private double batterySum = 0D;
        private double batteryMin = Double.POSITIVE_INFINITY;
        private double batteryMax = Double.NEGATIVE_INFINITY;

        private Instant latestEventTime;
        private String latestStatus;
    }

    /**
     * SensorRecord matching the full IoT sensor schema schema.
     * Contains all fields needed for ClickHouse sink, with defaults added at sink level.
     */
    private static class SensorRecord implements java.io.Serializable {
        private static final long serialVersionUID = 1L;
        // Device identifiers
        String device_id;
        String device_type;
        String customer_id;
        String site_id;
        
        // Location data
        double latitude;
        double longitude;
        double altitude;
        
        // Sensor readings
        double temperature;
        double humidity;
        double pressure;
        double co2_level;
        double noise_level;
        double light_level;
        int motion_detected;
        
        // Device metrics
        double battery_level;
        double signal_strength;
        double memory_usage;
        double cpu_usage;
        
        // Status
        int status;
        int error_count;
        
        // Network metrics
        long packets_sent;
        long packets_received;
        long bytes_sent;
        long bytes_received;
        
        @Override
        public String toString() {
            return String.format(
                    Locale.ROOT,
                    "SensorRecord{device_id=%s, device_type=%s, customer_id=%s, site_id=%s, " +
                    "temperature=%.2f, humidity=%.2f, pressure=%.2f, battery_level=%.2f, status=%d}",
                    device_id, device_type, customer_id, site_id,
                    temperature, humidity, pressure, battery_level, status);
        }
    }

    private static class SensorAggregate implements java.io.Serializable {
        private static final long serialVersionUID = 1L;
        final String sensorId;
        final String sensorType;
        final String location;
        final long windowStart;
        final long windowEnd;
        final double avgTemperature;
        final double minTemperature;
        final double maxTemperature;
        final double avgHumidity;
        final double minHumidity;
        final double maxHumidity;
        final double avgPressure;
        final double minPressure;
        final double maxPressure;
        final double avgBatteryLevel;
        final double minBatteryLevel;
        final double maxBatteryLevel;
        final String latestStatus;
        final long latestEventTime;
        final SensorData.MetaData metadata;

        SensorAggregate(String sensorId, String sensorType, String location,
                       long windowStart, long windowEnd,
                       double avgTemperature, double minTemperature, double maxTemperature,
                       double avgHumidity, double minHumidity, double maxHumidity,
                       double avgPressure, double minPressure, double maxPressure,
                       double avgBatteryLevel, double minBatteryLevel, double maxBatteryLevel,
                       String latestStatus, long latestEventTime, SensorData.MetaData metadata) {
            this.sensorId = sensorId;
            this.sensorType = sensorType;
            this.location = location;
            this.windowStart = windowStart;
            this.windowEnd = windowEnd;
            this.avgTemperature = avgTemperature;
            this.minTemperature = minTemperature;
            this.maxTemperature = maxTemperature;
            this.avgHumidity = avgHumidity;
            this.minHumidity = minHumidity;
            this.maxHumidity = maxHumidity;
            this.avgPressure = avgPressure;
            this.minPressure = minPressure;
            this.maxPressure = maxPressure;
            this.avgBatteryLevel = avgBatteryLevel;
            this.minBatteryLevel = minBatteryLevel;
            this.maxBatteryLevel = maxBatteryLevel;
            this.latestStatus = latestStatus;
            this.latestEventTime = latestEventTime;
            this.metadata = metadata;
        }

        @Override
        public String toString() {
            return String.format(
                    Locale.ROOT,
                    "SensorAggregate{sensorId=%s, window=[%s,%s), avgTemp=%.2f, avgHumidity=%.2f, avgPressure=%.2f, avgBattery=%.2f, status=%s}",
                    sensorId,
                    Instant.ofEpochMilli(windowStart),
                    Instant.ofEpochMilli(windowEnd),
                    avgTemperature,
                    avgHumidity,
                    avgPressure,
                    avgBatteryLevel,
                    latestStatus);
        }
    }
}
