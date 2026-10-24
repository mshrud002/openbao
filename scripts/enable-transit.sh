#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-}"
TRANSIT_PATH="${TRANSIT_PATH:-transit}"
KEY_NAME="${KEY_NAME:-app-key}"

if [[ -z "$BAO_ADDR" ]]; then echo "BAO_ADDR required"; exit 1; fi
export BAO_ADDR

bao secrets list 2>/dev/null | grep -q "^${TRANSIT_PATH}/" || bao secrets enable -path="${TRANSIT_PATH}" transit
bao write -f ${TRANSIT_PATH}/keys/${KEY_NAME}
echo "Transit enabled with key ${KEY_NAME}"
