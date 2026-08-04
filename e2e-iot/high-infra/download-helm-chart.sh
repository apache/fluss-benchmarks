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

#!/bin/bash
set -euo pipefail

# Install the Fluss Helm chart with persistence support into helm-charts/fluss/.
# The published chart at downloads.apache.org ignores persistence.enabled; the
# vendored chart under helm-charts/fluss/ includes volumeClaimTemplates.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELM_CHARTS_DIR="${SCRIPT_DIR}/helm-charts"
FLUSS_VERSION="${FLUSS_VERSION:-0.9.0-incubating}"

usage() {
    echo "Usage: $0 [--fluss-version VERSION]"
    echo "  Default version: 0.9.0-incubating (or FLUSS_VERSION env var)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fluss-version)
            if [ $# -lt 2 ]; then
                echo "Error: --fluss-version requires a value"
                usage
                exit 1
            fi
            FLUSS_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

mkdir -p "${HELM_CHARTS_DIR}"

if [ -f "${HELM_CHARTS_DIR}/fluss/Chart.yaml" ]; then
    echo "✓ Fluss Helm chart already present at ${HELM_CHARTS_DIR}/fluss"
    exit 0
fi

echo "ERROR: Fluss Helm chart with persistence support not found at ${HELM_CHARTS_DIR}/fluss"
echo "  The chart is vendored in this repo; ensure helm-charts/fluss/ is present."
exit 1
