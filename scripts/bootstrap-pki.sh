#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-}"
PKI_PATH="${PKI_PATH:-pki}"
COMMON_NAME="${COMMON_NAME:-OpenBao Root CA}"
TTL="${TTL:-87600h}"

if [[ -z "$BAO_ADDR" ]]; then echo "BAO_ADDR required"; exit 1; fi
export BAO_ADDR

echo "Enabling PKI at ${PKI_PATH}..."
bao secrets list 2>/dev/null | grep -q "^${PKI_PATH}/" || bao secrets enable -path="${PKI_PATH}" pki
bao secrets tune -max-lease-ttl="${TTL}" ${PKI_PATH}

echo "Generating root CA..."
bao write -field=certificate ${PKI_PATH}/root/generate/internal \
  common_name="${COMMON_NAME}" \
  ttl="${TTL}" > /tmp/ca.crt

bao write ${PKI_PATH}/config/urls \
  issuing_certificates="${BAO_ADDR}/v1/${PKI_PATH}/ca" \
  crl_distribution_points="${BAO_ADDR}/v1/${PKI_PATH}/crl"

echo "Creating role for example.com..."
bao write ${PKI_PATH}/roles/example-dot-com \
  allowed_domains="example.com" \
  allow_subdomains=true \
  max_ttl="720h"

echo "PKI bootstrapped. CA saved to /tmp/ca.crt"
echo "Issue cert: bao write ${PKI_PATH}/issue/example-dot-com common_name=test.example.com"
