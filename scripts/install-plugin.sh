#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
OpenBao Plugin Installer

Installs custom plugins into a running OpenBao cluster.
Supports three methods:

  1. Local binary  - Upload a plugin binary from the local filesystem
  2. Container     - Reference a plugin already in the pod
  3. ConfigMap     - Reference a plugin name from a ConfigMap (Helm-managed)

Usage: $0 [options] <plugin-name> [plugin-binary]

Options:
  -n, --namespace NS     Kubernetes namespace (default: openbao)
  -r, --release NAME     Helm release / pod prefix (default: openbao)
  -t, --type TYPE        Plugin type: secret, auth, database (default: secret)
  --token TOKEN          OpenBao token for authentication
  --token-file FILE      File containing OpenBao token
  --sha256 HASH          SHA-256 checksum of the plugin binary
  --in-pod PATH          Plugin binary is already at PATH inside the pod
  --from-configmap NAME  Plugin binary is from a ConfigMap
  --mount-path PATH      Path to mount the plugin as a secrets engine (default: <plugin-name>)
  --no-mount             Register plugin without mounting
  --update               Update existing plugin registration
  -h, --help             Show this help

Examples:
  # Install from local binary
  $0 my-plugin ./my-plugin-binary --token s.abc123

  # Install a plugin already in the pod
  $0 my-plugin --in-pod /openbao/plugins/my-plugin --token s.abc123

  # Register and mount as a secrets engine
  $0 my-plugin ./my-plugin-binary --token s.abc123 --mount-path my-app
EOF
  exit 0
}

NAMESPACE="openbao"
RELEASE_NAME="openbao"
PLUGIN_NAME=""
PLUGIN_BINARY=""
PLUGIN_TYPE="secret"
BAO_TOKEN=""
TOKEN_FILE=""
SHA256=""
IN_POD_PATH=""
FROM_CONFIGMAP=""
MOUNT_PATH=""
NO_MOUNT=false
UPDATE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)     NAMESPACE="$2"; shift 2 ;;
    -r|--release)       RELEASE_NAME="$2"; shift 2 ;;
    -t|--type)          PLUGIN_TYPE="$2"; shift 2 ;;
    --token)            BAO_TOKEN="$2"; shift 2 ;;
    --token-file)       TOKEN_FILE="$2"; shift 2 ;;
    --sha256)           SHA256="$2"; shift 2 ;;
    --in-pod)           IN_POD_PATH="$2"; shift 2 ;;
    --from-configmap)   FROM_CONFIGMAP="$2"; shift 2 ;;
    --mount-path)       MOUNT_PATH="$2"; shift 2 ;;
    --no-mount)         NO_MOUNT=true; shift ;;
    --update)           UPDATE=true; shift ;;
    -h|--help)          usage ;;
    -*)
      log_error "Unknown option: $1"
      usage
      ;;
    *)
      if [[ -z "$PLUGIN_NAME" ]]; then
        PLUGIN_NAME="$1"
      elif [[ -z "$PLUGIN_BINARY" ]]; then
        PLUGIN_BINARY="$1"
      else
        log_error "Unexpected argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PLUGIN_NAME" ]]; then
  log_error "Plugin name is required"
  usage
fi

if [[ -n "$TOKEN_FILE" ]]; then
  BAO_TOKEN=$(cat "$TOKEN_FILE")
fi

if [[ -z "$BAO_TOKEN" ]]; then
  local init_file="/tmp/openbao-init-${NAMESPACE}.json"
  if [[ -f "$init_file" ]]; then
    BAO_TOKEN=$(jq -r '.root_token' "$init_file")
    log_info "Using root token from $init_file"
  else
    log_error "No token provided. Use --token, --token-file, or ensure $init_file exists"
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

copy_plugin_to_pod() {
  local src="$1"
  local dest="/tmp/${PLUGIN_NAME}"

  if [[ ! -f "$src" ]]; then
    log_error "Plugin binary not found: $src"
    exit 1
  fi

  if [[ -z "$SHA256" ]]; then
    SHA256=$(sha256sum "$src" | cut -d' ' -f1)
    log_info "Computed SHA-256: $SHA256"
  fi

  log_info "Copying plugin binary to pod $POD..."
  kubectl cp --namespace "$NAMESPACE" "$src" "$POD:$dest"

  kubectl exec -n "$NAMESPACE" "$POD" -- chmod 755 "$dest"
  log_ok "Plugin binary copied to $POD:$dest"
}

register_plugin() {
  local plugin_path

  if [[ -n "$IN_POD_PATH" ]]; then
    plugin_path="$IN_POD_PATH"
  elif [[ -n "$FROM_CONFIGMAP" ]]; then
    plugin_path="/openbao/plugins/$FROM_CONFIGMAP"
  else
    plugin_path="/tmp/${PLUGIN_NAME}"
  fi

  local register_args=(
    "-address=http://127.0.0.1:8200"
    "plugin" "register"
    "-sha256=$SHA256"
  )

  if $UPDATE; then
    register_args+=("-force")
  fi

  register_args+=("$PLUGIN_TYPE" "$PLUGIN_NAME" "$plugin_path")

  log_info "Registering plugin: $PLUGIN_NAME (type: $PLUGIN_TYPE)..."
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao ${register_args[*]}"

  log_ok "Plugin $PLUGIN_NAME registered successfully"
}

mount_plugin() {
  if $NO_MOUNT; then
    return 0
  fi

  local mount_path="${MOUNT_PATH:-$PLUGIN_NAME}"

  if kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao secrets list -format=json" 2>/dev/null | \
    jq -e ".[\"$mount_path/\"]" &>/dev/null; then
    log_warn "Path $mount_path/ already has a secrets engine mounted"
    return 0
  fi

  log_info "Mounting plugin at $mount_path/ ..."
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao secrets enable \
      -path=$mount_path \
      -plugin-name=$PLUGIN_NAME \
      plugin" || log_warn "Mount failed (may need manual setup)"

  log_ok "Plugin mounted at $mount_path/"
}

verify_plugin() {
  log_info "Verifying plugin installation..."
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "BAO_TOKEN=$BAO_TOKEN bao plugin list $PLUGIN_TYPE" 2>/dev/null | grep -q "$PLUGIN_NAME" && \
    log_ok "Plugin $PLUGIN_NAME verified in type $PLUGIN_TYPE" || \
    log_warn "Plugin $PLUGIN_NAME not found in plugin list"
}

main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     OpenBao Plugin Installer          ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo ""

  check_pod

  if [[ -z "$IN_POD_PATH" && -z "$FROM_CONFIGMAP" ]]; then
    if [[ -z "$PLUGIN_BINARY" ]]; then
      log_error "Plugin binary path required. Use --in-pod, --from-configmap, or provide a file path"
      usage
    fi
    copy_plugin_to_pod "$PLUGIN_BINARY"
  fi

  if [[ -n "$FROM_CONFIGMAP" ]]; then
    log_info "Using plugin from ConfigMap: $FROM_CONFIGMAP (path: /openbao/plugins/$FROM_CONFIGMAP)"
  fi

  register_plugin
  mount_plugin
  verify_plugin

  echo ""
  log_info "✅ Plugin $PLUGIN_NAME installed and ready"
}

main
