#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
BAO_ADDR="${BAO_ADDR:-}"
ROLE_NAME="${ROLE_NAME:-openbao-k8s}"
SERVICE_ACCOUNTS="${SERVICE_ACCOUNTS:-*}"
SERVICE_NAMESPACES="${SERVICE_NAMESPACES:-$NAMESPACE}"
POLICIES="${POLICIES:-default}"
TOKEN_TTL="${TOKEN_TTL:-3600}"
TOKEN_MAX_TTL="${TOKEN_MAX_TTL:-86400}"
AUTH_PATH="${AUTH_PATH:-auth/kubernetes}"

if [[ -z "$BAO_ADDR" ]]; then
  echo "BAO_ADDR not set"
  exit 1
fi

export BAO_ADDR

echo "Enabling kubernetes auth at ${AUTH_PATH} if not enabled..."
bao auth list 2>/dev/null | grep -q "^kubernetes/" || bao auth enable -path="${AUTH_PATH}" kubernetes

echo "Configuring kubernetes auth..."
K8S_HOST="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT:-443}"
K8S_CA_CERT="${K8S_CA_CERT:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}"
K8S_TOKEN="${K8S_TOKEN:-/var/run/secrets/kubernetes.io/serviceaccount/token}"

if [[ -f "$K8S_CA_CERT" && -f "$K8S_TOKEN" ]]; then
  bao write "${AUTH_PATH}/config" \
    kubernetes_host="${K8S_HOST}" \
    kubernetes_ca_cert=@"${K8S_CA_CERT}" \
    token_reviewer_jwt=@"${K8S_TOKEN}"
else
  echo "Using in-cluster defaults for kubernetes auth config"
  bao write "${AUTH_PATH}/config" kubernetes_host="${K8S_HOST}" || true
fi

echo "Creating role ${ROLE_NAME}..."
bao write "${AUTH_PATH}/role/${ROLE_NAME}" \
  bound_service_account_names="${SERVICE_ACCOUNTS}" \
  bound_service_account_namespaces="${SERVICE_NAMESPACES}" \
  policies="${POLICIES}" \
  ttl="${TOKEN_TTL}" \
  max_ttl="${TOKEN_MAX_TTL}"
echo "Kubernetes auth configured"
