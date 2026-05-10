terraform {
  required_version = ">= 1.5"
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

locals {
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
    var.values
  )
}

resource "kubernetes_namespace" "openbao" {
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

  depends_on = [kubernetes_namespace.openbao]

  dynamic "set" {
    for_each = local.helm_values
    content {
      name  = set.key
      value = set.value
    }
  }
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
