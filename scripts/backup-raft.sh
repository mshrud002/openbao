#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
  cat <<EOF
OpenBao Raft Snapshot Backup

Takes a raft snapshot and saves it locally or to S3.

Usage: $0 [options]

Options:
  -n, --namespace NS     Kubernetes namespace (default: openbao)
  -r, --release NAME     Helm release / pod prefix (default: openbao)
  --token TOKEN          OpenBao token
  --token-file FILE      File containing OpenBao token
  --init-file FILE       OpenBao init JSON (default: /tmp/openbao-init-<ns>.json)
  --output DIR           Output directory for snapshots (default: ./backups)
  --s3-bucket BUCKET     S3 bucket to upload snapshot
  --s3-prefix PREFIX     S3 key prefix (default: openbao-raft-snapshots)
  --s3-region REGION     AWS region (default: eu-west-1)
  -h, --help             Show this help
EOF
  exit 0
}

NAMESPACE="openbao"
RELEASE_NAME="openbao"
BAO_TOKEN=""
TOKEN_FILE=""
INIT_FILE=""
OUTPUT_DIR="./backups"
S3_BUCKET=""
S3_PREFIX="openbao-raft-snapshots"
S3_REGION="eu-west-1"

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)    NAMESPACE="$2"; shift 2 ;;
    -r|--release)      RELEASE_NAME="$2"; shift 2 ;;
    --token)           BAO_TOKEN="$2"; shift 2 ;;
    --token-file)      TOKEN_FILE="$2"; shift 2 ;;
    --init-file)       INIT_FILE="$2"; shift 2 ;;
    --output)          OUTPUT_DIR="$2"; shift 2 ;;
    --s3-bucket)       S3_BUCKET="$2"; shift 2 ;;
    --s3-prefix)       S3_PREFIX="$2"; shift 2 ;;
    --s3-region)       S3_REGION="$2"; shift 2 ;;
    -h|--help)         usage ;;
    *)                 log_error "Unknown option: $1"; usage ;;
  esac
done

: "${INIT_FILE:=/tmp/openbao-init-${NAMESPACE}.json}"

if [[ -z "$BAO_TOKEN" ]]; then
  if [[ -n "$TOKEN_FILE" ]]; then
    BAO_TOKEN=$(cat "$TOKEN_FILE")
  elif [[ -f "$INIT_FILE" ]]; then
    BAO_TOKEN=$(jq -r '.root_token' "$INIT_FILE")
  else
    log_error "No token provided"
    exit 1
  fi
fi

POD="${RELEASE_NAME}-0"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="openbao-raft-snapshot-${TIMESTAMP}.snap"

mkdir -p "$OUTPUT_DIR"

log_info "Taking raft snapshot from pod $POD..."
kubectl exec -n "$NAMESPACE" "$POD" -- \
  sh -c "BAO_TOKEN=$BAO_TOKEN bao operator raft snapshot save - /tmp/${SNAPSHOT_FILE} 2>/dev/null; cat /tmp/${SNAPSHOT_FILE}" \
  > "${OUTPUT_DIR}/${SNAPSHOT_FILE}"

SIZE=$(stat -c%s "${OUTPUT_DIR}/${SNAPSHOT_FILE}" 2>/dev/null || stat -f%z "${OUTPUT_DIR}/${SNAPSHOT_FILE}" 2>/dev/null)
log_ok "Snapshot saved: ${OUTPUT_DIR}/${SNAPSHOT_FILE} ($(numfmt --to=iec "$SIZE" 2>/dev/null || echo "$SIZE bytes"))"

if [[ -n "$S3_BUCKET" ]]; then
  if command -v aws &>/dev/null; then
    S3_KEY="${S3_PREFIX}/${SNAPSHOT_FILE}"
    log_info "Uploading to s3://${S3_BUCKET}/${S3_KEY}..."
    aws s3 cp "${OUTPUT_DIR}/${SNAPSHOT_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --region "$S3_REGION"
    log_ok "Uploaded to S3"
  else
    log_error "aws CLI not installed, skipping S3 upload"
  fi
fi

log_info "To restore: bao operator raft snapshot restore - ${OUTPUT_DIR}/${SNAPSHOT_FILE}"
