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

package org.apache.fluss.benchmark.e2eplatformaws.setup;

import org.apache.fluss.client.Connection;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.admin.Admin;
import org.apache.fluss.config.ConfigOptions;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.metadata.DatabaseDescriptor;
import org.apache.fluss.metadata.Schema;
import org.apache.fluss.metadata.TableDescriptor;
import org.apache.fluss.metadata.TablePath;
import org.apache.fluss.types.DataTypes;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Collections;

/**
 * Utility to create a Fluss table with a specific number of buckets.
 * This can be run before the producer starts to ensure the table exists with the correct bucket count.
 */
public final class CreateTableWithBuckets {
    private static final Logger LOG = LoggerFactory.getLogger(CreateTableWithBuckets.class);

    private CreateTableWithBuckets() {}

    public static void main(String[] args) throws Exception {
        if (args.length < 4) {
            System.err.println("Usage: CreateTableWithBuckets <bootstrap> <database> <table> <buckets> [drop-if-exists]");
            System.err.println("  bootstrap: Fluss coordinator address (e.g., localhost:9124)");
            System.err.println("  database: Database name");
            System.err.println("  table: Table name");
            System.err.println("  buckets: Number of buckets (e.g., 48)");
            System.err.println("  drop-if-exists: Optional, set to 'true' to drop table if it exists");
            System.exit(1);
        }

        String bootstrap = args[0];
        String database = args[1];
        String table = args[2];
        int buckets = Integer.parseInt(args[3]);
        boolean dropIfExists = args.length > 4 && "true".equalsIgnoreCase(args[4]);

        Configuration conf = new Configuration();
        conf.set(ConfigOptions.BOOTSTRAP_SERVERS, Collections.singletonList(bootstrap));

        TablePath tablePath = new TablePath(database, table);

        try (Connection connection = ConnectionFactory.createConnection(conf);
                Admin admin = connection.getAdmin()) {

            // Create database if it doesn't exist
            LOG.info("Creating database '{}' if it doesn't exist...", database);
            admin.createDatabase(
                            database,
                            DatabaseDescriptor.builder().comment("IoT demo database").build(),
                            true)
                    .get();
            LOG.info("Database '{}' ready", database);

            // Check if table exists
            boolean tableExists = false;
            try {
                admin.getTableInfo(tablePath).get();
                tableExists = true;
                LOG.info("Table '{}' already exists", tablePath);
            } catch (Exception e) {
                LOG.info("Table '{}' does not exist, will create it", tablePath);
            }

            // Drop table if it exists and dropIfExists is true
            if (tableExists && dropIfExists) {
                LOG.info("Dropping existing table '{}'...", tablePath);
                admin.dropTable(tablePath, true).get();
                LOG.info("Table '{}' dropped", tablePath);
                tableExists = false;
            }

            // Create table if it doesn't exist
            if (!tableExists) {
                LOG.info("Creating table '{}' with {} buckets...", tablePath, buckets);

                // Minimal producer schema stored in Fluss; Flink fills remaining full-schema fields with defaults
                Schema schema = Schema.newBuilder()
                        .primaryKey("sensor_id")  // Primary key (maps from sensorId in AVRO)
                        .column("sensor_id", DataTypes.INT())  // sensorId from AVRO
                        .column("sensor_type", DataTypes.INT())  // sensorType from AVRO (1-8)
                        .column("temperature", DataTypes.DOUBLE())
                        .column("humidity", DataTypes.DOUBLE())
                        .column("pressure", DataTypes.DOUBLE())
                        .column("battery_level", DataTypes.DOUBLE())
                        .column("status", DataTypes.INT())  // 1=online, 2=offline, 3=maintenance, 4=error
                        .column("timestamp", DataTypes.BIGINT())  // timestamp-millis from AVRO
                        .build();

                TableDescriptor descriptor = TableDescriptor.builder()
                        .schema(schema)
                        .comment("Realtime sensor readings - minimal IoT producer schema")
                        .distributedBy(buckets, "sensor_id")
                        .build();

                admin.createTable(tablePath, descriptor, false).get();
                LOG.info("Successfully created table '{}' with {} buckets", tablePath, buckets);
            } else {
                // Verify bucket count
                try {
                    var tableInfo = admin.getTableInfo(tablePath).get();
                    int actualBuckets = tableInfo.getNumBuckets();
                    LOG.info("Table '{}' already exists with {} buckets", tablePath, actualBuckets);
                    if (actualBuckets != buckets) {
                        LOG.warn("WARNING: Table has {} buckets, but requested {} buckets. " +
                                "Set drop-if-exists=true to recreate the table.", actualBuckets, buckets);
                        System.exit(1);
                    } else {
                        LOG.info("Table '{}' has the correct number of buckets ({})", tablePath, buckets);
                    }
                } catch (Exception e) {
                    LOG.error("Failed to verify table bucket count", e);
                    System.exit(1);
                }
            }
        }

        LOG.info("Done!");
    }
}

