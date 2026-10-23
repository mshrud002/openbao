# Tenant Read-Only Policy
path "{{namespace}}/data/*" {
  capabilities = ["read", "list"]
}

path "{{namespace}}/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
