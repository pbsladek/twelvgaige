#!/bin/sh
set -eu

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf "missing required command: %s\n" "$1" >&2
    exit 127
  }
}

require_command k3d
require_command kubectl
require_command mix

cluster="${K3D_CLUSTER_PREFIX:-twelvgaige-live}-$(date +%s)-$$"
namespace="${K3D_NAMESPACE:-default}"
context="k3d-$cluster"
artifact_dir="${TWELVGAIGE_LIVE_ARTIFACT_DIR:-/tmp/twelvgaige-live-k3d-$cluster}"

cleanup() {
  status=$?

  if [ "$status" -ne 0 ]; then
    mkdir -p "$artifact_dir"
    kubectl --context "$context" get nodes -o wide > "$artifact_dir/nodes.txt" 2>&1 || true
    kubectl --context "$context" get all -A -o wide > "$artifact_dir/all.txt" 2>&1 || true
    kubectl --context "$context" get events -A --sort-by=.lastTimestamp > "$artifact_dir/events.txt" 2>&1 || true
  fi

  k3d cluster delete "$cluster" >/dev/null 2>&1 || true
  exit "$status"
}

trap cleanup EXIT INT TERM

k3d cluster create "$cluster" --wait --agents 0
kubectl --context "$context" get namespace "$namespace" >/dev/null

TWELVGAIGE_K8S_LIVE=1 \
  TWELVGAIGE_K8S_CONTEXT="$context" \
  TWELVGAIGE_K8S_NAMESPACE="$namespace" \
  TWELVGAIGE_K8S_TIMEOUT_MS="${TWELVGAIGE_K8S_TIMEOUT_MS:-30000}" \
  MIX_ENV=test \
  mix test --include k8s_live test/twelvgaige/integration/kubernetes_live_test.exs

printf "k3d live e2e passed for cluster %s\n" "$cluster"
