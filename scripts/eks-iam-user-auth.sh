#!/usr/bin/env bash
# Authenticate to AWS via IAM user credentials, then configure kubectl for EKS.
# Use this when deploying with a long-lived IAM user instead of OIDC roles.
# Requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY to be set in the environment.
set -euo pipefail

usage() {
  cat <<EOF
Configure AWS EKS access using IAM user credentials.

Usage: $0 [options]

Options:
  --cluster NAME      EKS cluster name (required)
  --region REGION     AWS region (default: eu-west-1)
  --namespace NS      Kubernetes namespace (default: openbao)
  --helm-values FILE  Helm values file for deploy
  --install           Run helm install/upgrade after auth
  -h, --help          Show this help

Environment:
  AWS_ACCESS_KEY_ID       IAM user access key ID (required)
  AWS_SECRET_ACCESS_KEY   IAM user secret access key (required)

Examples:
  # Just configure kubectl
  AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... \\
    $0 --cluster my-cluster

  # Deploy OpenBao
  AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... \\
    $0 --cluster my-cluster --install

  # In GitHub Actions (secrets set automatically via env:)
  $0 --cluster my-cluster --namespace openbao-dev --install
EOF
  exit 0
}

CLUSTER_NAME=""
REGION="eu-west-1"
NAMESPACE="openbao"
HELM_VALUES=""
DO_INSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster)      CLUSTER_NAME="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --helm-values)  HELM_VALUES="$2"; shift 2 ;;
    --install)      DO_INSTALL=true; shift ;;
    -h|--help)      usage ;;
    *)              echo "Unknown: $1"; usage ;;
  esac
done

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: --cluster is required"
  usage
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "ERROR: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set."
  echo "  Set them as environment variables or CI/CD secrets before running this script."
  exit 1
fi

export AWS_DEFAULT_REGION="$REGION"

echo "==> IAM user configured (access key ID: ${AWS_ACCESS_KEY_ID:0:4}...)"

# ------------------------------------------------------------------
# Step 1: Configure kubectl for EKS
# ------------------------------------------------------------------
echo "==> Configuring kubectl for EKS cluster: $CLUSTER_NAME..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "  kubectl configured. Testing connection..."
kubectl cluster-info --request-timeout=5s | head -3

# ------------------------------------------------------------------
# Step 2: Optional Helm deploy
# ------------------------------------------------------------------
if $DO_INSTALL; then
  echo "==> Deploying OpenBao via Helm..."
  CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/openbao" && pwd)"

  HELM_ARGS=(
    --namespace "$NAMESPACE"
    --create-namespace
    --wait
    --timeout 10m
  )

  if [[ -n "$HELM_VALUES" ]]; then
    HELM_ARGS+=(-f "$HELM_VALUES")
  fi

  if helm status openbao --namespace "$NAMESPACE" &>/dev/null; then
    echo "  Upgrading existing release..."
    helm upgrade openbao "$CHART_DIR" "${HELM_ARGS[@]}"
  else
    echo "  Installing new release..."
    helm install openbao "$CHART_DIR" "${HELM_ARGS[@]}"
  fi

  echo "  OpenBao deployed successfully."
fi

echo "==> Done"
