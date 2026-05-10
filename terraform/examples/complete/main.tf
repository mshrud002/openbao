terraform {
  required_providers {
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

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

# ---------------------------------------------------------------------------
# In real deployments, the KMS key, IRSA role, and certificate ARN would be
# created by Terraform resources (aws_kms_key, aws_iam_role, etc.) and
# referenced here as outputs or data sources.
# ---------------------------------------------------------------------------

# data "aws_kms_key" "openbao" {
#   key_id = "alias/openbao-unseal"
# }
#
# data "aws_iam_role" "openbao_irsa" {
#   name = "openbao-kms-role"
# }

module "openbao" {
  source = "../../terraform"

  release_name     = "openbao"
  namespace        = "openbao"
  create_namespace  = true
  mode             = "ha"
  chart_path       = "../../helm/openbao"

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

  # Seal config — pass KMS key and IRSA role from Terraform resources
  seal = {
    type         = "awskms"
    region       = "eu-west-1"
    kms_key_id   = "alias/openbao-unseal"         # or aws_kms_key.openbao.key_id
    irsa_role_arn = "arn:aws:iam::123456789012:role/openbao-kms"  # or aws_iam_role.openbao_irsa.arn
  }

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
