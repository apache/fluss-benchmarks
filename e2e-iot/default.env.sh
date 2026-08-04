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

# Usage:
#   source ./default.env.sh --fluss-version VERSION
#
# Example:
#   source ./default.env.sh --fluss-version 0.9.0-incubating

_default_env_fail() {
    echo "Error: $1" >&2
    echo "Usage: source $(basename "${BASH_SOURCE[0]}") --fluss-version VERSION" >&2
    echo "Example: source ./default.env.sh --fluss-version 0.9.0-incubating" >&2
    return 1 2>/dev/null || exit 1
}

_fluss_version_arg=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fluss-version)
            if [ $# -lt 2 ]; then
                _default_env_fail "--fluss-version requires a value"
            fi
            _fluss_version_arg="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: source ./default.env.sh --fluss-version VERSION"
            echo "Example: source ./default.env.sh --fluss-version 0.9.0-incubating"
            return 0 2>/dev/null || exit 0
            ;;
        *)
            _default_env_fail "Unknown argument: $1"
            ;;
    esac
done

if [ -z "${_fluss_version_arg}" ]; then
    _default_env_fail "--fluss-version is required"
fi

export FLUSS_VERSION="${_fluss_version_arg}"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-west-2"
export DEMO_IMAGE_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/fluss-demo"
export DEMO_IMAGE_TAG="latest"
export FLUSS_IMAGE_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/fluss"
export FLUSS_IMAGE_TAG="${FLUSS_VERSION}"
export NAMESPACE="fluss"
export CLUSTER_NAME="fluss-eks-cluster"
export REGION="${AWS_REGION}"
