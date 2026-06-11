/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.openmessaging.benchmark.driver.fluss;

import static org.apache.fluss.utils.function.ThrowingConsumer.unchecked;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.ObjectWriter;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.openmessaging.benchmark.driver.BenchmarkConsumer;
import io.openmessaging.benchmark.driver.BenchmarkDriver;
import io.openmessaging.benchmark.driver.BenchmarkProducer;
import io.openmessaging.benchmark.driver.ConsumerCallback;
import java.io.File;
import java.io.IOException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import org.apache.bookkeeper.stats.StatsLogger;
import org.apache.fluss.client.Connection;
import org.apache.fluss.compression.ArrowCompressionType;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.admin.Admin;
import org.apache.fluss.config.ConfigOptions;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.config.MemorySize;
import org.apache.fluss.metadata.DatabaseDescriptor;
import org.apache.fluss.metadata.LogFormat;
import org.apache.fluss.metadata.Schema;
import org.apache.fluss.metadata.TableDescriptor;
import org.apache.fluss.metadata.TablePath;
import org.apache.fluss.types.DataTypes;
import org.apache.fluss.types.RowType;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Fluss benchmark driver. */
public class FlussBenchmarkDriver implements BenchmarkDriver {
    private static final Logger LOG = LoggerFactory.getLogger(FlussBenchmarkDriver.class);

    public static final String DEFAULT_DATABASE_NAME = "benchmarkDb";
    private static final ObjectWriter writer = new ObjectMapper().writerWithDefaultPrettyPrinter();
    private static final ObjectMapper mapper =
            new ObjectMapper(new YAMLFactory())
                    .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    private FlussConfig config;
    private Configuration flussConfiguration;
    private Connection connection;
    private Admin flussAdmin;
    private int[] projectFields;
    private LogFormat logFormat;
    private ArrowCompressionType arrowCompressionType;
    private Schema schema;
    private RowType rowType;
    private String[] schemaTypes;

    private final List<BenchmarkProducer> producers = Collections.synchronizedList(new ArrayList<>());
    private final List<BenchmarkConsumer> consumers = Collections.synchronizedList(new ArrayList<>());
    private final List<String> createdTopics = Collections.synchronizedList(new ArrayList<>());

    @Override
    public void initialize(File configurationFile, StatsLogger statsLogger) throws IOException {
        this.config = mapper.readValue(configurationFile, FlussConfig.class);
        LOG.info("Fluss driver conf: {}", writer.writeValueAsString(config));

        this.schemaTypes = config.schema.split("-");
        if (schemaTypes.length == 0 || !schemaTypes[0].equals("long")) {
            throw new IllegalArgumentException(
                    "Schema must start with 'long' for E2E timestamp. Got: " + config.schema);
        }

        this.schema = buildSchema(schemaTypes);
        this.rowType = schema.getRowType();
        this.flussConfiguration = buildFlussConfiguration(config);
        this.connection = ConnectionFactory.createConnection(flussConfiguration);
        this.flussAdmin = connection.getAdmin();
    }

    @Override
    public String getTopicNamePrefix() {
        return "Fluss-Benchmark";
    }

    @Override
    public CompletableFuture<Void> createTopic(String topic, int partitions) {
        try {
            flussAdmin.createDatabase(DEFAULT_DATABASE_NAME, DatabaseDescriptor.EMPTY, true).get();
        } catch (Exception e) {
            throw new RuntimeException("Exception occurs while creating Fluss database.", e);
        }

        TableDescriptor.Builder tableBuilder =
                TableDescriptor.builder()
                        .schema(schema)
                        .logFormat(logFormat);
        if (config.tieredLogLocalSegments >= 0) {
            tableBuilder.property(
                    ConfigOptions.TABLE_TIERED_LOG_LOCAL_SEGMENTS, config.tieredLogLocalSegments);
        }
        tableBuilder.property(
                ConfigOptions.TABLE_LOG_ARROW_COMPRESSION_TYPE, arrowCompressionType);
        TableDescriptor tableDescriptor = tableBuilder.distributedBy(partitions).build();
        createdTopics.add(topic);
        return flussAdmin.createTable(
                new TablePath(DEFAULT_DATABASE_NAME, topic), tableDescriptor, false);
    }

    @Override
    public CompletableFuture<BenchmarkProducer> createProducer(String topic) {
        try {
            BenchmarkProducer benchmarkProducer =
                    new FlussBenchmarkProducer(flussConfiguration, topic, schemaTypes, rowType);
            producers.add(benchmarkProducer);
            return CompletableFuture.completedFuture(benchmarkProducer);
        } catch (Throwable t) {
            CompletableFuture<BenchmarkProducer> future = new CompletableFuture<>();
            future.completeExceptionally(t);
            return future;
        }
    }

    @Override
    public CompletableFuture<BenchmarkConsumer> createConsumer(
            int id,
            int partitionsPerTopic,
            int partitionsPerSubscription,
            String topic,
            String subscriptionName,
            ConsumerCallback consumerCallback) {
        try {
            List<Integer> subscriptionBuckets =
                    calculateSubscriptionBuckets(id, partitionsPerTopic, partitionsPerSubscription);
            FlussBenchmarkConsumer consumer =
                    new FlussBenchmarkConsumer(
                            flussConfiguration, topic, projectFields, subscriptionBuckets, consumerCallback);
            consumers.add(consumer);
            return CompletableFuture.completedFuture(consumer);
        } catch (Throwable t) {
            CompletableFuture<BenchmarkConsumer> future = new CompletableFuture<>();
            future.completeExceptionally(t);
            return future;
        }
    }

    @Override
    public void close() {
        try {
            producers.forEach(unchecked(BenchmarkProducer::close));
        } catch (Exception e) {
            LOG.warn("Exception occurs while closing producers.", e);
        }
        try {
            consumers.forEach(unchecked(BenchmarkConsumer::close));
        } catch (Exception e) {
            LOG.warn("Exception occurs while closing consumers.", e);
        }

        for (String topic : createdTopics) {
            try {
                flussAdmin
                        .dropTable(
                                new TablePath(DEFAULT_DATABASE_NAME, topic),
                                false)
                        .get();
                LOG.info("Dropped table: {}", topic);
            } catch (Exception e) {
                LOG.warn("Failed to drop table: {}", topic, e);
            }
        }

        try {
            if (connection != null) {
                connection.close();
            }
        } catch (Exception e) {
            LOG.warn("Exception occurs while closing Fluss Connection.", e);
        }
        connection = null;
    }

    private static Schema buildSchema(String[] types) {
        Schema.Builder builder = Schema.newBuilder();
        for (int i = 0; i < types.length; i++) {
            String colName = "col" + i;
            switch (types[i]) {
                case "int":
                    builder.column(colName, DataTypes.INT());
                    break;
                case "long":
                    builder.column(colName, DataTypes.BIGINT());
                    break;
                case "string":
                    builder.column(colName, DataTypes.STRING());
                    break;
                default:
                    throw new IllegalArgumentException("Unsupported schema type: " + types[i]);
            }
        }
        return builder.build();
    }

    private Configuration buildFlussConfiguration(FlussConfig config) {
        Configuration conf = new Configuration();
        conf.setString(ConfigOptions.BOOTSTRAP_SERVERS.key(), config.bootstrapServers);
        conf.setString(ConfigOptions.CLIENT_WRITER_ACKS.key(), config.writerAcks);
        conf.setBoolean(ConfigOptions.CLIENT_WRITER_ENABLE_IDEMPOTENCE, config.writerIdempotenceEnabled);
        conf.set(ConfigOptions.CLIENT_WRITER_BATCH_SIZE, MemorySize.parse(config.writerBatchSize));
        conf.set(
                ConfigOptions.CLIENT_WRITER_BUFFER_MEMORY_SIZE,
                MemorySize.parse(config.writerBufferMemory));
        conf.set(
                ConfigOptions.CLIENT_WRITER_BATCH_TIMEOUT, Duration.ofMillis(config.writerBatchTimeoutMs));
        conf.setInt(ConfigOptions.NETTY_CLIENT_NUM_NETWORK_THREADS, config.clientNettyThreads);
        conf.set(
                ConfigOptions.CLIENT_SCANNER_LOG_FETCH_MAX_BYTES, MemorySize.parse(config.fetchMaxBytes));
        conf.set(ConfigOptions.CLIENT_SCANNER_REMOTE_LOG_PREFETCH_NUM, config.prefetchNum);
        conf.setBoolean(ConfigOptions.CLIENT_SCANNER_LOG_CHECK_CRC, config.isCheckCrc);
        // Consumer scanner tuning (added to address consumer drain bottleneck observed at high throughput).
        conf.setInt(ConfigOptions.CLIENT_SCANNER_LOG_MAX_POLL_RECORDS, config.scannerMaxPollRecords);
        conf.set(
                ConfigOptions.CLIENT_SCANNER_LOG_FETCH_WAIT_MAX_TIME,
                Duration.ofMillis(config.scannerFetchWaitMaxTimeMs));
        conf.set(
                ConfigOptions.CLIENT_SCANNER_LOG_FETCH_MAX_BYTES_FOR_BUCKET,
                MemorySize.parse(config.scannerFetchMaxBytesForBucket));
        conf.set(
                ConfigOptions.CLIENT_SCANNER_LOG_FETCH_MIN_BYTES,
                MemorySize.parse(config.scannerFetchMinBytes));

        conf.setString(
                ConfigOptions.CLIENT_SECURITY_PROTOCOL.key(), config.securityProtocol);
        if (config.saslUsername != null && !config.saslUsername.isEmpty()) {
            conf.setString(
                    ConfigOptions.CLIENT_SASL_MECHANISM.key(), config.saslMechanism);
            conf.setString(
                    ConfigOptions.CLIENT_SASL_JAAS_USERNAME.key(), config.saslUsername);
            conf.setString(
                    ConfigOptions.CLIENT_SASL_JAAS_PASSWORD.key(), config.saslPassword);
        }

        if (config.logFormat.equals(LogFormat.INDEXED.toString())) {
            this.logFormat = LogFormat.INDEXED;
        } else {
            this.logFormat = LogFormat.ARROW;
        }

        this.arrowCompressionType =
                ArrowCompressionType.valueOf(config.arrowCompressionType.toUpperCase());

        String projectFieldString = config.projectFields;
        if (projectFieldString.equals("all")) {
            projectFields = new int[0];
        } else {
            String[] fields = projectFieldString.split("/");
            projectFields = new int[fields.length];
            for (int i = 0; i < fields.length; i++) {
                projectFields[i] = Integer.parseInt(fields[i]);
            }
        }

        return conf;
    }

    private List<Integer> calculateSubscriptionBuckets(
            int id, int partitionsPerTopic, int subscriptionsPerTopic) {
        List<Integer> buckets = new ArrayList<>();

        int partitionsPerSubscription = partitionsPerTopic / subscriptionsPerTopic;
        int extraPartitions = partitionsPerTopic % subscriptionsPerTopic;

        int startBucket;
        if (id < extraPartitions) {
            startBucket = id * (partitionsPerSubscription + 1);
        } else {
            startBucket = id * partitionsPerSubscription + extraPartitions;
        }

        int endBucket = startBucket + partitionsPerSubscription - 1;
        if (id < extraPartitions) {
            endBucket += 1;
        }

        for (int i = startBucket; i <= endBucket; i++) {
            buckets.add(i);
        }
        LOG.info(
                "id: {}, the subscriptionBuckets is {}, total buckets: {}, total consumers: {}",
                id,
                buckets,
                partitionsPerTopic,
                subscriptionsPerTopic);
        return buckets;
    }
}
