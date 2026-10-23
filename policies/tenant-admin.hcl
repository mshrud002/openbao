# Tenant Admin Policy
# Grants full access within tenant namespace/path
path "{{namespace}}/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/mounts/{{namespace}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/token/create" {
  capabilities = ["create", "update"]
}

path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
