variable "helm_release_name" {
  description = "Name of the Helm release"
  type        = string
  default     = "openbao"
}

variable "namespace" {
  description = "Kubernetes namespace to deploy into"
  type        = string
  default     = "openbao"
}

variable "create_namespace" {
  description = "Create the Kubernetes namespace"
  type        = bool
  default     = true
}

variable "chart_version" {
  description = "Version of the OpenBao Helm chart"
  type        = string
  default     = null
}

variable "chart_path" {
  description = "Path to the Helm chart (overrides chart repo)"
  type        = string
  default     = "../helm/openbao"
}

variable "values" {
  description = "Additional values to pass to the Helm chart"
  type        = any
  default     = {}
}

variable "mode" {
  description = "OpenBao server mode: dev, standalone, or ha"
  type        = string
  default     = "standalone"
  validation {
    condition     = contains(["dev", "standalone", "ha"], var.mode)
    error_message = "Mode must be one of: dev, standalone, ha"
  }
}

variable "openbao_addr" {
  description = "Address of the OpenBao server for provider configuration"
  type        = string
  default     = ""
}

variable "openbao_token" {
  description = "Token for OpenBao provider authentication"
  type        = string
  default     = ""
  sensitive   = true
}

variable "plugins" {
  description = "Map of plugins to register in OpenBao"
  type = map(object({
    plugin_name    = string
    plugin_type    = optional(string, "secret")
    plugin_version = optional(string, "v1")
    sha256         = string
    command        = optional(string)
    env            = optional(list(string))
  }))
  default = {}
}

variable "configure_openbao" {
  description = "Whether to configure OpenBao after deployment (requires init/unseal)"
  type        = bool
  default     = false
}

variable "ingress_enabled" {
  description = "Enable ingress for OpenBao"
  type        = bool
  default     = false
}

variable "ingress_config" {
  description = "Ingress configuration"
  type = object({
    host        = optional(string, "openbao.local")
    annotations = optional(map(string), {})
    tls_enabled = optional(bool, false)
    tls_secret  = optional(string, "")
  })
  default = {}
}
