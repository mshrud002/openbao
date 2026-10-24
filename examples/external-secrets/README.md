# External Secrets Operator with OpenBao

1. Install External Secrets Operator
2. Configure Kubernetes auth role for `external-secrets` service account
3. Apply ClusterSecretStore pointing to OpenBao
4. Create ExternalSecret to sync secrets
5. Use the generated Kubernetes Secret in your apps
