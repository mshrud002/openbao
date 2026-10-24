#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-}"
OIDC_PATH="${OIDC_PATH:-oidc}"
GROUP_NAME="${GROUP_NAME:-}"
POLICIES="${POLICIES:-default}"
OIDC_GROUP_CLAIM="${OIDC_GROUP_CLAIM:-groups}"

if [[ -z "$BAO_ADDR" || -z "$GROUP_NAME" ]]; then
  echo "Usage: GROUP_NAME=admins POLICIES=admin BAO_ADDR=... $0"
  exit 1
fi

export BAO_ADDR

# Create external group
GROUP_ID=$(bao write -field=id identity/group name="${GROUP_NAME}" type="external" policies="${POLICIES}" 2>/dev/null || echo "")
if [[ -z "$GROUP_ID" ]]; then
  GROUP_ID=$(bao read -field=id "identity/group/name/${GROUP_NAME}" 2>/dev/null || echo "")
fi

# Get OIDC auth mount accessor
ACCESSOR=$(bao auth list -format=json | jq -r ".\"${OIDC_PATH}/\".accessor" 2>/dev/null || echo "")
if [[ -z "$ACCESSOR" ]]; then
  echo "Could not find accessor for ${OIDC_PATH}"
  exit 1
fi

# Create group alias
bao write identity/group-alias name="${GROUP_NAME}" mount_accessor="${ACCESSOR}" canonical_group_id="${GROUP_ID}" 2>/dev/null || echo "Alias may exist"

echo "OIDC group mapping configured: ${GROUP_NAME} -> ${POLICIES}"
