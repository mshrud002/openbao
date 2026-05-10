output "namespace" {
  description = "Kubernetes namespace where OpenBao is deployed"
  value       = var.namespace
}

output "helm_release_name" {
  description = "Helm release name"
  value       = helm_release.openbao.name
}

output "helm_chart" {
  description = "Helm chart used"
  value       = helm_release.openbao.chart
}

output "helm_version" {
  description = "Helm chart version deployed"
  value       = helm_release.openbao.version
}

output "service_name" {
  description = "Kubernetes service name for OpenBao"
  value       = "${var.helm_release_name}.${var.namespace}.svc.cluster.local"
}

output "openbao_addr_internal" {
  description = "Internal cluster address for OpenBao"
  value       = "http://${var.helm_release_name}.${var.namespace}.svc.cluster.local:8200"
}

output "openbao_addr_external" {
  description = "External address for OpenBao (if ingress enabled)"
  value       = var.ingress_enabled ? "https://${var.ingress_config.host}" : null
}

output "seal_config" {
  description = "KMS seal configuration (sensitive values redacted)"
  value = var.seal.kms_key_id != "" ? {
    type     = var.seal.type
    region   = var.seal.region
    kms_key_id = var.seal.kms_key_id
  } : null
}

output "irsa_role_arn" {
  description = "IRSA role ARN for the OpenBao service account"
  value       = var.seal.irsa_role_arn
}

output "openbao_status" {
  description = "Status command for the OpenBao deployment"
  value       = "kubectl exec -n ${var.namespace} ${var.helm_release_name}-0 -- bao status"
}

output "init_command" {
  description = "Command to initialize OpenBao"
  value       = "kubectl exec -n ${var.namespace} ${var.helm_release_name}-0 -- bao operator init -format=json > openbao-init.json"
}

output "unseal_command" {
  description = "Command to unseal OpenBao"
  value       = "for i in $(seq 0 $((${var.mode == "ha" ? 2 : 0}))); do kubectl exec -n ${var.namespace} ${var.helm_release_name}-\"$i\" -- bao operator unseal \"$(cat openbao-init.json | jq -r '.unseal_keys_b64[0]')\"; done"
}
