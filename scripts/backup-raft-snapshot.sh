#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
POD="${POD:-openbao-0}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/tmp/openbao-snapshots}"
S3_BUCKET="${S3_BUCKET:-}"

mkdir -p "$SNAPSHOT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="$SNAPSHOT_DIR/raft-snapshot-${TIMESTAMP}.snap"

echo "Taking raft snapshot from ${POD} in namespace ${NAMESPACE}..."
kubectl exec -n "$NAMESPACE" "$POD" -c openbao -- bao operator raft snapshot save /tmp/raft.snap
kubectl cp -n "$NAMESPACE" "$POD:/tmp/raft.snap" "$SNAPSHOT_FILE" -c openbao

echo "Snapshot saved to: $SNAPSHOT_FILE"

if [[ -n "$S3_BUCKET" ]]; then
  if command -v aws >/dev/null 2>&1; then
    echo "Uploading to s3://${S3_BUCKET}/"
    aws s3 cp "$SNAPSHOT_FILE" "s3://${S3_BUCKET}/raft-snapshot-${TIMESTAMP}.snap"
    echo "Upload complete"
  else
    echo "AWS CLI not found, skipping S3 upload"
  fi
fi
