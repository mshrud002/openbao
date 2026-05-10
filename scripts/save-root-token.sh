#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
  cat <<EOF
OpenBao Root Token Saver

Stores the OpenBao root token and unseal keys as a Kubernetes secret.

Usage: $0 [options]

Options:
  -n, --namespace NS     Kubernetes namespace (default: openbao)
  -r, --release NAME     Helm release name (default: openbao)
  --init-file FILE       Path to init JSON (default: /tmp/openbao-init-<ns>.json)
  --secret-name NAME     K8s secret name (default: <release>-openbao-credentials)
  -h, --help             Show this help
EOF
  exit 0
}

NAMESPACE="openbao"
RELEASE_NAME="openbao"
INIT_FILE=""
SECRET_NAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -r|--release)    RELEASE_NAME="$2"; shift 2 ;;
    --init-file)     INIT_FILE="$2"; shift 2 ;;
    --secret-name)   SECRET_NAME="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *)               log_error "Unknown option: $1"; exit 1 ;;
  esac
done

: "${INIT_FILE:=/tmp/openbao-init-${NAMESPACE}.json}"
: "${SECRET_NAME:=${RELEASE_NAME}-openbao-credentials}"

if [[ ! -f "$INIT_FILE" ]]; then
  log_error "Init file not found: $INIT_FILE"
  exit 1
fi

ROOT_TOKEN=$(jq -r '.root_token' "$INIT_FILE")
UNSEAL_KEYS=$(jq -r '.unseal_keys_b64 | join(" ")' "$INIT_FILE")

if kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
  log_warn "Secret $SECRET_NAME already exists, updating..."
  kubectl delete secret -n "$NAMESPACE" "$SECRET_NAME"
fi

kubectl create secret generic -n "$NAMESPACE" "$SECRET_NAME" \
  --from-literal=root-token="$ROOT_TOKEN" \
  --from-literal=unseal-keys="$UNSEAL_KEYS" \
  --from-file=init-json="$INIT_FILE"

log_ok "Root token and unseal keys stored in secret: $SECRET_NAME"
log_info "Retrieve with: kubectl get secret -n $NAMESPACE $SECRET_NAME -o jsonpath='{.data.root-token}' | base64 -d"
