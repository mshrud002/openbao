terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25"
    }
  }
}

data "aws_caller_identity" "current" {
  count = var.create_irsa_resources ? 1 : 0
}

data "aws_region" "current" {
  count = var.create_irsa_resources ? 1 : 0
}

data "aws_eks_cluster" "this" {
  count = var.create_irsa_resources ? 1 : 0
  name  = var.eks_cluster_name
}

locals {
  oidc_issuer_url = try(
    replace(data.aws_eks_cluster.this[0].identity[0].oidc[0].issuer, "https://", ""),
    ""
  )

  kms_key_id    = var.create_irsa_resources ? aws_kms_key.openbao[0].key_id : var.seal.kms_key_id
  irsa_role_arn = var.create_irsa_resources ? aws_iam_role.openbao_irsa[0].arn : var.seal.irsa_role_arn
  seal_region   = var.create_irsa_resources ? data.aws_region.current[0].name : var.seal.region

  use_iam_user_k8s_secret = var.create_iam_user_k8s_secret && var.iam_user_access_key_id != "" && var.iam_user_secret_access_key != ""

  iam_user_extra_env_vars = local.use_iam_user_k8s_secret ? {
    seal = {
      extraEnvironmentVars = [
        {
          name = "AWS_ACCESS_KEY_ID"
          valueFrom = {
            secretKeyRef = {
              name = "${var.helm_release_name}-aws-creds"
              key  = "access-key-id"
            }
          }
        },
        {
          name = "AWS_SECRET_ACCESS_KEY"
          valueFrom = {
            secretKeyRef = {
              name = "${var.helm_release_name}-aws-creds"
              key  = "secret-access-key"
            }
          }
        }
      ]
    }
  } : {}

  seal_values = local.kms_key_id != "" ? {
    seal = {
      awskms = {
        enabled     = true
        region      = local.seal_region
        kms_key_id  = local.kms_key_id
        endpoint    = var.seal.endpoint
        irsaRoleArn = local.use_iam_user_k8s_secret ? "" : local.irsa_role_arn
      }
    }
  } : {}

  helm_values = merge(
    {
      global = {
        namespace = var.namespace
      }
      server = {
        dev         = { enabled = var.mode == "dev" }
        standalone  = { enabled = var.mode == "standalone" }
        ha          = { enabled = var.mode == "ha" }
        replicas    = var.mode == "ha" ? 3 : 1
      }
    },
    local.seal_values,
    local.iam_user_extra_env_vars,
    var.values
  )
}

resource "aws_kms_key" "openbao" {
  count                   = var.create_irsa_resources ? 1 : 0
  description             = "OpenBao auto-unseal key - ${var.helm_release_name}"
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  enable_key_rotation     = true
  tags = {
    Name        = "${var.helm_release_name}-unseal"
    Environment = var.namespace
    ManagedBy   = "terraform"
  }
}

resource "aws_kms_alias" "openbao" {
  count         = var.create_irsa_resources ? 1 : 0
  name          = "alias/${var.helm_release_name}-unseal"
  target_key_id = aws_kms_key.openbao[0].key_id
}

resource "aws_iam_role" "openbao_irsa" {
  count = var.create_irsa_resources ? 1 : 0
  name  = "${var.helm_release_name}-irsa-${var.namespace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current[0].account_id}:oidc-provider/${local.oidc_issuer_url}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_issuer_url}:sub" = "system:serviceaccount:${var.namespace}:${var.helm_release_name}"
            "${local.oidc_issuer_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.helm_release_name}-irsa-${var.namespace}"
    Environment = var.namespace
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy" "openbao_kms_access" {
  count = var.create_irsa_resources ? 1 : 0
  name  = "${var.helm_release_name}-kms-access"
  role  = aws_iam_role.openbao_irsa[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.openbao[0].arn
      }
    ]
  })
}

resource "kubernetes_secret_v1" "aws_creds" {
  count = local.use_iam_user_k8s_secret ? 1 : 0
  metadata {
    name      = "${var.helm_release_name}-aws-creds"
    namespace = var.namespace
    labels = {
      app     = "openbao"
      managed = "terraform"
    }
  }
  data = {
    "access-key-id"     = var.iam_user_access_key_id
    "secret-access-key" = var.iam_user_secret_access_key
  }
  type = "Opaque"
}

resource "kubernetes_namespace_v1" "openbao" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name = var.namespace
    labels = {
      name    = var.namespace
      app     = "openbao"
      managed = "terraform"
    }
  }
}

resource "helm_release" "openbao" {
  name       = var.helm_release_name
  namespace  = var.namespace
  chart      = var.chart_path
  version    = var.chart_version
  skip_crds  = false
  wait       = true
  timeout    = 600

  depends_on = [
    kubernetes_namespace_v1.openbao,
    kubernetes_secret_v1.aws_creds
  ]

  values = [yamlencode(local.helm_values)]
}

data "kubernetes_service" "openbao" {
  metadata {
    name      = var.helm_release_name
    namespace = var.namespace
  }
  depends_on = [helm_release.openbao]
}

resource "kubernetes_ingress_v1" "openbao" {
  count = var.ingress_enabled ? 1 : 0
  metadata {
    name        = "${var.helm_release_name}-ingress"
    namespace   = var.namespace
    annotations = var.ingress_config.annotations
  }
  spec {
    dynamic "tls" {
      for_each = var.ingress_config.tls_enabled ? [1] : []
      content {
        hosts       = [var.ingress_config.host]
        secret_name = var.ingress_config.tls_secret
      }
    }
    rule {
      host = var.ingress_config.host
      http {
        path {
          path     = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.helm_release_name
              port {
                number = 8200
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.openbao]
}
