#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-}"
ROLE_NAME="${ROLE_NAME:-app-role}"
POLICIES="${POLICIES:-default}"
SECRET_ID_TTL="${SECRET_ID_TTL:-600}"
TOKEN_TTL="${TOKEN_TTL:-3600}"
TOKEN_MAX_TTL="${TOKEN_MAX_TTL:-86400}"

if [[ -z "$BAO_ADDR" ]]; then
  echo "BAO_ADDR required"; exit 1
fi
export BAO_ADDR

echo "Enabling approle..."
bao auth list 2>/dev/null | grep -q "^approle/" || bao auth enable approle

echo "Creating role ${ROLE_NAME}..."
bao write "auth/approle/role/${ROLE_NAME}" \
  token_policies="${POLICIES}" \
  token_ttl="${TOKEN_TTL}" \
  token_max_ttl="${TOKEN_MAX_TTL}" \
  secret_id_ttl="${SECRET_ID_TTL}"

ROLE_ID=$(bao read -field=role_id "auth/approle/role/${ROLE_NAME}/role-id")
SECRET_ID=$(bao write -field=secret_id -f "auth/approle/role/${ROLE_NAME}/secret-id")

echo "ROLE_ID=${ROLE_ID}"
echo "SECRET_ID=${SECRET_ID}"
echo "Login: bao write auth/approle/login role_id=${ROLE_ID} secret_id=${SECRET_ID}"
