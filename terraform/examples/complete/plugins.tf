# Plugin registration using OpenBao provider
# Requires OpenBao to be initialized and unsealed first

provider "openbao" {
  address = module.openbao.openbao_addr_internal
  token   = var.openbao_token
}

variable "openbao_token" {
  description = "OpenBao token with permissions to enable secrets engines"
  type        = string
  sensitive   = true
}

variable "openbao_init_file" {
  description = "Path to the OpenBao init JSON output"
  type        = string
  default     = "openbao-init.json"
}

# Register a custom plugin
resource "openbao_plugin" "custom" {
  for_each = module.openbao.plugins

  name    = each.value.plugin_name
  type    = each.value.plugin_type
  version = each.value.plugin_version
  sha256  = each.value.sha256
  command = each.value.command
  env     = each.value.env
}

# Mount a custom secrets plugin as a secrets engine
resource "openbao_mount" "custom_plugin" {
  for_each = {
    for k, v in module.openbao.plugins : k => v
    if v.plugin_type == "secret"
  }

  path        = each.key
  type        = "plugin"
  plugin_name = each.value.plugin_name
  description = "Custom plugin: ${each.value.plugin_name}"
}
