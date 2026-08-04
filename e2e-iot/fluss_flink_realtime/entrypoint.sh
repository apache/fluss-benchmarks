#!/bin/bash
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
# Don't use set -euo pipefail as it might cause silent failures
# set -euo pipefail

# Entrypoint script to ensure IPv4 preference and start Java application
# Write to both stderr and a log file to ensure we see output
echo "[entrypoint] Script started" >&2
echo "[entrypoint] Starting with args: $@" >&2
echo "[entrypoint] Starting with args: $@" >> /tmp/entrypoint.log 2>&1 || true

# Add coordinator hostname to /etc/hosts with IPv4 IP to force IPv4 resolution
# This prevents Netty from resolving the hostname to IPv6
COORD_HOST="coordinator-server-0.coordinator-server-hs.default.svc.cluster.local"
COORD_IP=$(getent ahostsv4 coordinator-server-hs.default.svc.cluster.local 2>/dev/null | awk '{print $1}' | head -1)
if [ -n "$COORD_IP" ]; then
    echo "[entrypoint] Adding $COORD_IP $COORD_HOST to /etc/hosts to force IPv4 resolution" >&2
    echo "$COORD_IP $COORD_HOST" >> /etc/hosts
fi

# Force IPv4 stack via environment variable (applies to all Java processes)
# Also include --add-opens for Apache Arrow compatibility and Flink Kryo serialization
# Use -Djava.net.preferIPv4Stack=true to disable IPv6 completely
# Use -Djava.net.preferIPv4Addresses=true to prefer IPv4 when both are available
export JAVA_TOOL_OPTIONS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.time=ALL-UNNAMED -Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true ${JAVA_TOOL_OPTIONS:-}"

# Resolve hostnames in bootstrap arguments to IPv4 addresses
# Replace hostname with IP to prevent Netty from doing DNS resolution that might return IPv6
# For Kubernetes services, try to get the IP from the Kubernetes API first, then fall back to DNS
RESOLVED_ARGS=()
i=0
ORIG_ARGS=("$@")
while [ $i -lt ${#ORIG_ARGS[@]} ]; do
  arg="${ORIG_ARGS[$i]}"
  # Check if this is --bootstrap argument
  if [ "$arg" = "--bootstrap" ] && [ $((i + 1)) -lt ${#ORIG_ARGS[@]} ]; then
    RESOLVED_ARGS+=("$arg")
    HOSTPORT="${ORIG_ARGS[$((i + 1))]}"
    HOST=$(echo "$HOSTPORT" | cut -d: -f1)
    PORT=$(echo "$HOSTPORT" | cut -d: -f2)
    
    # Try multiple methods to get IPv4 address
    IPV4=""
    
    # Method 1: Try to get from Kubernetes API (if service account has permissions)
    if [[ "$HOST" == *".svc.cluster.local" ]] || [[ "$HOST" == *".svc" ]]; then
      # Extract service name and namespace from FQDN
      # Format: <service-name>.<namespace>.svc.cluster.local or <service-name>.<namespace>.svc
      if [[ "$HOST" == *".svc.cluster.local" ]]; then
        # Remove .svc.cluster.local suffix
        HOST_PART=$(echo "$HOST" | sed 's/\.svc\.cluster\.local$//')
      else
        # Remove .svc suffix
        HOST_PART=$(echo "$HOST" | sed 's/\.svc$//')
      fi
      # Split into service name and namespace
      SERVICE_NAME=$(echo "$HOST_PART" | cut -d'.' -f1)
      NAMESPACE=$(echo "$HOST_PART" | cut -d'.' -f2-)
      if [ -z "$NAMESPACE" ] || [ "$NAMESPACE" = "$SERVICE_NAME" ]; then
        NAMESPACE="default"
      fi
      
      # Try to get endpoint IPs from Kubernetes API
      if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] && [ -n "${KUBERNETES_SERVICE_PORT:-}" ]; then
        TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
          # Query endpoints API to get pod IPs
          ENDPOINT_IP=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
            "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/api/v1/namespaces/${NAMESPACE}/endpoints/${SERVICE_NAME}" \
            2>/dev/null | grep -oE '"ip":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4)
          if [ -n "$ENDPOINT_IP" ]; then
            IPV4="$ENDPOINT_IP"
            echo "[entrypoint] Resolved $HOST to IPv4 via Kubernetes API: $IPV4" >&2
          fi
        fi
      fi
    fi
    
    # Method 2: Fall back to DNS resolution (IPv4 only)
    if [ -z "$IPV4" ]; then
      # Use getent with ahostsv4 to force IPv4 only
      IPV4=$(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1}' | head -1)
      if [ -n "$IPV4" ]; then
        echo "[entrypoint] Resolved $HOST to IPv4 via DNS: $IPV4" >&2
      fi
    fi
    
    # Use resolved IP or fall back to original hostname
    if [ -n "$IPV4" ] && [ -n "$PORT" ]; then
      echo "[entrypoint] Using $IPV4:$PORT instead of $HOSTPORT" >&2
      RESOLVED_ARGS+=("$IPV4:$PORT")
    else
      echo "[entrypoint] Warning: Could not resolve $HOST to IPv4, using original: $HOSTPORT" >&2
      RESOLVED_ARGS+=("$HOSTPORT")
    fi
    i=$((i + 2))
  else
    RESOLVED_ARGS+=("$arg")
    i=$((i + 1))
  fi
done

# Execute Java with resolved arguments (IP addresses instead of hostnames)
# Also add IPv4 system properties and --add-opens flags directly to the java command
# -Djava.net.preferIPv4Stack=true: Disables IPv6 support completely, forces IPv4-only
# -Djava.net.preferIPv4Addresses=true: When both IPv4 and IPv6 are available, prefer IPv4
# --add-opens: Required for Flink Kryo serialization to access internal Java classes (java.nio, java.util, java.time)
echo "[entrypoint] Executing: java --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.time=ALL-UNNAMED -Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true ${RESOLVED_ARGS[*]}" >&2
exec java --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.time=ALL-UNNAMED -Djava.net.preferIPv4Stack=true -Djava.net.preferIPv4Addresses=true "${RESOLVED_ARGS[@]}"

