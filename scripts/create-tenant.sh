#!/usr/bin/env bash
set -euo pipefail

# Create a tenant using OpenBao namespaces (if supported) or path-based multi-tenancy
# Follows OpenBao docs patterns for namespace/workspace isolation

NAMESPACE="${NAMESPACE:-openbao}"
BAO_ADDR="${BAO_ADDR:-}"
TENANT_NAME="${1:-}"
DESCRIPTION="${2:-Tenant $TENANT_NAME}"
POLICIES="${POLICIES:-${TENANT_NAME}-admin}"
CREATE_NAMESPACE="${CREATE_NAMESPACE:-true}"
ENABLE_KV="${ENABLE_KV:-true}"
KV_PATH="${KV_PATH:-secret}"
ENABLE_K8S_AUTH="${ENABLE_K8S_AUTH:-false}"
K8S_ROLE_NAME="${K8S_ROLE_NAME:-${TENANT_NAME}-k8s}"

if [[ -z "$BAO_ADDR" || -z "$TENANT_NAME" ]]; then
  echo "Usage: $0 <tenant-name> [description]"
  echo "BAO_ADDR must be set"
  exit 1
fi

export BAO_ADDR

echo "Creating tenant: ${TENANT_NAME}"

# Try to create namespace (OpenBao namespaces)
if [[ "$CREATE_NAMESPACE" == "true" ]]; then
  echo "Attempting to create namespace: ${TENANT_NAME}"
  if bao namespace list 2>/dev/null | grep -q "${TENANT_NAME}"; then
    echo "Namespace ${TENANT_NAME} already exists"
  else
    if bao namespace create "${TENANT_NAME}" 2>/dev/null; then
      echo "Namespace created: ${TENANT_NAME}"
      export VAULT_NAMESPACE="${TENANT_NAME}"
      export BAO_NAMESPACE="${TENANT_NAME}"
    else
      echo "Namespaces not available or failed; falling back to path-based multi-tenancy"
      CREATE_NAMESPACE="false"
    fi
  fi
fi

# Create tenant admin policy
POLICY_NAME="${TENANT_NAME}-admin"
echo "Creating policy: ${POLICY_NAME}"
cat > /tmp/${POLICY_NAME}.hcl <<EOF
# Admin policy for tenant ${TENANT_NAME}
path "${TENANT_NAME}/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/mounts/${TENANT_NAME}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "auth/token/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

bao policy write "${POLICY_NAME}" /tmp/${POLICY_NAME}.hcl

# Enable KV secrets engine under tenant path if using path-based tenancy
if [[ "$CREATE_NAMESPACE" != "true" && "$ENABLE_KV" == "true" ]]; then
  echo "Enabling KV v2 at ${TENANT_NAME}/${KV_PATH}"
  bao secrets enable -path="${TENANT_NAME}/${KV_PATH}" -version=2 kv 2>/dev/null || echo "KV may already be enabled"
fi

# Create identity group for tenant (if using identity)
echo "Creating identity group for tenant..."
GROUP_ID=$(bao write -field=id identity/group name="${TENANT_NAME}" policies="${POLICIES}" type="internal" 2>/dev/null || echo "")
if [[ -n "$GROUP_ID" ]]; then
  echo "Identity group created: ${GROUP_ID}"
fi

echo "Tenant ${TENANT_NAME} created successfully"
echo "Namespace mode: ${CREATE_NAMESPACE}"
if [[ "$CREATE_NAMESPACE" == "true" ]]; then
  echo "Use: export BAO_NAMESPACE=${TENANT_NAME}"
else
  echo "Use path: ${TENANT_NAME}/${KV_PATH}/"
fi
