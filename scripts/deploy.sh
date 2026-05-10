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
OpenBao Kubernetes Deployment Script

Usage: $0 [options]

Options:
  -m, --mode MODE        Deployment mode: dev, standalone, ha (default: standalone)
  -n, --namespace NS     Kubernetes namespace (default: openbao)
  -r, --release NAME     Helm release name (default: openbao)
  --chart PATH           Path to Helm chart (default: ../helm/openbao)
  --values FILE          Additional values file for Helm
  --init                 Initialize and unseal after deployment
  --plugins FILE         Plugin config file (YAML/JSON, see examples)
  --community-plugins    Enable community openbao-plugins download
  --register-plugins     Register and enable plugins after init/unseal
  --terraform            Use Terraform instead of Helm directly
  --tf-dir DIR           Terraform directory (default: ../terraform/examples/complete)
  -h, --help             Show this help message

Examples:
  $0 --mode standalone --namespace openbao
  $0 --mode ha --init --community-plugins --register-plugins
  $0 --terraform --mode ha --init
EOF
  exit 0
}

MODE="standalone"
NAMESPACE="openbao"
RELEASE_NAME="openbao"
CHART_PATH="$PROJECT_DIR/helm/openbao"
VALUES_FILE=""
DO_INIT=false
PLUGINS_FILE=""
COMMUNITY_PLUGINS=false
REGISTER_PLUGINS=false
USE_TERRAFORM=false
TF_DIR="$PROJECT_DIR/terraform/examples/complete"

while [[ $# -gt 0 ]]; do
  case $1 in
    -m|--mode)       MODE="$2"; shift 2 ;;
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -r|--release)    RELEASE_NAME="$2"; shift 2 ;;
    --chart)         CHART_PATH="$2"; shift 2 ;;
    --values)        VALUES_FILE="$2"; shift 2 ;;
    --init)          DO_INIT=true; shift ;;
    --plugins)           PLUGINS_FILE="$2"; shift 2 ;;
    --community-plugins) COMMUNITY_PLUGINS=true; shift ;;
    --register-plugins)  REGISTER_PLUGINS=true; shift ;;
    --terraform)         USE_TERRAFORM=true; shift ;;
    --tf-dir)            TF_DIR="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *)               log_error "Unknown option: $1"; usage ;;
  esac
done

check_prerequisites() {
  log_info "Checking prerequisites..."
  local missing=false

  for cmd in kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd is not installed"
      missing=true
    fi
  done

  if $USE_TERRAFORM; then
    if ! command -v terraform &>/dev/null; then
      log_error "terraform is not installed"
      missing=true
    fi
  fi

  if $missing; then
    log_error "Install missing tools and retry"
    exit 1
  fi

  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
  fi
  log_ok "All prerequisites met, cluster reachable"
}

deploy_helm() {
  log_info "Deploying OpenBao via Helm (mode: $MODE)..."

  local helm_args=(
    --namespace "$NAMESPACE"
    --create-namespace
    --wait
    --timeout 10m
  )

  if [[ -n "$VALUES_FILE" ]]; then
    helm_args+=(-f "$VALUES_FILE")
  fi

  case "$MODE" in
    dev)
      helm_args+=(
        --set server.dev.enabled=true
        --set server.standalone.enabled=false
        --set server.ha.enabled=false
        --set server.replicas=1
      )
      ;;
    standalone)
      helm_args+=(
        --set server.dev.enabled=false
        --set server.standalone.enabled=true
        --set server.ha.enabled=false
        --set server.replicas=1
      )
      ;;
    ha)
      helm_args+=(
        --set server.dev.enabled=false
        --set server.standalone.enabled=false
        --set server.ha.enabled=true
        --set server.replicas=3
      )
      ;;
  esac

  if [[ -n "$PLUGINS_FILE" ]]; then
    log_info "Loading plugin configuration from $PLUGINS_FILE..."
    while IFS='=' read -r plugin_name plugin_binary; do
      [[ -z "$plugin_name" || "$plugin_name" == \#* ]] && continue
      helm_args+=(--set "plugins.extra.$plugin_name=$plugin_binary")
    done < <(yq eval '.plugins.extra | to_entries | .[] | .key + "=" + .value' "$PLUGINS_FILE" 2>/dev/null || true)
  fi

  if $COMMUNITY_PLUGINS; then
    log_info "Enabling community openbao-plugins download..."
    helm_args+=(--set plugins.community.enabled=true)
    helm_args+=(--set plugins.community.auth.aws.enabled=true)
    helm_args+=(--set plugins.community.auth.azure.enabled=true)
    helm_args+=(--set plugins.community.auth.gcp.enabled=true)
    helm_args+=(--set plugins.community.auth.github.enabled=true)
    helm_args+=(--set plugins.community.secrets.aws.enabled=true)
    helm_args+=(--set plugins.community.secrets.azure.enabled=true)
    helm_args+=(--set plugins.community.secrets.gcp.enabled=true)
    helm_args+=(--set plugins.community.secrets.gcpkms.enabled=true)
    helm_args+=(--set plugins.community.secrets.nomad.enabled=true)
    helm_args+=(--set plugins.community.secrets.consul.enabled=true)
  fi

  if helm status "$RELEASE_NAME" --namespace "$NAMESPACE" &>/dev/null; then
    log_info "Release exists, upgrading..."
    helm upgrade "$RELEASE_NAME" "$CHART_PATH" "${helm_args[@]}"
  else
    helm install "$RELEASE_NAME" "$CHART_PATH" "${helm_args[@]}"
  fi

  log_ok "Helm deployment complete"
}

deploy_terraform() {
  log_info "Deploying OpenBao via Terraform (mode: $MODE)..."

  if [[ ! -d "$TF_DIR" ]]; then
    log_error "Terraform directory not found: $TF_DIR"
    exit 1
  fi

  pushd "$TF_DIR" >/dev/null

  local tf_args=(
    -var "namespace=$NAMESPACE"
    -var "mode=$MODE"
    -var "helm_release_name=$RELEASE_NAME"
  )

  if [[ -n "$VALUES_FILE" ]]; then
    tf_args+=(-var-file "$VALUES_FILE")
  fi

  if [[ -n "$PLUGINS_FILE" ]]; then
    tf_args+=(-var-file "$PLUGINS_FILE")
  fi

  terraform init -upgrade
  terraform apply -auto-approve "${tf_args[@]}"

  popd >/dev/null
  log_ok "Terraform deployment complete"
}

init_and_unseal() {
  log_info "Waiting for OpenBao pod to be ready..."
  kubectl wait --namespace "$NAMESPACE" \
    --for=condition=ready \
    --selector="app.kubernetes.io/name=openbao,app.kubernetes.io/instance=$RELEASE_NAME" \
    --timeout=300s

  local pod="${RELEASE_NAME}-0"
  local init_file="/tmp/openbao-init-${NAMESPACE}.json"

  log_info "Initializing OpenBao..."
  if kubectl exec -n "$NAMESPACE" "$pod" -- bao status &>/dev/null; then
    log_warn "OpenBao is already initialized"
    return 0
  fi

  kubectl exec -n "$NAMESPACE" "$pod" -- \
    bao operator init -format=json -key-shares=5 -key-threshold=3 > "$init_file"

  if [[ ! -f "$init_file" ]]; then
    log_error "Failed to initialize OpenBao"
    exit 1
  fi
  log_ok "OpenBao initialized, keys saved to $init_file"

  log_info "Unsealing OpenBao..."
  local unseal_keys
  mapfile -t unseal_keys < <(jq -r '.unseal_keys_b64[:3][]' "$init_file")

  local pods
  if [[ "$MODE" == "ha" ]]; then
    pods=("${RELEASE_NAME}-0" "${RELEASE_NAME}-1" "${RELEASE_NAME}-2")
  else
    pods=("${RELEASE_NAME}-0")
  fi

  for pod in "${pods[@]}"; do
    for key in "${unseal_keys[@]}"; do
      kubectl exec -n "$NAMESPACE" "$pod" -- bao operator unseal "$key" &>/dev/null
    done
    log_ok "Unsealed pod: $pod"
  done

  local root_token
  root_token=$(jq -r '.root_token' "$init_file")
  log_info "Root token: $root_token"
  log_info "Root token saved to: $init_file"
  log_info "You can login with: kubectl exec -n $NAMESPACE $pod -- bao login $root_token"
}

install_plugins() {
  if [[ -z "$PLUGINS_FILE" ]]; then
    return 0
  fi

  log_info "Installing plugins from $PLUGINS_FILE..."

  local pod="${RELEASE_NAME}-0"
  local init_file="/tmp/openbao-init-${NAMESPACE}.json"
  local root_token
  root_token=$(jq -r '.root_token' "$init_file")

  while IFS='=' read -r plugin_name plugin_path; do
    [[ -z "$plugin_name" || "$plugin_name" == \#* ]] && continue
    log_info "Registering plugin: $plugin_name"

    kubectl exec -n "$NAMESPACE" "$pod" -- \
      sh -c "BAO_TOKEN=$root_token bao plugin register \
        -sha256=$(sha256sum "$plugin_path" | cut -d' ' -f1) \
        secret $plugin_name \
        $plugin_path" || log_warn "Plugin $plugin_name registration failed (may already exist)"
  done < <(yq eval '.plugins.extra | to_entries | .[] | .key + "=" + .value' "$PLUGINS_FILE" 2>/dev/null || true)

  log_ok "Plugin installation complete"
}

print_summary() {
  local init_file="/tmp/openbao-init-${NAMESPACE}.json"
  local root_token=""

  if [[ -f "$init_file" ]]; then
    root_token=$(jq -r '.root_token' "$init_file")
  fi

  cat <<EOF

${GREEN}========================================${NC}
${GREEN}  OpenBao Deployment Complete${NC}
${GREEN}========================================${NC}

  Mode:       $MODE
  Namespace:  $NAMESPACE
  Release:    $RELEASE_NAME

  Pod Status:
$(kubectl get pods --namespace "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME" 2>/dev/null | sed 's/^/    /')

  Services:
$(kubectl get svc --namespace "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME" 2>/dev/null | sed 's/^/    /')

  Access:
    Internal: http://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8200
    CLI:      kubectl exec -n ${NAMESPACE} -it ${RELEASE_NAME}-0 -- bao

  Management:
    Status:   kubectl exec -n ${NAMESPACE} ${RELEASE_NAME}-0 -- bao status
    Login:    kubectl exec -n ${NAMESPACE} ${RELEASE_NAME}-0 -- bao login ${root_token:+"<root-token>"}

EOF

  if [[ -n "$root_token" ]]; then
    log_info "Root token: $root_token"
    log_warn "Store this token and the unseal keys from $init_file securely!"
  fi
}

main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     OpenBao K8s Deployment Script    ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo ""

  check_prerequisites

  if $USE_TERRAFORM; then
    deploy_terraform
  else
    deploy_helm
  fi

  if $DO_INIT; then
    init_and_unseal
    install_plugins
    if $REGISTER_PLUGINS; then
      log_info "Registering community plugins..."
      "$SCRIPT_DIR/register-plugins.sh" --namespace "$NAMESPACE" --release "$RELEASE_NAME" 2>&1 || log_warn "Plugin registration incomplete"
    fi
  fi

  print_summary
}

main
