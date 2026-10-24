#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-}"
KV_PATH="${KV_PATH:-secret}"
VERSION="${VERSION:-2}"
MAX_VERSIONS="${MAX_VERSIONS:-10}"

if [[ -z "$BAO_ADDR" ]]; then echo "BAO_ADDR required"; exit 1; fi
export BAO_ADDR

echo "Enabling KV v${VERSION} at ${KV_PATH}..."
bao secrets list 2>/dev/null | grep -q "^${KV_PATH}/" || bao secrets enable -path="${KV_PATH}" -version=${VERSION} kv

if [[ "$VERSION" == "2" ]]; then
  bao write ${KV_PATH}/config max_versions=${MAX_VERSIONS}
fi

echo "KV enabled"
