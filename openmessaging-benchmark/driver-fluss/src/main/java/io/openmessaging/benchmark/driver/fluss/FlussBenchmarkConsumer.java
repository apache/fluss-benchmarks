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

import static io.openmessaging.benchmark.driver.fluss.FlussBenchmarkDriver.DEFAULT_DATABASE_NAME;

import io.openmessaging.benchmark.driver.BenchmarkConsumer;
import io.openmessaging.benchmark.driver.ConsumerCallback;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.apache.fluss.client.Connection;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.table.Table;
import org.apache.fluss.client.table.scanner.Scan;
import org.apache.fluss.client.table.scanner.log.LogScanner;
import org.apache.fluss.client.table.scanner.log.ScanRecords;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.metadata.TablePath;
import org.apache.fluss.row.BinaryString;
import org.apache.fluss.row.InternalRow;
import org.apache.fluss.types.DataType;
import org.apache.fluss.types.DataTypeRoot;
import org.apache.fluss.types.RowType;
import org.apache.fluss.utils.IOUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Fluss benchmark consumer. */
public class FlussBenchmarkConsumer implements BenchmarkConsumer {

    private static final Logger LOG = LoggerFactory.getLogger(FlussBenchmarkConsumer.class);

    private Connection connection;
    private final Table table;
    private final LogScanner logScanner;
    private final int fieldLength;
    private final InternalRow.FieldGetter[] flussFieldGetters;
    private final RowType projectRowType;
    private final ConsumerCallback callback;
    private final ExecutorService executor;
    private final Future<?> consumerTask;
    private volatile boolean closing = false;

    public FlussBenchmarkConsumer(
            Configuration conf,
            String topic,
            int[] projectFields,
            List<Integer> subscriptionBuckets,
            ConsumerCallback callback) {
        this(conf, topic, projectFields, subscriptionBuckets, callback, 100L);
    }

    public FlussBenchmarkConsumer(
            Configuration conf,
            String topic,
            int[] projectFields,
            List<Integer> subscriptionBuckets,
            ConsumerCallback callback,
            long pollTimeoutMs) {
        this.connection = ConnectionFactory.createConnection(conf);
        this.callback = callback;
        this.table = connection.getTable(new TablePath(DEFAULT_DATABASE_NAME, topic));
        RowType originRowType = table.getTableInfo().getRowType();
        this.logScanner = createLogScanner(table, projectFields, subscriptionBuckets);
        if (projectFields.length == 0) {
            this.projectRowType = new RowType(originRowType.getFields());
            this.fieldLength = originRowType.getFieldCount();
        } else {
            this.projectRowType = originRowType.project(projectFields);
            this.fieldLength = projectRowType.getFieldCount();
        }
        this.flussFieldGetters = new InternalRow.FieldGetter[fieldLength];
        for (int i = 0; i < fieldLength; i++) {
            flussFieldGetters[i] = InternalRow.createFieldGetter(projectRowType.getTypeAt(i), i);
        }

        this.executor = Executors.newSingleThreadExecutor();
        this.consumerTask =
                this.executor.submit(
                        () -> {
                            while (!closing) {
                                try {
                                    ScanRecords records = logScanner.poll(Duration.ofMillis(pollTimeoutMs));
                                    records.forEach(record -> processRecord(record.getRow()));
                                } catch (Exception e) {
                                    LOG.error("exception occur while consuming message", e);
                                }
                            }
                        });
    }

    private void processRecord(InternalRow row) {
        if (fieldLength <= 0) {
            LOG.warn("No fields available in the row to process");
            return;
        }
        long timeStamp = (long) flussFieldGetters[0].getFieldOrNull(row);
        // Include all fields (including field 0) in the size calculation
        // to match the producer's messageSize-based byte reporting.
        int sizeInBytes = objectSizes(null, projectRowType.getTypeAt(0));
        for (int i = 1; i < fieldLength; i++) {
            Object value = flussFieldGetters[i].getFieldOrNull(row);
            sizeInBytes += objectSizes(value, projectRowType.getTypeAt(i));
        }
        callback.messageReceived(new byte[sizeInBytes], timeStamp);
    }

    private LogScanner createLogScanner(
            Table table, int[] projectFields, List<Integer> subscriptionBuckets) {
        LogScanner logScanner;
        if (projectFields.length == 0) {
            logScanner = table.newScan().createLogScanner();
        } else {
            //            logScanner = new LogScan().withProjectedFields(projectFields);
            Scan projectScan = table.newScan().project(projectFields);
            logScanner = projectScan.createLogScanner();
        }
        for (int subscriptionBucket : subscriptionBuckets) {
            logScanner.subscribeFromBeginning(subscriptionBucket);
        }

        return logScanner;
    }

    private int objectSizes(Object obj, DataType type) {
        DataTypeRoot typeRoot = type.getTypeRoot();
        if (typeRoot == DataTypeRoot.INTEGER) {
            return 4;
        } else if (typeRoot == DataTypeRoot.BIGINT) {
            return 8;
        } else if (typeRoot == DataTypeRoot.STRING) {
            if (obj instanceof BinaryString) {
                return ((BinaryString) obj).getSizeInBytes();
            } else if (obj instanceof byte[]) {
                return ((byte[]) obj).length;
            } else {
                LOG.warn("Unexpected object type for STRING field: {}", obj.getClass().getName());
                return String.valueOf(obj).getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
            }
        } else {
            throw new UnsupportedOperationException("Unsupported type: " + typeRoot);
        }
    }

    @Override
    public void close() throws Exception {
        closing = true;
        executor.shutdown();
        consumerTask.get();
        logScanner.close();

        IOUtils.closeQuietly(table);

        try {
            if (connection != null) {
                connection.close();
            }
        } catch (Exception e) {
            LOG.warn("Exception occurs while closing Fluss Connection.", e);
        }
        connection = null;
    }
}
