#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
RELEASE="${RELEASE:-openbao}"
CHART="${CHART:-./helm/openbao}"

echo "Checking cluster status..."
kubectl get pods -n "$NAMESPACE"

echo "Upgrading..."
helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" --wait --timeout 10m

echo "Waiting for pods..."
kubectl rollout status "statefulset/${RELEASE}" -n "$NAMESPACE" --timeout=10m

echo "Upgrade complete"
