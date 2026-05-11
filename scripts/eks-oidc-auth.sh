#!/usr/bin/env bash
# Authenticate to AWS via GitHub OIDC, then configure kubectl for EKS.
# No marketplace actions required — uses only curl + aws CLI.
set -euo pipefail

usage() {
  cat <<EOF
Configure AWS EKS access via GitHub OIDC.

Usage: $0 [options]

Options:
  --role-arn ARN      AWS IAM role ARN to assume via OIDC (required)
  --cluster NAME      EKS cluster name (required)
  --region REGION     AWS region (default: eu-west-1)
  --audience AUD      STS audience (default: sts.amazonaws.com)
  --namespace NS      Kubernetes namespace (default: openbao)
  --helm-values FILE  Helm values file for deploy
  --install           Run helm install/upgrade after auth
  -h, --help          Show this help

Environment (set by GitHub Actions runner automatically):
  ACTIONS_ID_TOKEN_REQUEST_TOKEN
  ACTIONS_ID_TOKEN_REQUEST_URL

Examples:
  # Just configure kubectl
  $0 --role-arn arn:aws:iam::123456:role/github-oidc-openbao --cluster my-cluster

  # Deploy OpenBao
  $0 --role-arn arn:aws:iam::123456:role/github-oidc-openbao --cluster my-cluster --install
EOF
  exit 0
}

ROLE_ARN=""
CLUSTER_NAME=""
REGION="eu-west-1"
AUDIENCE="sts.amazonaws.com"
NAMESPACE="openbao"
HELM_VALUES=""
DO_INSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --role-arn)     ROLE_ARN="$2"; shift 2 ;;
    --cluster)      CLUSTER_NAME="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --audience)     AUDIENCE="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --helm-values)  HELM_VALUES="$2"; shift 2 ;;
    --install)      DO_INSTALL=true; shift ;;
    -h|--help)      usage ;;
    *)              echo "Unknown: $1"; usage ;;
  esac
done

if [[ -z "$ROLE_ARN" || -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: --role-arn and --cluster are required"
  usage
fi

# ------------------------------------------------------------------
# Step 1: Get the GitHub OIDC JWT token from the runner
# ------------------------------------------------------------------
echo "==> Requesting OIDC token from GitHub..."
if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo "ERROR: ACTIONS_ID_TOKEN_REQUEST_TOKEN and ACTIONS_ID_TOKEN_REQUEST_URL are not set."
  echo "  This script must run in a GitHub Actions runner with id-token: write permission."
  exit 1
fi

ID_TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}" | jq -r '.value')

if [[ -z "$ID_TOKEN" || "$ID_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to get OIDC token"
  exit 1
fi
echo "  OIDC token received (${#ID_TOKEN} chars)"

# Write token to temp file for AWS CLI
echo "$ID_TOKEN" > /tmp/oidc-token.jwt

# ------------------------------------------------------------------
# Step 2: Assume the IAM role via OIDC
# ------------------------------------------------------------------
echo "==> Assuming IAM role: $ROLE_ARN..."
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "$ROLE_ARN" \
  --role-session-name "github-oidc-${GITHUB_ACTOR:-deploy}" \
  --web-identity-token file:///tmp/oidc-token.jwt \
  --duration-seconds 3600 \
  --query 'Credentials' \
  --output json)

AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.SessionToken')

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_DEFAULT_REGION="$REGION"

echo "  Credentials obtained (expires in 3600s)"

# ------------------------------------------------------------------
# Step 3: Configure kubectl for EKS
# ------------------------------------------------------------------
echo "==> Configuring kubectl for EKS cluster: $CLUSTER_NAME..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "  kubectl configured. Testing connection..."
kubectl cluster-info --request-timeout=5s | head -3

# ------------------------------------------------------------------
# Step 4: Optional Helm deploy
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

# Unset credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
echo "==> Done"
