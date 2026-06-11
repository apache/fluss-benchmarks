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

/** Fluss benchmark config. All Fluss-specific configuration lives here. */
public class FlussConfig {

    /** Fluss coordinator bootstrap servers. */
    public String bootstrapServers;

    /**
     * Schema definition, dash-separated type names. First field MUST be "long" (used for E2E
     * timestamp). Example: "long-int-int-string-string"
     */
    public String schema = "long-int-int-string-string";

    /** Log format: "ARROW" or "INDEXED". */
    public String logFormat = "ARROW";

    /** Arrow compression type: "NONE", "LZ4_FRAME", or "ZSTD". */
    public String arrowCompressionType = "NONE";

    /** Tiered log local segments to retain. -1 means use server default. */
    public int tieredLogLocalSegments = -1;

    /** Writer acknowledgment mode. */
    public String writerAcks = "all";

    /** Whether to enable idempotent writer. Must be true when acks=all. */
    public boolean writerIdempotenceEnabled = true;

    /** Writer batch size (Fluss MemorySize string, e.g. "1mb"). */
    public String writerBatchSize = "1mb";

    /** Writer buffer memory (Fluss MemorySize string, e.g. "32mb"). */
    public String writerBufferMemory = "32mb";

    /** Writer batch timeout in milliseconds. */
    public int writerBatchTimeoutMs = 0;

    /** Number of Netty client threads. */
    public int clientNettyThreads = 1;

    /** Max bytes per fetch (Fluss MemorySize string, e.g. "16mb"). */
    public String fetchMaxBytes = "16mb";

    /** Project fields: "all" or slash-separated indices like "0/2/4". */
    public String projectFields = "all";

    /** Number of remote log segments to prefetch. */
    public int prefetchNum = 2;

    /** Whether to check CRC on log records. */
    public boolean isCheckCrc = false;

    // ---- Consumer scanner tuning (Fluss client.scanner.log.* options) ----

    /** Max records returned per scanner.poll() (Fluss default 500). */
    public int scannerMaxPollRecords = 500;

    /** Max wait time on server holding fetch RPC when bytesReadable < min-bytes (Fluss default 500ms). */
    public int scannerFetchWaitMaxTimeMs = 500;

    /** Per-bucket fetch byte cap (Fluss MemorySize string, default "1mb"). */
    public String scannerFetchMaxBytesForBucket = "1mb";

    /** Min bytes for fetch to return (Fluss MemorySize string, default "1b"). */
    public String scannerFetchMinBytes = "1b";

    /** Security protocol: "PLAINTEXT" or "SASL_PLAINTEXT". */
    public String securityProtocol = "PLAINTEXT";

    /** SASL mechanism: "PLAIN". */
    public String saslMechanism = "PLAIN";

    /** SASL username. */
    public String saslUsername;

    /** SASL password. */
    public String saslPassword;
}
