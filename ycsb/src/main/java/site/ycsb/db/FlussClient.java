/**
 * Copyright (c) 2024 YCSB contributors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you
 * may not use this file except in compliance with the License. You
 * may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * permissions and limitations under the License. See accompanying
 * LICENSE file.
 */

package site.ycsb.db;

import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;
import site.ycsb.StringByteIterator;

import org.apache.fluss.client.Connection;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.admin.Admin;
import org.apache.fluss.client.lookup.Lookuper;
import org.apache.fluss.client.table.Table;
import org.apache.fluss.client.table.scanner.batch.BatchScanner;
import org.apache.fluss.client.table.writer.UpsertWriter;
import org.apache.fluss.config.Configuration;
import org.apache.fluss.metadata.DatabaseDescriptor;
import org.apache.fluss.metadata.Schema;
import org.apache.fluss.metadata.TableBucket;
import org.apache.fluss.metadata.TableDescriptor;
import org.apache.fluss.metadata.TablePath;
import org.apache.fluss.row.BinaryString;
import org.apache.fluss.row.GenericRow;
import org.apache.fluss.row.InternalRow;
import org.apache.fluss.types.DataTypes;
import org.apache.fluss.utils.CloseableIterator;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.Vector;


/**
 * YCSB binding for <a href="https://github.com/apache/fluss">Apache Fluss</a>.
 *
 * <p>This binding uses Fluss Primary Key Tables. Each YCSB record maps to a row
 * with a string primary key column and N string value columns.
 */
public class FlussClient extends DB {

  public static final String BOOTSTRAP_SERVERS_PROPERTY = "fluss.bootstrap.servers";
  public static final String DATABASE_PROPERTY = "fluss.database";
  public static final String DATABASE_DEFAULT = "ycsb";
  public static final String BUCKET_NUM_PROPERTY = "fluss.bucket.num";
  public static final String BUCKET_NUM_DEFAULT = "30";
  public static final String SECURITY_PROTOCOL_PROPERTY = "fluss.security.protocol";
  public static final String SASL_MECHANISM_PROPERTY = "fluss.security.sasl.mechanism";
  public static final String SASL_USERNAME_PROPERTY = "fluss.security.sasl.username";
  public static final String SASL_PASSWORD_PROPERTY = "fluss.security.sasl.password";
  public static final String FIELD_COUNT_PROPERTY = "fieldcount";
  public static final String FIELD_COUNT_DEFAULT = "10";

  private static final String PRIMARY_KEY_COLUMN = "ycsb_key";
  private static final String FIELD_PREFIX = "field";
  private static final Duration POLL_TIMEOUT = Duration.ofSeconds(10);

  private static final Object INIT_LOCK = new Object();
  private static volatile boolean tableCreated = false;

  private Connection connection;
  private Table table;
  private Lookuper lookuper;
  private UpsertWriter upsertWriter;
  private int fieldCount;
  private long tableId;
  private String databaseName;

  @Override
  public void init() throws DBException {
    Properties props = getProperties();

    String bootstrapServers = props.getProperty(BOOTSTRAP_SERVERS_PROPERTY);
    if (bootstrapServers == null || bootstrapServers.isEmpty()) {
      throw new DBException("Required property '" + BOOTSTRAP_SERVERS_PROPERTY + "' is missing.");
    }

    databaseName = props.getProperty(DATABASE_PROPERTY, DATABASE_DEFAULT);
    fieldCount = Integer.parseInt(props.getProperty(FIELD_COUNT_PROPERTY, FIELD_COUNT_DEFAULT));

    Configuration conf = new Configuration();
    conf.setString("bootstrap.servers", bootstrapServers);
    conf.setString("client.lookup.max-batch-size", "1");

    String securityProtocol = props.getProperty(SECURITY_PROTOCOL_PROPERTY);
    if (securityProtocol != null) {
      conf.setString("client.security.protocol", securityProtocol);
    }
    String saslMechanism = props.getProperty(SASL_MECHANISM_PROPERTY);
    if (saslMechanism != null) {
      conf.setString("client.security.sasl.mechanism", saslMechanism);
    }
    String saslUsername = props.getProperty(SASL_USERNAME_PROPERTY);
    if (saslUsername != null) {
      conf.setString("client.security.sasl.username", saslUsername);
    }
    String saslPassword = props.getProperty(SASL_PASSWORD_PROPERTY);
    if (saslPassword != null) {
      conf.setString("client.security.sasl.password", saslPassword);
    }

    try {
      connection = ConnectionFactory.createConnection(conf);
      synchronized (INIT_LOCK) {
        if (!tableCreated) {
          ensureTableExists(props);
          tableCreated = true;
        }
      }

      String tableName = props.getProperty("table", "usertable");
      TablePath tablePath = TablePath.of(databaseName, tableName);
      table = connection.getTable(tablePath);
      tableId = table.getTableInfo().getTableId();
      lookuper = table.newLookup().createLookuper();
      upsertWriter = table.newUpsert().createWriter();
    } catch (Exception e) {
      throw new DBException("Failed to initialize Fluss connection.", e);
    }
  }

  private void ensureTableExists(Properties props) throws Exception {
    String tableName = props.getProperty("table", "usertable");
    TablePath tablePath = TablePath.of(databaseName, tableName);

    try (Admin admin = connection.getAdmin()) {
      admin.createDatabase(databaseName, DatabaseDescriptor.EMPTY, true).get();

      Schema.Builder schemaBuilder = Schema.newBuilder();
      schemaBuilder.column(PRIMARY_KEY_COLUMN, DataTypes.STRING());
      for (int i = 0; i < fieldCount; i++) {
        schemaBuilder.column(FIELD_PREFIX + i, DataTypes.STRING());
      }
      schemaBuilder.primaryKey(PRIMARY_KEY_COLUMN);

      int bucketNum = Integer.parseInt(
          props.getProperty(BUCKET_NUM_PROPERTY, BUCKET_NUM_DEFAULT));

      TableDescriptor tableDescriptor = TableDescriptor.builder()
          .schema(schemaBuilder.build())
          .distributedBy(bucketNum)
          .build();

      admin.createTable(tablePath, tableDescriptor, true).get();
    }
  }

  @Override
  public void cleanup() throws DBException {
    try {
      if (upsertWriter != null) {
        upsertWriter.flush();
      }
      if (table != null) {
        table.close();
      }
      if (connection != null) {
        connection.close();
      }
    } catch (Exception e) {
      throw new DBException("Failed to close Fluss resources.", e);
    }
  }

  @Override
  public Status read(String tableName, String key, Set<String> fields,
      Map<String, ByteIterator> result) {
    try {
      GenericRow keyRow = GenericRow.of(BinaryString.fromString(key));
      lookuper.lookup(keyRow).get();
      return Status.OK;
    } catch (Exception e) {
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  @Override
  public Status scan(String tableName, String startkey, int recordcount,
      Set<String> fields, Vector<HashMap<String, ByteIterator>> result) {
    try {
      TableBucket bucket = new TableBucket(tableId, 0);
      BatchScanner scanner = table.newScan().limit(recordcount).createBatchScanner(bucket);
      try {
        CloseableIterator<InternalRow> batch;
        while ((batch = scanner.pollBatch(POLL_TIMEOUT)) != null) {
          while (batch.hasNext()) {
            InternalRow row = batch.next();
            HashMap<String, ByteIterator> rowResult = new HashMap<>();
            if (fields == null) {
              for (int i = 0; i < fieldCount; i++) {
                if (!row.isNullAt(i + 1)) {
                  BinaryString value = row.getString(i + 1);
                  rowResult.put(FIELD_PREFIX + i, new StringByteIterator(value.toString()));
                }
              }
            } else {
              for (String field : fields) {
                int index = fieldIndex(field);
                if (index >= 0 && !row.isNullAt(index + 1)) {
                  BinaryString value = row.getString(index + 1);
                  rowResult.put(field, new StringByteIterator(value.toString()));
                }
              }
            }
            result.add(rowResult);
          }
          batch.close();
        }
      } finally {
        scanner.close();
      }
      return Status.OK;
    } catch (Exception e) {
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  @Override
  public Status update(String tableName, String key, Map<String, ByteIterator> values) {
    return insert(tableName, key, values);
  }

  @Override
  public Status insert(String tableName, String key, Map<String, ByteIterator> values) {
    try {
      GenericRow row = new GenericRow(fieldCount + 1);
      row.setField(0, BinaryString.fromString(key));
      for (Map.Entry<String, ByteIterator> entry : values.entrySet()) {
        int index = fieldIndex(entry.getKey());
        if (index >= 0) {
          row.setField(index + 1, BinaryString.fromString(entry.getValue().toString()));
        }
      }
      upsertWriter.upsert(row);
      return Status.OK;
    } catch (Exception e) {
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  @Override
  public Status delete(String tableName, String key) {
    try {
      GenericRow keyRow = new GenericRow(fieldCount + 1);
      keyRow.setField(0, BinaryString.fromString(key));
      upsertWriter.delete(keyRow);
      return Status.OK;
    } catch (Exception e) {
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  private int fieldIndex(String fieldName) {
    if (fieldName.startsWith(FIELD_PREFIX)) {
      try {
        return Integer.parseInt(fieldName.substring(FIELD_PREFIX.length()));
      } catch (NumberFormatException e) {
        return -1;
      }
    }
    return -1;
  }
}
