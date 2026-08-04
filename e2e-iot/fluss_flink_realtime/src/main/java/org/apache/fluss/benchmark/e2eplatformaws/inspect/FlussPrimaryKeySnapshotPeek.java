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

package org.apache.fluss.benchmark.e2eplatformaws.inspect;

import org.apache.fluss.client.Connection;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.table.Table;
import org.apache.fluss.client.table.scanner.batch.BatchScanner;
import org.apache.fluss.config.ConfigOptions;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.metadata.TableBucket;
import org.apache.fluss.metadata.TableInfo;
import org.apache.fluss.metadata.TablePath;
import org.apache.fluss.row.InternalRow;
import org.apache.fluss.utils.CloseableIterator;

import java.io.IOException;
import java.time.Duration;
import java.util.Collections;

/**
 * Utility to read the current snapshot of a primary key table from Fluss.
 */
public final class FlussPrimaryKeySnapshotPeek {

    private FlussPrimaryKeySnapshotPeek() {}

    public static void main(String[] args) throws Exception {
        if (args.length < 3 || args.length > 4) {
            System.err.println(
                    "Usage: FlussPrimaryKeySnapshotPeek <bootstrap-host:port> <database> <table> [limit]\n"
                            + "Example: FlussPrimaryKeySnapshotPeek localhost:9123 iot sensor_readings 20");
            System.exit(1);
        }

        String bootstrap = args[0];
        String database = args[1];
        String tableName = args[2];
        int limit = args.length == 4 ? Integer.parseInt(args[3]) : 20;

        Configuration conf = new Configuration();
        conf.set(ConfigOptions.BOOTSTRAP_SERVERS, Collections.singletonList(bootstrap));

        try (Connection connection = ConnectionFactory.createConnection(conf);
                Table table = connection.getTable(TablePath.of(database, tableName))) {
            TableInfo tableInfo = table.getTableInfo();

            if (!tableInfo.hasPrimaryKey()) {
                System.err.println("Table is not a primary-key table; snapshot peek is not supported.");
                return;
            }

            if (tableInfo.isPartitioned()) {
                System.err.println("Partitioned primary-key tables are not supported by this helper yet.");
                return;
            }

            long tableId = tableInfo.getTableId();
            int numBuckets = tableInfo.getNumBuckets();
            System.out.printf(
                    "Reading snapshot from %d buckets for table %s.%s (limit=%d)%n",
                    numBuckets, database, tableName, limit);

            int remaining = limit;
            for (int bucket = 0; bucket < numBuckets && remaining > 0; bucket++) {
                TableBucket tableBucket = new TableBucket(tableId, bucket);
                try (BatchScanner scanner =
                        table.newScan().limit(remaining).createBatchScanner(tableBucket)) {
                    remaining = dumpBucket(scanner, bucket, remaining);
                }
            }

            if (remaining == limit) {
                System.out.println("(no rows found)");
            } else if (remaining > 0) {
                System.out.printf("Reached end of table after printing %d rows.%n", limit - remaining);
            }
        }
    }

    private static int dumpBucket(BatchScanner scanner, int bucket, int remaining) throws IOException {
        while (remaining > 0) {
            try (CloseableIterator<InternalRow> rows = scanner.pollBatch(Duration.ofMillis(500))) {
                if (rows == null) {
                    break;
                }
                while (rows.hasNext() && remaining > 0) {
                    InternalRow row = rows.next();
                    System.out.printf("bucket=%d %s%n", bucket, row);
                    remaining--;
                }
            }
        }
        return remaining;
    }
}
