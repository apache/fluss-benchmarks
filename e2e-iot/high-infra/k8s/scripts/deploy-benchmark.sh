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
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-fluss}"
DEMO_IMAGE_REPO="${DEMO_IMAGE_REPO:-}"
DEMO_IMAGE_TAG="${DEMO_IMAGE_TAG:-latest}"
FLUSS_IMAGE_REPO="${FLUSS_IMAGE_REPO:-apache/fluss:0.9.0-incubating}"
CLUSTER_NAME="${CLUSTER_NAME:-fluss-eks-cluster}"
REGION="${REGION:-us-west-2}"

# Export variables for child scripts
export NAMESPACE DEMO_IMAGE_REPO DEMO_IMAGE_TAG FLUSS_IMAGE_REPO CLUSTER_NAME REGION

# Script definitions (using functions for bash 3.2 compatibility)
get_step_script() {
    case $1 in
        0) echo "00-deploy-infra.sh" ;;
        1) echo "01-update-kubeconfig.sh" ;;
        2) echo "02-setup-storage.sh" ;;
        3) echo "03-deploy-components.sh" ;;
        4) echo "04-verify-storage.sh" ;;
        5) echo "05-deploy-producer.sh" ;;
        6) echo "06-submit-flink-job.sh" ;;
        7) echo "07-deploy-dashboard.sh" ;;
        8) echo "08-verify-deployment.sh" ;;
        *) echo "" ;;
    esac
}

get_step_description() {
    case $1 in
        0) echo "Deploy infrastructure with Terraform" ;;
        1) echo "Update kubeconfig" ;;
        2) echo "Setup local NVMe storage" ;;
        3) echo "Deploy all components" ;;
        4) echo "Verify NVMe storage" ;;
        5) echo "Deploy multi-instance producer" ;;
        6) echo "Submit Flink aggregator job" ;;
        7) echo "Deploy Grafana dashboard" ;;
        8) echo "Verify deployment" ;;
        *) echo "" ;;
    esac
}

# List of all step numbers
ALL_STEPS="0 1 2 3 4 5 6 7 8"

# Function to run a step
run_step() {
    local step_num=$1
    local script_name=$2
    local step_desc=$3
    
    local script_path="${SCRIPT_DIR}/${script_name}"
    
    if [ ! -f "${script_path}" ]; then
        echo "ERROR: Script not found: ${script_path}"
        return 1
    fi
    
    # Make script executable
    chmod +x "${script_path}"
    
    echo ""
    echo "=========================================="
    echo "Running Step ${step_num}: ${step_desc}"
    echo "=========================================="
    echo ""
    
    # Run the script and capture exit code
    if "${script_path}"; then
        echo ""
        echo "✓ Step ${step_num} completed successfully: ${step_desc}"
        return 0
    else
        local exit_code=$?
        echo ""
        echo "✗ Step ${step_num} FAILED: ${step_desc}"
        echo "  Exit code: ${exit_code}"
        return ${exit_code}
    fi
}

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy the 2-million-messages-per-second benchmark infrastructure and components.

OPTIONS:
    --skip-step N          Skip step N (can be used multiple times)
    --start-from-step N    Start from step N (skip previous steps)
    --only-step N          Run only step N
    --help                 Show this help message

ENVIRONMENT VARIABLES:
    NAMESPACE              Kubernetes namespace (default: fluss)
    DEMO_IMAGE_REPO        Demo image repository (required for step 5)
    DEMO_IMAGE_TAG         Demo image tag (default: latest)
    FLUSS_IMAGE_REPO       Fluss image repository (default: apache/fluss:0.9.0-incubating)
    CLUSTER_NAME           EKS cluster name (default: fluss-eks-cluster)
    REGION                 AWS region (default: us-west-2)

STEPS:
    0. Deploy infrastructure with Terraform
    1. Update kubeconfig
    2. Setup local NVMe storage
    3. Deploy all components (ZooKeeper, Fluss, Flink, Monitoring)
    4. Verify NVMe storage
    5. Deploy multi-instance producer
    6. Submit Flink aggregator job
    7. Deploy Grafana dashboard
    8. Verify deployment

EXAMPLE:
    # Run all steps
    ./deploy-benchmark.sh

    # Skip step 4 (storage verification)
    ./deploy-benchmark.sh --skip-step 4

    # Start from step 5 (producer deployment)
    ./deploy-benchmark.sh --start-from-step 5

    # Run only step 3
    ./deploy-benchmark.sh --only-step 3

    # With custom image
    DEMO_IMAGE_REPO=my-repo/fluss-demo ./deploy-benchmark.sh
EOF
}

# Parse command line arguments
SKIP_STEPS=()
START_FROM_STEP=""
ONLY_STEP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-step)
            SKIP_STEPS+=("$2")
            shift 2
            ;;
        --start-from-step)
            START_FROM_STEP="$2"
            shift 2
            ;;
        --only-step)
            ONLY_STEP="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required environment variables for specific steps
if [ -z "${DEMO_IMAGE_REPO}" ] && [ -z "${ONLY_STEP}" ]; then
    echo "WARNING: DEMO_IMAGE_REPO is not set. Step 5 (producer deployment) will fail."
    echo "Set it with: export DEMO_IMAGE_REPO=your-repo/fluss-demo"
    echo ""
fi

# Main execution
main() {
    echo "=========================================="
    echo "2 Million Messages Per Second Benchmark"
    echo "Deployment Master Script"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Namespace: ${NAMESPACE}"
    echo "  Demo Image: ${DEMO_IMAGE_REPO}:${DEMO_IMAGE_TAG}"
    echo "  Fluss Image: ${FLUSS_IMAGE_REPO}"
    echo "  Cluster: ${CLUSTER_NAME}"
    echo "  Region: ${REGION}"
    echo ""
    
    # Determine which steps to run
    local steps_to_run=""
    
    if [ -n "${ONLY_STEP}" ]; then
        # Run only specified step
        if [ -z "$(get_step_script ${ONLY_STEP})" ]; then
            echo "ERROR: Invalid step number: ${ONLY_STEP}"
            echo "Valid steps: ${ALL_STEPS}"
            exit 1
        fi
        steps_to_run="${ONLY_STEP}"
    elif [ -n "${START_FROM_STEP}" ]; then
        # Start from specified step
        for step in ${ALL_STEPS}; do
            if [ "${step}" -ge "${START_FROM_STEP}" ]; then
                steps_to_run="${steps_to_run} ${step}"
            fi
        done
        # Sort steps numerically (portable across all Unix systems)
        steps_to_run=$(printf '%s\n' ${steps_to_run} | sort -n | tr '\n' ' ')
    else
        # Run all steps
        steps_to_run="${ALL_STEPS}"
    fi
    
    # Filter out skipped steps
    local filtered_steps=""
    for step in ${steps_to_run}; do
        local skip=false
        if [ ${#SKIP_STEPS[@]} -gt 0 ]; then
            for skip_step in "${SKIP_STEPS[@]}"; do
                if [ "${step}" = "${skip_step}" ]; then
                    skip=true
                    break
                fi
            done
        fi
        if [ "${skip}" = false ]; then
            filtered_steps="${filtered_steps} ${step}"
        fi
    done
    
    filtered_steps=$(echo ${filtered_steps} | sed 's/^ *//;s/ *$//')
    
    if [ -z "${filtered_steps}" ]; then
        echo "ERROR: No steps to run after filtering"
        exit 1
    fi
    
    echo "Steps to execute: ${filtered_steps}"
    echo ""
    
    # Run each step
    local failed_steps=""
    for step in ${filtered_steps}; do
        local script_name=$(get_step_script ${step})
        local step_desc=$(get_step_description ${step})
        
        if ! run_step "${step}" "${script_name}" "${step_desc}"; then
            failed_steps="${failed_steps} ${step}: ${step_desc}"
            echo ""
            echo "=========================================="
            echo "DEPLOYMENT FAILED"
            echo "=========================================="
            echo ""
            echo "Failed at Step ${step}: ${step_desc}"
            echo ""
            if [ -n "${failed_steps}" ]; then
                echo "Failed steps:"
                for failed in ${failed_steps}; do
                    echo "  - Step ${failed}"
                done
            fi
            echo ""
            echo "To retry from this step:"
            echo "  ./deploy-benchmark.sh --start-from-step ${step}"
            echo ""
            echo "To retry only this step:"
            echo "  ./deploy-benchmark.sh --only-step ${step}"
            echo ""
            exit 1
        fi
    done
    
    # Success summary
    echo ""
    echo "=========================================="
    echo "DEPLOYMENT COMPLETED SUCCESSFULLY"
    echo "=========================================="
    echo ""
    echo "All steps completed:"
    for step in ${filtered_steps}; do
        local step_desc=$(get_step_description ${step})
        echo "  ✓ Step ${step}: ${step_desc}"
    done
    echo ""
    echo "Access services:"
    echo "  Flink Web UI:"
    echo "    kubectl port-forward -n ${NAMESPACE} svc/flink-jobmanager 8081:8081"
    echo "    Then open: http://localhost:8081"
    echo ""
    echo "  Grafana:"
    echo "    kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "    Then open: http://localhost:3000"
    echo "    Username: admin"
    echo "    Password: admin123"
    echo ""
    echo "  Prometheus:"
    echo "    kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
    echo "    Then open: http://localhost:9090"
    echo ""
    echo "Check status:"
    echo "  kubectl get pods -n ${NAMESPACE}"
    echo "  kubectl get pods -n monitoring"
    echo ""
}

# Run main function
main

