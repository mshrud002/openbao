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
    host        = optional(string, "bao.example.com")
    annotations = optional(map(string), {})
    tls_enabled = optional(bool, false)
    tls_secret  = optional(string, "")
  })
  default = {}
}

variable "create_irsa_resources" {
  description = "Create KMS key and IAM role for IRSA auto-unseal"
  type        = bool
  default     = false
}

variable "eks_cluster_name" {
  description = "EKS cluster name (required when create_irsa_resources = true)"
  type        = string
  default     = ""
}

variable "kms_key_deletion_window_in_days" {
  description = "KMS key deletion window (7-30 days)"
  type        = number
  default     = 7
  validation {
    condition     = var.kms_key_deletion_window_in_days >= 7 && var.kms_key_deletion_window_in_days <= 30
    error_message = "KMS key deletion window must be between 7 and 30 days."
  }
}

variable "seal" {
  description = "KMS auto-unseal configuration (not needed when create_irsa_resources = true)"
  type = object({
    type         = optional(string, "awskms")
    region       = optional(string, "")
    kms_key_id   = optional(string, "")
    endpoint     = optional(string, "")
    irsa_role_arn = optional(string, "")
  })
  default = {}
}

variable "service_account_annotations" {
  description = "Additional annotations for the OpenBao service account (e.g. IRSA)"
  type        = map(string)
  default     = {}
}

variable "iam_user_access_key_id" {
  description = "AWS IAM user access key ID for pod-level AWS access (alternative to IRSA)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "iam_user_secret_access_key" {
  description = "AWS IAM user secret access key for pod-level AWS access (alternative to IRSA)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "create_iam_user_k8s_secret" {
  description = "Create a Kubernetes secret with IAM user credentials for pod-level AWS access"
  type        = bool
  default     = false
}
