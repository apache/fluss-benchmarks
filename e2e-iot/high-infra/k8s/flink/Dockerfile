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

# Dockerfile for Fluss Flink Demo Job
# Builds the JAR and includes it in Flink image for local:// submission
#
# Build context: high-infra/k8s/flink (paths below are relative to that directory)

# Stage 1: Build the JAR using Maven
FROM --platform=linux/amd64 maven:3.9-eclipse-temurin-17 AS builder

ARG FLUSS_VERSION=0.9.0-incubating

WORKDIR /build

COPY ../../../fluss_flink_realtime/pom.xml .
COPY ../../../fluss_flink_realtime/src ./src

RUN mvn clean package -DskipTests -Dfluss.version="${FLUSS_VERSION}" -f pom.xml

# Stage 2: Create runtime image with Flink
FROM --platform=linux/amd64 apache/flink:1.20.3-scala_2.12-java17

RUN mkdir -p /opt/flink/plugins/metrics-prometheus && \
    if [ ! -f /opt/flink/plugins/metrics-prometheus/flink-metrics-prometheus-1.20.3.jar ]; then \
        curl -L https://repo1.maven.org/maven2/org/apache/flink/flink-metrics-prometheus/1.20.3/flink-metrics-prometheus-1.20.3.jar \
            -o /opt/flink/plugins/metrics-prometheus/flink-metrics-prometheus-1.20.3.jar && \
        chmod 644 /opt/flink/plugins/metrics-prometheus/flink-metrics-prometheus-1.20.3.jar; \
    fi

WORKDIR /opt/flink/usrlib

COPY --from=builder /build/target/fluss-flink-realtime-demo.jar /opt/flink/usrlib/fluss-flink-realtime-demo.jar

RUN ls -lh /opt/flink/usrlib/fluss-flink-realtime-demo.jar

LABEL maintainer="Fluss Team"
LABEL description="Fluss Flink Realtime Demo - JAR embedded for local:// submission"
LABEL version="0.1.0"
LABEL flink.version="1.20.3"
