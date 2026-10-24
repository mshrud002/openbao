#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
POD="${POD:-openbao-0}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/tmp/openbao-snapshots}"
S3_BUCKET="${S3_BUCKET:-}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

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
    if [[ "$RETENTION_DAYS" -gt 0 ]]; then
      CUTOFF=$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d 2>/dev/null || date -v-"${RETENTION_DAYS}"d +%Y%m%d 2>/dev/null || echo "")
      if [[ -n "$CUTOFF" ]]; then
        aws s3 ls "s3://${S3_BUCKET}/" | awk '{print $4}' | grep raft-snapshot | while read -r f; do
          DATE=$(echo "$f" | grep -oP '\d{8}' | head -1 || true)
          if [[ -n "$DATE" && "$DATE" < "$CUTOFF" ]]; then
            echo "Deleting old snapshot $f"
            aws s3 rm "s3://${S3_BUCKET}/$f" || true
          fi
        done
      fi
    fi
  else
    echo "AWS CLI not found, skipping S3 upload"
  fi
fi

# Local retention
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  find "$SNAPSHOT_DIR" -name "raft-snapshot-*.snap" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
fi

