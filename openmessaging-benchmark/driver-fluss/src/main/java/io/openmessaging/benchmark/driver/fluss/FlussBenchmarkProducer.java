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

import io.openmessaging.benchmark.driver.BenchmarkProducer;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ThreadLocalRandom;
import org.apache.fluss.client.Connection;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.table.Table;
import org.apache.fluss.client.table.writer.AppendResult;
import org.apache.fluss.client.table.writer.AppendWriter;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.metadata.TablePath;
import org.apache.fluss.row.BinaryString;
import org.apache.fluss.row.InternalRow;
import org.apache.fluss.row.indexed.IndexedRow;
import org.apache.fluss.row.indexed.IndexedRowWriter;
import org.apache.fluss.types.DataType;
import org.apache.fluss.types.RowType;
import org.apache.fluss.utils.IOUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Fluss benchmark producer with pre-generated row pool to minimize hot-path allocation. */
public class FlussBenchmarkProducer implements BenchmarkProducer {

    private static final Logger LOG = LoggerFactory.getLogger(FlussBenchmarkProducer.class);
    private static final int ROW_POOL_SIZE = 1000;

    private final AppendWriter appendWriter;
    private final String[] schemaTypes;
    private final DataType[] fieldTypes;
    private Connection connection;
    private final Table table;

    private final int fixedBytes;
    private final int stringCount;

    /** Pre-generated row pool: each entry holds a reusable IndexedRow. */
    private IndexedRow[] rowPool;

    /** Offset of field 0 (timestamp) within each row's MemorySegment. */
    private int timestampFieldOffset;

    /** Round-robin index into the row pool. */
    private int poolIndex = 0;

    /** Whether the pool has been initialized (deferred until first real message). */
    private volatile boolean poolInitialized = false;

    public FlussBenchmarkProducer(
            Configuration conf, String topic, String[] schemaTypes, RowType rowType) {
        this.schemaTypes = schemaTypes.clone();
        this.connection = ConnectionFactory.createConnection(conf);
        this.table = connection.getTable(new TablePath(DEFAULT_DATABASE_NAME, topic));
        this.appendWriter = table.newAppend().createWriter();
        this.fieldTypes = rowType.getChildren().toArray(new DataType[0]);

        int fixed = 0;
        int strings = 0;
        for (String type : schemaTypes) {
            switch (type) {
                case "int":
                    fixed += 4;
                    break;
                case "long":
                    fixed += 8;
                    break;
                case "string":
                    strings++;
                    break;
                default:
                    throw new IllegalArgumentException("Unsupported schema type: " + type);
            }
        }
        this.fixedBytes = fixed;
        this.stringCount = strings;
    }

    @Override
    public CompletableFuture<Void> sendAsync(Optional<String> key, byte[] payload) {
        int targetSize = payload.length;

        if (targetSize < fixedBytes) {
            InternalRow row = buildSingleRow(0);
            CompletableFuture<AppendResult> result = appendWriter.append(row);
            return result.thenApply(appendResult -> null);
        }

        if (!poolInitialized) {
            synchronized (this) {
                if (!poolInitialized) {
                    initializePool(targetSize);
                    poolInitialized = true;
                }
            }
        }

        IndexedRow row = rowPool[poolIndex];
        poolIndex = (poolIndex + 1) % ROW_POOL_SIZE;

        row.getSegment().putLong(timestampFieldOffset, System.currentTimeMillis());

        CompletableFuture<AppendResult> result = appendWriter.append(row);
        return result.thenApply(appendResult -> null);
    }

    @Override
    public void close() throws Exception {
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

    private void initializePool(int targetSize) {
        int perStringByteSize = 0;
        if (stringCount > 0) {
            perStringByteSize = (targetSize - fixedBytes) / stringCount;
        }
        LOG.info(
                "Initializing row pool: poolSize={}, targetSize={}, fixedBytes={},"
                        + " stringCount={}, perStringByteSize={}",
                ROW_POOL_SIZE,
                targetSize,
                fixedBytes,
                stringCount,
                perStringByteSize);

        rowPool = new IndexedRow[ROW_POOL_SIZE];
        for (int i = 0; i < ROW_POOL_SIZE; i++) {
            rowPool[i] = buildSingleRow(perStringByteSize);
        }

        // Compute the fixed offset for field 0 (timestamp).
        // IndexedRow layout: nullBitSet + variableColumnLengthList + field values
        // Field 0 starts right after the header.
        int nullBitsSize = IndexedRow.calculateBitSetWidthInBytes(schemaTypes.length);
        int variableLengthListSize = IndexedRow.calculateVariableColumnLengthListSize(fieldTypes);
        this.timestampFieldOffset = nullBitsSize + variableLengthListSize;
    }

    private IndexedRow buildSingleRow(int perStringByteSize) {
        IndexedRowWriter rowWriter = new IndexedRowWriter(fieldTypes);
        for (int i = 0; i < schemaTypes.length; i++) {
            switch (schemaTypes[i]) {
                case "long":
                    if (i == 0) {
                        rowWriter.writeLong(System.currentTimeMillis());
                    } else {
                        rowWriter.writeLong(ThreadLocalRandom.current().nextLong());
                    }
                    break;
                case "int":
                    rowWriter.writeInt(ThreadLocalRandom.current().nextInt());
                    break;
                case "string":
                    rowWriter.writeString(randomBinaryString(perStringByteSize));
                    break;
                default:
                    throw new IllegalArgumentException("Unsupported schema type: " + schemaTypes[i]);
            }
        }
        rowWriter.complete();
        IndexedRow row = new IndexedRow(fieldTypes);
        row.pointTo(rowWriter.segment(), 0, rowWriter.position());
        return row;
    }

    private static BinaryString randomBinaryString(int byteSize) {
        if (byteSize <= 0) {
            return BinaryString.EMPTY_UTF8;
        }
        byte[] bytes = new byte[byteSize];
        ThreadLocalRandom.current().nextBytes(bytes);
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) (33 + (bytes[i] & 0x7F) % 94);
        }
        return BinaryString.fromBytes(bytes);
    }
}
