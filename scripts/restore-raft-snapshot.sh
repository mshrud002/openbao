#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
POD="${POD:-openbao-0}"
SNAPSHOT_FILE="${1:-}"

if [[ -z "$SNAPSHOT_FILE" ]]; then
  echo "Usage: $0 <snapshot-file.snap>"
  exit 1
fi

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
  echo "Snapshot file not found: $SNAPSHOT_FILE"
  exit 1
fi

echo "Restoring raft snapshot to ${POD} in namespace ${NAMESPACE}..."
kubectl cp -n "$NAMESPACE" "$SNAPSHOT_FILE" "$POD:/tmp/raft.snap" -c openbao
kubectl exec -n "$NAMESPACE" "$POD" -c openbao -- bao operator raft snapshot restore -force /tmp/raft.snap
echo "Restore complete. OpenBao will need to be unsealed if using Shamir."
