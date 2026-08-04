#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

FROM eclipse-temurin:17-jre

# Create Flink directory structure to match Flink image layout
RUN mkdir -p /opt/flink/usrlib /opt/flink/lib /opt/flink/bin

WORKDIR /opt/flink/usrlib

# Install bash, curl, and getent for hostname resolution and Kubernetes API access
# Retry apt-get update in case of transient mirror sync issues
RUN apt-get update || (sleep 5 && apt-get update) && \
    apt-get install -y bash curl netbase && \
    rm -rf /var/lib/apt/lists/*

# Copy the demo JAR to match Flink image structure
COPY target/fluss-flink-realtime-demo.jar /opt/flink/usrlib/fluss-flink-realtime-demo.jar

# Copy entrypoint script
COPY entrypoint.sh /opt/flink/bin/entrypoint.sh
RUN chmod +x /opt/flink/bin/entrypoint.sh

# Use entrypoint script
ENTRYPOINT ["/opt/flink/bin/entrypoint.sh"]

