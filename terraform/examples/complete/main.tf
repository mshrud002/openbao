terraform {
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
    openbao = {
      source  = "openbao/openbao"
      version = ">= 0.1.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

module "openbao" {
  source = "../../terraform"

  release_name     = "openbao"
  namespace        = "openbao"
  create_namespace  = true
  mode             = "ha"
  chart_path       = "../../helm/openbao"

  create_irsa_resources = true
  eks_cluster_name      = "my-eks-cluster"

  ingress_enabled = false
  ingress_config = {
    host = "bao.example.com"
    annotations = {
      # For internet-facing:
      # "alb.ingress.kubernetes.io/scheme" = "internet-facing"
      # For corporate/internal:
      # "alb.ingress.kubernetes.io/scheme" = "internal"
    }
  }

  # Seal config is auto-provisioned when create_irsa_resources = true.
  # Omit seal block entirely — KMS key and IRSA role are created by the module.
  # For BYO key/role, set create_irsa_resources = false and pass:
  # seal = {
  #   type         = "awskms"
  #   region       = "eu-west-1"
  #   kms_key_id   = aws_kms_key.existing.key_id
  #   irsa_role_arn = aws_iam_role.existing.arn
  # }

  # Additional Helm values (overrides)
  values = {
    server = {
      image = {
        tag = "v2.5.2"
      }
      resources = {
        requests = {
          memory = "512Mi"
          cpu    = "500m"
        }
        limits = {
          memory = "1Gi"
          cpu    = "1"
        }
      }
    }
    plugins = {
      community = {
        enabled = true
        auth = {
          aws   = { enabled = true }
          azure = { enabled = true }
          gcp   = { enabled = true }
        }
        secrets = {
          aws   = { enabled = true }
          azure = { enabled = true }
          gcp   = { enabled = true }
          nomad = { enabled = true }
          consul = { enabled = true }
        }
      }
    }
    monitoring = {
      serviceMonitor = {
        enabled = true
      }
    }
  }
}

output "openbao_service" {
  value = module.openbao.service_name
}

output "openbao_addr" {
  value = module.openbao.openbao_addr_internal
}

output "kms_key_arn" {
  value = module.openbao.kms_key_arn
}

output "irsa_role_arn" {
  value = module.openbao.irsa_role_arn
}
