# Tenant Developer Policy
# Limited write access for developers
path "{{namespace}}/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "{{namespace}}/metadata/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
