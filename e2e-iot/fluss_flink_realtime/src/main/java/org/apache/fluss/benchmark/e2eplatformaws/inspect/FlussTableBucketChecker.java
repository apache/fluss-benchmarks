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
import org.apache.fluss.client.admin.Admin;
import org.apache.fluss.config.ConfigOptions;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.metadata.TablePath;

import java.util.Collections;

/**
 * Simple CLI utility to check the number of buckets in a Fluss table.
 * Uses Fluss Admin API to query table metadata directly.
 */
public final class FlussTableBucketChecker {

    private FlussTableBucketChecker() {}

    private static final int DEFAULT_EXPECTED_BUCKETS = 128;

    public static void main(String[] args) throws Exception {
        if (args.length < 3 || args.length > 4) {
            System.err.println(
                    "Usage: FlussTableBucketChecker <bootstrap-host:port> <database> <table> [expected-buckets]");
            System.err.println(
                    "Example: FlussTableBucketChecker localhost:9124 iot sensor_readings 128");
            System.exit(1);
        }

        String bootstrap = args[0];
        String database = args[1];
        String table = args[2];
        int expectedBuckets = DEFAULT_EXPECTED_BUCKETS;
        if (args.length == 4) {
            try {
                expectedBuckets = Integer.parseInt(args[3]);
            } catch (NumberFormatException e) {
                System.err.println("ERROR: expected-buckets must be an integer, got: " + args[3]);
                System.exit(1);
            }
            if (expectedBuckets <= 0) {
                System.err.println("ERROR: expected-buckets must be positive, got: " + expectedBuckets);
                System.exit(1);
            }
        }

        Configuration conf = new Configuration();
        conf.set(ConfigOptions.BOOTSTRAP_SERVERS, Collections.singletonList(bootstrap));

        TablePath tablePath = TablePath.of(database, table);

        try (Connection connection = ConnectionFactory.createConnection(conf);
                Admin admin = connection.getAdmin()) {
            
            // Check if table exists
            boolean tableExists = admin.tableExists(tablePath).get();
            if (!tableExists) {
                System.err.println("ERROR: Table '" + tablePath + "' does not exist");
                System.exit(1);
            }

            // Get table info and bucket count
            var tableInfo = admin.getTableInfo(tablePath).get();
            int bucketCount = tableInfo.getNumBuckets();

            // Output result
            System.out.println("========================================");
            System.out.println("Fluss Table Bucket Count Check");
            System.out.println("========================================");
            System.out.println("Bootstrap:  " + bootstrap);
            System.out.println("Database:   " + database);
            System.out.println("Table:      " + table);
            System.out.println("Buckets:    " + bucketCount);
            System.out.println("Expected:   " + expectedBuckets);
            System.out.println("========================================");

            if (bucketCount == expectedBuckets) {
                System.out.println("✓ Table has " + expectedBuckets + " buckets as expected");
                System.exit(0);
            } else {
                System.out.println(
                        "⚠ WARNING: Table has "
                                + bucketCount
                                + " buckets, expected "
                                + expectedBuckets);
                System.exit(1);
            }
        } catch (Exception e) {
            System.err.println("ERROR: Failed to check table bucket count");
            System.err.println("Error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }
}


