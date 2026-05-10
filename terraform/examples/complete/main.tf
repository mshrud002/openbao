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

  release_name    = "openbao"
  namespace       = "openbao"
  create_namespace = true
  mode            = "ha"
  chart_path      = "../../helm/openbao"

  ingress_enabled = false
  ingress_config = {
    host = "openbao.example.com"
  }

  values = {
    server = {
      image = {
        registry   = "quay.io"
        repository = "openbao/openbao"
        tag        = "v2.5.2"
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
      ha = {
        raft = {
          config = <<-EOF
            ui = true
            listener "tcp" {
              tls_disable = 1
              address = "[::]:8200"
              cluster_address = "[::]:8201"
            }
            storage "raft" {
              path = "/openbao/data"
              node_id = "openbao-{{ ansible_hostname }}"
            }
            service_registration "kubernetes" {}
          EOF
        }
      }
    }
  }

  plugins = {
    example-plugin = {
      plugin_name    = "my-custom-plugin"
      plugin_type    = "secret"
      sha256         = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
    }
  }
}

output "openbao_service" {
  value = module.openbao.service_name
}

output "openbao_addr" {
  value = module.openbao.openbao_addr_internal
}
