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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Calculate base directory (e2e-platform-aws) - go up from scripts/k8s/high-infra
BASE_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "=== Step 9: View End-to-End Metrics ==="
echo ""

# Change to base directory
cd "${BASE_DIR}"

# Check if port-forward script exists
if [ ! -f "./port-forward-grafana.sh" ]; then
    echo "ERROR: Port-forward script not found"
    echo "Expected location: ./port-forward-grafana.sh in e2e-platform-aws directory"
    echo "Current directory: $(pwd)"
    exit 1
fi

# Check if script is executable
if [ ! -x "./port-forward-grafana.sh" ]; then
    echo "Making port-forward script executable..."
    chmod +x "./port-forward-grafana.sh"
fi

echo "Found port-forward script in: $(pwd)"
echo ""
echo "Starting Grafana port-forward to view end-to-end metrics..."
echo ""

# Execute the port-forward script
exec ./port-forward-grafana.sh

