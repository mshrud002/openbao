#!/usr/bin/env bash
set -euo pipefail

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
OpenBao Plugin Registration Script

Registers and enables community plugins from openbao/openbao-plugins.
Run AFTER OpenBao is initialized and unsealed.

Usage: $0 [options]

Options:
  -n, --namespace NS     Kubernetes namespace (default: openbao)
  -r, --release NAME     Helm release / pod prefix (default: openbao)
  --token TOKEN          OpenBao token for authentication
  --token-file FILE      File containing OpenBao token
  --init-file FILE       OpenBao init JSON (default: /tmp/openbao-init-<ns>.json)
  --plugin-dir PATH      Plugin directory in pod (default: /vault/plugins)
  --auth-plugins LIST    Comma-separated auth plugins to register (default: all)
  --secrets-plugins LIST Comma-separated secrets plugins to register (default: all)
  --skip-enable          Skip enabling plugins after registration
  -h, --help             Show this help

Examples:
  $0 --namespace openbao
  $0 --namespace openbao --auth-plugins aws,azure --secrets-plugins aws
EOF
  exit 0
}

NAMESPACE="openbao"
RELEASE_NAME="openbao"
BAO_TOKEN=""
TOKEN_FILE=""
INIT_FILE=""
PLUGIN_DIR="/vault/plugins"
AUTH_PLUGINS=""
SECRETS_PLUGINS=""
SKIP_ENABLE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)      NAMESPACE="$2"; shift 2 ;;
    -r|--release)        RELEASE_NAME="$2"; shift 2 ;;
    --token)             BAO_TOKEN="$2"; shift 2 ;;
    --token-file)        TOKEN_FILE="$2"; shift 2 ;;
    --init-file)         INIT_FILE="$2"; shift 2 ;;
    --plugin-dir)        PLUGIN_DIR="$2"; shift 2 ;;
    --auth-plugins)      AUTH_PLUGINS="$2"; shift 2 ;;
    --secrets-plugins)   SECRETS_PLUGINS="$2"; shift 2 ;;
    --skip-enable)       SKIP_ENABLE=true; shift ;;
    -h|--help)           usage ;;
    *)                   log_error "Unknown option: $1"; usage ;;
  esac
done

: "${INIT_FILE:=/tmp/openbao-init-${NAMESPACE}.json}"

if [[ -z "$BAO_TOKEN" ]]; then
  if [[ -n "$TOKEN_FILE" ]]; then
    BAO_TOKEN=$(cat "$TOKEN_FILE")
  elif [[ -f "$INIT_FILE" ]]; then
    BAO_TOKEN=$(jq -r '.root_token' "$INIT_FILE")
    log_info "Using root token from $INIT_FILE"
  else
    log_error "No token provided. Use --token, --token-file, or ensure $INIT_FILE exists"
    exit 1
  fi
fi

POD="${RELEASE_NAME}-0"

check_pod() {
  if ! kubectl get pod -n "$NAMESPACE" "$POD" &>/dev/null; then
    log_error "Pod $POD not found in namespace $NAMESPACE"
    exit 1
  fi
  log_ok "Pod $POD is available"
}

list_available_plugins() {
  log_info "Plugins in $PLUGIN_DIR:"
  kubectl exec -n "$NAMESPACE" "$POD" -- ls -la "$PLUGIN_DIR" 2>/dev/null || log_warn "Plugin directory not found"
}

compute_sha256() {
  local plugin_name="$1"
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sha256sum "${PLUGIN_DIR}/${plugin_name}" 2>/dev/null | cut -d' ' -f1 || echo ""
}

register_plugin() {
  local type="$1"
  local name="$2"
  local binary="${3:-openbao-plugin-${type}-${name}}"
  local full_path="${PLUGIN_DIR}/${binary}"

  local sha
  sha=$(compute_sha256 "$binary")
  if [[ -z "$sha" ]]; then
    log_warn "Binary $binary not found in plugin directory, skipping..."
    return 1
  fi

  log_info "Registering ${type} plugin: $name (sha256: $sha)"

  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao plugin register \
      -sha256=$sha \
      $type $name \
      $full_path" 2>&1 || log_warn "Registration of $name failed (may already exist)"

  log_ok "Registered ${type}/${name}"
}

enable_auth() {
  local name="$1"
  local path="$1"

  if kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao auth list -format=json 2>/dev/null" | \
    jq -e ".\"${path}/\" or .\"${path}_/\"" &>/dev/null; then
    log_warn "Auth path ${path}/ already enabled"
    return 0
  fi

  log_info "Enabling auth plugin: $name at path=$path"
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao auth enable -path=$path $name" || log_warn "Enable of $name failed"
}

enable_secrets() {
  local name="$1"
  local path="$1"

  if kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao secrets list -format=json 2>/dev/null" | \
    jq -e ".\"${path}/\" or .\"${path}_/\"" &>/dev/null; then
    log_warn "Secrets path ${path}/ already enabled"
    return 0
  fi

  log_info "Enabling secrets engine: $name at path=$path"
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao secrets enable -path=$path $name" || log_warn "Enable of $name failed"
}

register_all_auth() {
  local plugins
  if [[ -n "$AUTH_PLUGINS" ]]; then
    IFS=',' read -ra plugins <<< "$AUTH_PLUGINS"
  else
    plugins=("aws" "azure" "gcp" "github")
  fi

  for plugin in "${plugins[@]}"; do
    register_plugin "auth" "$plugin" || true
  done
}

register_all_secrets() {
  local plugins
  if [[ -n "$SECRETS_PLUGINS" ]]; then
    IFS=',' read -ra plugins <<< "$SECRETS_PLUGINS"
  else
    plugins=("aws" "azure" "gcp" "gcpkms" "nomad" "consul")
  fi

  for plugin in "${plugins[@]}"; do
    register_plugin "secret" "$plugin" || true
  done
}

enable_all_auth() {
  local plugins
  if [[ -n "$AUTH_PLUGINS" ]]; then
    IFS=',' read -ra plugins <<< "$AUTH_PLUGINS"
  else
    plugins=("aws" "azure" "gcp" "github")
  fi

  for plugin in "${plugins[@]}"; do
    enable_auth "$plugin" || true
  done
}

enable_all_secrets() {
  local plugins
  if [[ -n "$SECRETS_PLUGINS" ]]; then
    IFS=',' read -ra plugins <<< "$SECRETS_PLUGINS"
  else
    plugins=("aws" "azure" "gcp" "gcpkms" "nomad" "consul")
  fi

  for plugin in "${plugins[@]}"; do
    enable_secrets "$plugin" || true
  done
}

main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   OpenBao Plugin Registration        ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo ""

  check_pod
  list_available_plugins
  echo ""

  log_info "=== Registering Auth Plugins ==="
  register_all_auth
  echo ""

  log_info "=== Registering Secrets Plugins ==="
  register_all_secrets
  echo ""

  if ! $SKIP_ENABLE; then
    log_info "=== Enabling Auth Plugins ==="
    enable_all_auth
    echo ""

    log_info "=== Enabling Secrets Plugins ==="
    enable_all_secrets
    echo ""
  fi

  log_info "=== Registered Plugins ==="
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao plugin list auth 2>/dev/null" || true
  echo ""
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao plugin list secret 2>/dev/null" || true

  echo ""
  log_ok "Plugin registration complete!"
  log_info "Verify with: kubectl exec -n $NAMESPACE $POD -- bao plugin list auth"
  log_info "              kubectl exec -n $NAMESPACE $POD -- bao plugin list secret"
}

main
