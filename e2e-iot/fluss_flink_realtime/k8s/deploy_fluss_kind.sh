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

#!/usr/bin/env bash
set -euo pipefail

# Automation script for deploying ZooKeeper + Fluss on a local Kind cluster.
# It mirrors the steps in fluss_kubernetes_local_kind.md.

KIND_NAME=${KIND_NAME:-fluss-kind}
WORKDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIND_CONFIG="${WORKDIR}/kind-cluster-config.yaml"
ZK_MANIFEST="${WORKDIR}/zookeeper-kind.yaml"
FLUSS_VALUES="${WORKDIR}/fluss-values-kind.yaml"
FLUSS_VERSION="${FLUSS_VERSION:-0.9.0-incubating}"
FLUSS_CHART_VERSION="${FLUSS_CHART_VERSION:-${FLUSS_VERSION}}"
FLUSS_IMAGE="${FLUSS_IMAGE:-apache/fluss:${FLUSS_VERSION}}"

cat <<'EOF' >"${KIND_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            max-pods: "150"
    extraPortMappings:
      - containerPort: 30181
        hostPort: 8081
        protocol: TCP
      - containerPort: 30923
        hostPort: 9123
        protocol: TCP
      - containerPort: 30924
        hostPort: 9124
        protocol: TCP
  - role: worker
  - role: worker
EOF

echo "[1/7] Creating Kind cluster '${KIND_NAME}'..."
kind create cluster --name "${KIND_NAME}" --config "${KIND_CONFIG}" >/dev/null

# Wait until all Kind nodes report Ready before moving on.
echo "[2/7] Waiting for Kind nodes to become Ready..."
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
kubectl get nodes

# Optional resource tuning for docker-based Kind nodes (ignore failures on non-docker environments).
for node in "${KIND_NAME}-control-plane" "${KIND_NAME}-worker" "${KIND_NAME}-worker2"; do
  if docker inspect "$node" >/dev/null 2>&1; then
    docker update --cpus 3 --memory 5g --memory-swap 5g "$node" >/dev/null 2>&1 || true
  fi
done

cat <<'EOF' >"${ZK_MANIFEST}"
apiVersion: v1
kind: Service
metadata:
  name: zk-svc
  namespace: default
  labels:
    app: zookeeper
spec:
  selector:
    app: zookeeper
  ports:
    - name: client
      port: 2181
      targetPort: 2181
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: zk
  namespace: default
  labels:
    app: zookeeper
spec:
  serviceName: zk-svc
  replicas: 1
  selector:
    matchLabels:
      app: zookeeper
  template:
    metadata:
      labels:
        app: zookeeper
    spec:
      containers:
        - name: zookeeper
          image: zookeeper:3.9.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: client
              containerPort: 2181
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
EOF

echo "[3/7] Deploying ZooKeeper..."
kubectl apply -f "${ZK_MANIFEST}" >/dev/null
kubectl rollout status statefulset/zk --timeout=180s >/dev/null

cat <<EOF >"${FLUSS_VALUES}"
persistence:
  enabled: false
image:
  registry: docker.io
  repository: ${FLUSS_IMAGE%:*}
  tag: ${FLUSS_IMAGE##*:}
configurationOverrides:
  "zookeeper.address": zk-svc.default.svc.cluster.local:2181
EOF

# Pre-load the Fluss image into all Kind nodes.
echo "[4/7] Pre-loading ${FLUSS_IMAGE} into all Kind nodes..."
if ! docker image inspect "${FLUSS_IMAGE}" >/dev/null 2>&1; then
  echo "  Pulling ${FLUSS_IMAGE} from registry..."
  docker pull "${FLUSS_IMAGE}" >/dev/null
fi
echo "  Loading ${FLUSS_IMAGE} into Kind nodes..."
kind load docker-image "${FLUSS_IMAGE}" --name "${KIND_NAME}" >/dev/null
echo "  ✓ Image pre-loaded into all Kind nodes"

echo "[5/7] Installing Fluss Helm chart..."
helm repo add fluss https://downloads.apache.org/incubator/fluss/helm-chart >/dev/null 2>&1 || true
helm repo update >/dev/null
helm install fluss fluss/fluss --version "${FLUSS_CHART_VERSION}" -f "${FLUSS_VALUES}" >/dev/null

echo "[6/7] Waiting for Fluss pods..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=fluss --timeout=180s >/dev/null

echo "[7/7] Current pod status:"
kubectl get pods

echo "\nDeployment complete. Sample next steps:"
echo "  kubectl port-forward svc/coordinator-server-hs 9124:9124"
echo "  helm uninstall fluss && kubectl delete -f ${ZK_MANIFEST}"
echo "  kind delete cluster --name ${KIND_NAME}"
