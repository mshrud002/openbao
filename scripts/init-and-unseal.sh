#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
  cat <<EOF
OpenBao Initialize & Unseal Script

Initializes an OpenBao cluster and unseals all pods.
Saves unseal keys and root token to a JSON file.

Usage: $0 [options]

Options:
  -n, --namespace NS     Kubernetes namespace (default: openbao)
  -r, --release NAME     Helm release / pod prefix (default: openbao)
  -o, --output FILE      Output file for init keys (default: /tmp/openbao-init-<namespace>.json)
  -k, --key-shares N     Number of key shares (default: 5)
  -t, --key-threshold N  Key threshold for unseal (default: 3)
  --ha                   Unseal multiple HA pods
  --replicas N           Number of HA replicas (default: 3)
  --status-only          Only check init/unseal status
  -h, --help             Show this help
EOF
  exit 0
}

NAMESPACE="openbao"
RELEASE_NAME="openbao"
OUTPUT_FILE=""
KEY_SHARES=5
KEY_THRESHOLD=3
HA_MODE=false
HA_REPLICAS=3
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
    -r|--release)     RELEASE_NAME="$2"; shift 2 ;;
    -o|--output)      OUTPUT_FILE="$2"; shift 2 ;;
    -k|--key-shares)  KEY_SHARES="$2"; shift 2 ;;
    -t|--key-threshold) KEY_THRESHOLD="$2"; shift 2 ;;
    --ha)             HA_MODE=true; shift ;;
    --replicas)       HA_REPLICAS="$2"; shift 2 ;;
    --status-only)    STATUS_ONLY=true; shift ;;
    -h|--help)        usage ;;
    *)                log_error "Unknown option: $1"; usage ;;
  esac
done

: "${OUTPUT_FILE:=/tmp/openbao-init-${NAMESPACE}.json}"

check_pod() {
  local pod="$1"
  if ! kubectl get pod -n "$NAMESPACE" "$pod" &>/dev/null; then
    log_error "Pod $pod not found in namespace $NAMESPACE"
    return 1
  fi
}

status_check() {
  local pod="${RELEASE_NAME}-0"
  check_pod "$pod"

  log_info "Checking OpenBao status on $pod..."
  if kubectl exec -n "$NAMESPACE" "$pod" -- bao status 2>&1; then
    log_ok "OpenBao is initialized and unsealed"
  else
    log_warn "OpenBao is sealed or not initialized"
  fi
}

init_openbao() {
  local pod="${RELEASE_NAME}-0"
  check_pod "$pod"

  log_info "Waiting for pod $pod to be ready..."
  kubectl wait --namespace "$NAMESPACE" --for=condition=ready "pod/$pod" --timeout=300s

  if kubectl exec -n "$NAMESPACE" "$pod" -- bao status &>/dev/null; then
    log_warn "OpenBao is already initialized"
    return 0
  fi

  log_info "Initializing OpenBao with $KEY_SHARES key shares, $KEY_THRESHOLD threshold..."
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    bao operator init \
    -format=json \
    -key-shares="$KEY_SHARES" \
    -key-threshold="$KEY_THRESHOLD" > "$OUTPUT_FILE"

  if [[ ! -s "$OUTPUT_FILE" ]]; then
    log_error "Init output is empty"
    exit 1
  fi

  log_ok "OpenBao initialized. Keys saved to: $OUTPUT_FILE"
}

unseal_all() {
  if [[ ! -f "$OUTPUT_FILE" ]]; then
    log_error "Init file not found: $OUTPUT_FILE"
    log_error "Run init first or specify the correct output file"
    exit 1
  fi

  local unseal_keys=()
  while IFS='' read -r key; do
    unseal_keys+=("$key")
  done < <(jq -r ".unseal_keys_b64[:$KEY_THRESHOLD][]" "$OUTPUT_FILE")

  if [[ ${#unseal_keys[@]} -eq 0 ]]; then
    log_error "No unseal keys found in $OUTPUT_FILE"
    exit 1
  fi

  local pods=()
  if $HA_MODE; then
    for ((i = 0; i < HA_REPLICAS; i++)); do
      pods+=("${RELEASE_NAME}-${i}")
    done
  else
    pods+=("${RELEASE_NAME}-0")
  fi

  for pod in "${pods[@]}"; do
    if ! kubectl get pod -n "$NAMESPACE" "$pod" &>/dev/null; then
      log_warn "Pod $pod not found, skipping..."
      continue
    fi

    kubectl wait --namespace "$NAMESPACE" --for=condition=ready "pod/$pod" --timeout=120s 2>/dev/null || true

    for key in "${unseal_keys[@]}"; do
      kubectl exec -n "$NAMESPACE" "$pod" -- bao operator unseal "$key" &>/dev/null || true
    done

    local sealed_status
    sealed_status=$(kubectl exec -n "$NAMESPACE" "$pod" -- bao status --format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "unknown")

    if [[ "$sealed_status" == "false" ]]; then
      log_ok "Pod $pod: unsealed successfully"
    else
      log_warn "Pod $pod: still sealed (sealed=$sealed_status)"
    fi
  done

  log_ok "Unseal process complete for all pods"
  log_info "Root token: $(jq -r '.root_token' "$OUTPUT_FILE")"
}

main() {
  if $STATUS_ONLY; then
    status_check
    exit 0
  fi

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   OpenBao Init & Unseal Script       ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo ""

  init_openbao
  unseal_all

  echo ""
  log_info "✅ OpenBao is ready!"
  log_info "   Login: kubectl exec -n $NAMESPACE -it ${RELEASE_NAME}-0 -- bao login"
  log_info "   Key file: $OUTPUT_FILE (KEEP SECURE!)"
}

main
