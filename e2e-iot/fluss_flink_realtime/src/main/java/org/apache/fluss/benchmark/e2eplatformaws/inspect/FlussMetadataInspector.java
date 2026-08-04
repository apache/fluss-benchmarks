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

import java.util.Collections;
import java.util.List;

/** Simple CLI to inspect Fluss metadata (databases and tables). */
public final class FlussMetadataInspector {

    private FlussMetadataInspector() {}

    public static void main(String[] args) throws Exception {
        if (args.length == 0 || args.length > 2) {
            System.err.println("Usage: FlussMetadataInspector <bootstrap-host:port> [database]");
            System.exit(1);
        }

        String bootstrap = args[0];
        String databaseFilter = args.length == 2 ? args[1] : null;

        Configuration conf = new Configuration();
        conf.set(ConfigOptions.BOOTSTRAP_SERVERS, Collections.singletonList(bootstrap));

        try (Connection connection = ConnectionFactory.createConnection(conf);
                Admin admin = connection.getAdmin()) {
            List<String> databases = admin.listDatabases().get();
            System.out.println("Databases:");
            databases.forEach(db -> System.out.println("  - " + db));

            if (!databases.isEmpty()) {
                if (databaseFilter != null) {
                    printTables(admin, databaseFilter);
                } else {
                    for (String db : databases) {
                        printTables(admin, db);
                    }
                }
            }
        }
    }

    private static void printTables(Admin admin, String database) {
        try {
            List<String> tables = admin.listTables(database).get();
            System.out.println("Tables in database '" + database + "':");
            if (tables.isEmpty()) {
                System.out.println("  (none)");
            } else {
                tables.forEach(table -> System.out.println("  - " + table));
            }
        } catch (Exception e) {
            System.err.println(
                    "Failed to list tables for database '" + database + "': " + e.getMessage());
        }
    }
}
