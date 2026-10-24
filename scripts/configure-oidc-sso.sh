#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
BAO_ADDR="${BAO_ADDR:-}"
AUTH_PATH="${AUTH_PATH:-oidc}"
DISCOVERY_URL="${DISCOVERY_URL:-}"
CLIENT_ID="${CLIENT_ID:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
CLIENT_SECRET_SECRET_NAME="${CLIENT_SECRET_SECRET_NAME:-}"
CLIENT_SECRET_SECRET_KEY="${CLIENT_SECRET_SECRET_KEY:-client-secret}"
DEFAULT_ROLE="${DEFAULT_ROLE:-default}"
ALLOWED_REDIRECT_URIS="${ALLOWED_REDIRECT_URIS:-https://bao.example.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback}"
OIDC_SCOPES="${OIDC_SCOPES:-openid,profile,email,groups}"
GROUPS_CLAIM="${GROUPS_CLAIM:-groups}"
USER_CLAIM="${USER_CLAIM:-email}"
BOUND_AUDIENCES="${BOUND_AUDIENCES:-}"

if [[ -z "$BAO_ADDR" || -z "$DISCOVERY_URL" || -z "$CLIENT_ID" ]]; then
  echo "BAO_ADDR, DISCOVERY_URL, CLIENT_ID required"
  exit 1
fi

export BAO_ADDR

if [[ -n "$CLIENT_SECRET_SECRET_NAME" ]]; then
  echo "Reading client secret from k8s secret ${CLIENT_SECRET_SECRET_NAME}"
  CLIENT_SECRET=$(kubectl get secret -n "$NAMESPACE" "$CLIENT_SECRET_SECRET_NAME" -o jsonpath="{.data.${CLIENT_SECRET_SECRET_KEY}}" | base64 -d)
fi

echo "Enabling OIDC auth at ${AUTH_PATH}..."
bao auth list 2>/dev/null | grep -q "^${AUTH_PATH}/" || bao auth enable -path="${AUTH_PATH}" oidc

echo "Configuring OIDC..."
bao write "auth/${AUTH_PATH}/config" \
  oidc_discovery_url="${DISCOVERY_URL}" \
  oidc_client_id="${CLIENT_ID}" \
  oidc_client_secret="${CLIENT_SECRET}" \
  default_role="${DEFAULT_ROLE}"

echo "Creating OIDC role ${DEFAULT_ROLE}..."
bao write "auth/${AUTH_PATH}/role/${DEFAULT_ROLE}" \
  allowed_redirect_uris="${ALLOWED_REDIRECT_URIS}" \
  oidc_scopes="${OIDC_SCOPES}" \
  groups_claim="${GROUPS_CLAIM}" \
  user_claim="${USER_CLAIM}" \
  bound_audiences="${BOUND_AUDIENCES}" \
  token_policies="default" \
  role_type="oidc"

echo "OIDC SSO configured. Sign in via UI at /ui/vault/auth/${AUTH_PATH}/login"
echo "CLI: bao login -method=oidc -path=${AUTH_PATH} role=${DEFAULT_ROLE}"
