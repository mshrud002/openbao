# Setup GitHub OIDC provider and IAM role for CI/CD via GitHub Actions.
# Apply this once per AWS account before running the deploy-eks workflow.
#
# Usage:
#   terraform init
#   terraform apply -var="github_repo=mshrud002/openbao" -var="cluster_name=my-eks-cluster"
#
# After apply, add the OIDC_ROLE_ARN output as a GitHub Actions secret
# named OIDC_ROLE_ARN (per environment).
#
# Alternative: IAM user for CI/CD
#   Instead of OIDC, you can use a long-lived IAM user:
#   1. Create an IAM user with eks:DescribeCluster permission
#   2. Add AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY as GitHub Actions secrets
#   3. Use scripts/eks-iam-user-auth.sh in the deploy workflow

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "github_repo" {
  description = "GitHub repository in org/repo format (e.g. mshrud002/openbao)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name to grant access to"
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# GitHub OIDC provider (create once per account)
# ---------------------------------------------------------------------------
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------------------------
# IAM role that GitHub Actions will assume via OIDC
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "github_oidc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Restrict to main branch on this repo
      values = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_oidc" {
  name               = "github-oidc-${var.environment}-openbao"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json

  tags = {
    Name        = "github-oidc-${var.environment}-openbao"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Permissions: EKS access + KMS decrypt for auto-unseal
# ---------------------------------------------------------------------------
data "aws_eks_cluster" "target" {
  name = var.cluster_name
}

resource "aws_iam_role_policy" "eks_access" {
  name   = "eks-access-${var.environment}"
  role   = aws_iam_role.github_oidc.name
  policy = data.aws_iam_policy_document.eks_access.json
}

data "aws_iam_policy_document" "eks_access" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [data.aws_eks_cluster.target.arn]
  }
}

# Grant access to KMS key for auto-unseal (if using awskms)
# Uncomment and set kms_key_arn variable to use:
# resource "aws_iam_role_policy" "kms_access" {
#   name   = "kms-unseal-${var.environment}"
#   role   = aws_iam_role.github_oidc.name
#   policy = data.aws_iam_policy_document.kms_access.json
# }
#
# data "aws_iam_policy_document" "kms_access" {
#   statement {
#     effect    = "Allow"
#     actions   = ["kms:Decrypt", "kms:Encrypt", "kms:DescribeKey"]
#     resources = [var.kms_key_arn]
#   }
# }

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "oidc_role_arn" {
  description = "IAM role ARN for GitHub Actions (store as GHA secret: OIDC_ROLE_ARN)"
  value       = aws_iam_role.github_oidc.arn
}

output "oidc_role_name" {
  description = "IAM role name for GitHub Actions"
  value       = aws_iam_role.github_oidc.name
}
