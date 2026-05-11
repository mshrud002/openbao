# OpenBao Kubernetes Deployment

Deploy [OpenBao](https://openbao.org) on Kubernetes with plugin support, using Helm charts, Terraform, and bash scripts.

Includes the full suite of [openbao-plugins](https://github.com/openbao/openbao-plugins) (auth: AWS, Azure, GCP, GitHub; secrets: AWS, Azure, GCP, GCPKMS, Nomad, Consul) and KMS auto-unseal.

## Project Structure

```
├── helm/openbao/              # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── configmap.yaml      # HCL config with tpl rendering + dynamic retry_join
│       ├── statefulset.yaml    # StatefulSet with plugin init/download containers
│       ├── service.yaml        # Client service + headless internal service
│       ├── ingress.yaml        # ALB-compatible ingress
│       ├── injector-deployment.yaml  # Agent injector
│       ├── serviceaccount.yaml # IRSA annotation support
│       ├── ui-service.yaml
│       ├── pdb.yaml
│       └── plugin-configmap.yaml
├── terraform/                  # Terraform module
│   ├── main.tf / variables.tf / outputs.tf
│   └── examples/complete/      # Complete example with Terraform
├── scripts/
│   ├── deploy.sh               # Full deployment workflow
│   ├── eks-oidc-auth.sh        # GitHub OIDC → AWS STS auth (CI/CD)
│   ├── eks-iam-user-auth.sh    # IAM user credentials auth (CI/CD)
│   ├── init-and-unseal.sh      # Initialize & unseal cluster
│   ├── install-plugin.sh       # Runtime plugin installation
│   └── register-plugins.sh     # Register community plugins
└── README.md
```

## Architecture

### Deployment Pipeline (GitHub Actions → AWS EKS)

Two authentication methods are supported:

| Method | Credentials | Best for |
|--------|-------------|----------|
| **OIDC** (default) | Short-lived tokens via `sts:AssumeRoleWithWebIdentity` | Teams with GitHub OIDC provider configured |
| **IAM User** | Long-lived access keys stored as GitHub secrets | Quick setup, BYO IAM user, no OIDC setup |

#### Option 1: OIDC (GitHub Actions → AWS STS)

```mermaid
flowchart TD
    subgraph "GitHub"
        GHA["GitHub Actions Runner"] -->|"OIDC JWT"| OIDC["token.actions.githubusercontent.com"]
        OIDC -->|"ACTIONS_ID_TOKEN_REQUEST_TOKEN"| GHA
        GHA -->|"aws sts assume-role-with-web-identity"| AWS_STS["AWS STS"]
    end
    subgraph "AWS Account"
        AWS_STS -->|"temp credentials"| EKS["Amazon EKS"]
        IAM_ROLE["IAM Role<br/>github-oidc-{env}-openbao"] -->|"eks:DescribeCluster"| EKS
    end
    subgraph "Kubernetes"
        EKS -->|"helm install/upgrade"| HELM["Helm Release: openbao"]
        HELM --> PODS["OpenBao StatefulSet"]
    end
    GHA -->|"OIDC_ROLE_ARN"| IAM_ROLE
```

#### Option 2: IAM User (long-lived access keys)

```mermaid
flowchart TD
    subgraph "GitHub"
        GHA["GitHub Actions Runner"]
        GHA -->|"AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"| AWS["AWS APIs"]
    end
    subgraph "AWS Account"
        AWS -->|"eks:DescribeCluster"| EKS["Amazon EKS"]
        IAM_USER["IAM User<br/>(BYO)"] -->|"eks:DescribeCluster"| EKS
    end
    subgraph "Kubernetes"
        EKS -->|"helm install/upgrade"| HELM["Helm Release: openbao"]
        HELM --> PODS["OpenBao StatefulSet"]
    end
```

**Required GitHub secrets:**
- `AWS_ACCESS_KEY_ID` — IAM user access key ID
- `AWS_SECRET_ACCESS_KEY` — IAM user secret access key
- `EKS_CLUSTER_NAME` — target EKS cluster name

### Kubernetes Resources

```mermaid
flowchart TD
    HELM_RELEASE["Helm Release<br/>openbao"] --> SA["ServiceAccount<br/>openbao"]
    HELM_RELEASE --> CM["ConfigMap<br/>openbao-config"]
    HELM_RELEASE --> STS["StatefulSet<br/>openbao"]
    HELM_RELEASE --> SVC["Service<br/>openbao:8200"]
    HELM_RELEASE --> SVC_INT["Service (Headless)<br/>openbao-internal"]
    HELM_RELEASE --> INGRESS["Ingress (optional)"]
    HELM_RELEASE --> SVC_MON["ServiceMonitor (optional)"]
    HELM_RELEASE --> INJECTOR["Agent Injector (optional)"]

    subgraph "Pod (openbao-N)"
        INIT_PLUGIN["initContainer: plugin-download"] --> MAIN["main: bao server"]
        INIT_COPY["initContainer: plugin-copy"] --> MAIN
        INIT_IMG["initContainer: plugin-image (opt)"] --> MAIN
        MAIN --> VOL_DATA["PVC: /openbao/data"]
        MAIN --> VOL_AUDIT["PVC: /vault/logs"]
        MAIN --> VOL_PLUGINS["emptyDir: /vault/plugins"]
    end

    SA -.->|"IRSA annotation"| MAIN
    CM -.->|"openbao.hcl"| MAIN
```

### Network Flow

```mermaid
flowchart LR
    USER["User<br/>HTTPS"] --> INGRESS["AWS ALB / NGINX<br/>Ingress"]
    INGRESS -->|"host: bao.example.com"| SVC["Service: openbao<br/>ClusterIP :8200"]
    SVC --> POD0["Pod: openbao-0<br/>:8200 API + UI"]
    SVC --> POD1["Pod: openbao-1<br/>:8200 API + UI"]
    SVC --> POD2["Pod: openbao-2<br/>:8200 API + UI"]
    SVC_INT["Service: openbao-internal<br/>(headless)"] -->|"Raft gossip :8201"| POD0
    SVC_INT -->|"Raft gossip :8201"| POD1
    SVC_INT -->|"Raft gossip :8201"| POD2
    POD0 -->|"retry_join"| POD1
    POD1 -->|"retry_join"| POD2
```

### KMS Auto-Unseal

Auto-unseal requires AWS credentials with `kms:Decrypt`/`kms:Encrypt`/`kms:DescribeKey` permissions on the KMS key. Two approaches are supported:

| Method | How it works | When to use |
|--------|-------------|-------------|
| **IRSA** (default) | IAM role annotated on ServiceAccount | EKS clusters with OIDC provider |
| **IAM User** | Access keys injected via Kubernetes secret | Non-EKS clusters, BYO credentials |

#### Option A: IRSA (IAM Roles for Service Accounts)

```mermaid
flowchart TD
    subgraph "AWS"
        KMS_KEY["AWS KMS Key"] -->|"kms:Decrypt / Encrypt"| IRSA_ROLE["IAM Role (IRSA)"]
    end
    subgraph "Kubernetes / EKS"
        SA["ServiceAccount<br/>openbao"] -->|"annotation: role-arn"| IRSA_ROLE
        POD["OpenBao Pod"] -->|"mounts SA"| SA
    end
    subgraph "OpenBao"
        CONFIG["openbao.hcl<br/>seal 'awskms'"] -->|"reads seal stanza"| BAO_SERVER["bao server"]
        BAO_SERVER -->|"kms:Decrypt"| KMS_KEY
        BAO_SERVER -->|"auto-unsealed"| READY["Ready for traffic"]
    end
    POD --> CONFIG
```

#### Option B: IAM User (via K8s secret)

```mermaid
flowchart TD
    subgraph "AWS"
        KMS_KEY["AWS KMS Key"]
    end
    subgraph "Kubernetes"
        SECRET["K8s Secret<br/>openbao-aws-creds"] -->|"AWS_ACCESS_KEY_ID /<br/>AWS_SECRET_ACCESS_KEY"| POD["OpenBao Pod"]
    end
    subgraph "OpenBao"
        CONFIG["openbao.hcl<br/>seal 'awskms'"] -->|"reads seal stanza"| BAO_SERVER["bao server"]
        BAO_SERVER -->|"kms:Decrypt"| KMS_KEY
        BAO_SERVER -->|"auto-unsealed"| READY["Ready for traffic"]
    end
    POD --> CONFIG
```

### Plugin System

```mermaid
flowchart TD
    subgraph "initContainers"
        COMMUNITY["plugin-download<br/>curlimages/curl"] -->|"curl GitHub releases"| ARCHIVES["openbao-plugins/releases"]
        ARCHIVES -->|"extract .tar.gz"| PLUGIN_DIR["/vault/plugins/ (emptyDir)"]
        CONFIGMAP["plugin-copy"] -->|"copy from ConfigMap"| PLUGIN_DIR
        SIDECAR["plugin-image"] -->|"copy from image"| PLUGIN_DIR
    end
    subgraph "Post-Deploy"
        PLUGIN_DIR --> REGISTER["register-plugins.sh"]
        REGISTER -->|"bao plugin register"| PLUGIN_REG["Plugin Registered"]
        PLUGIN_REG -->|"bao auth / secrets enable"| PLUGIN_MOUNTED["Plugin Active"]
    end
```

### Init & Unseal Flow

```mermaid
flowchart TD
    DEPLOY["Helm install done"] --> WAIT["Wait pod ready"]
    WAIT --> CHECK{"Already initialized?"}
    CHECK -->|"No"| INIT["bao operator init<br/>5 keys, threshold 3"]
    CHECK -->|"Yes"| DONE["Done"]
    INIT --> KEYS["openbao-init-{ns}.json"]
    KEYS --> UNSEAL["For each pod:<br/>bao operator unseal x3"]
    UNSEAL --> VERIFY["Verify unsealed"]
    VERIFY --> READY["OpenBao Ready"]
```

## Quick Start

### Prerequisites
- Kubernetes cluster (>= 1.27)
- Helm 3.6+ / kubectl
- (optional) Terraform 1.5+

### Deploy HA with all community plugins + auto-unseal

```bash
# One-command deploy with community plugins, init, unseal, and registration
./scripts/deploy.sh --mode ha --namespace openbao \
  --community-plugins \
  --init \
  --register-plugins
```

### Deploy with Helm

```bash
helm install openbao ./helm/openbao \
  --namespace openbao --create-namespace \
  --set server.ha.enabled=true \
  --set server.standalone.enabled=false \
  --set plugins.community.enabled=true \
  --set plugins.community.auth.aws.enabled=true \
  --set plugins.community.secrets.aws.enabled=true
```

## Community Plugins (openbao-plugins)

The chart can automatically download and install plugins from [openbao/openbao-plugins](https://github.com/openbao/openbao-plugins) at pod startup.

### Available Plugins

| Type    | Plugin  | Description |
|---------|---------|-------------|
| auth    | aws     | Authenticate using AWS IAM credentials |
| auth    | azure   | Authenticate using Azure credentials |
| auth    | gcp     | Authenticate using GCP credentials |
| auth    | github  | Authenticate using GitHub credentials |
| secret  | aws     | Generate AWS access credentials |
| secret  | azure   | Generate Azure service principals |
| secret  | gcp     | Generate GCP service account keys |
| secret  | gcpkms  | Encrypt data via GCP KMS |
| secret  | nomad   | Generate Nomad ACL tokens |
| secret  | consul  | Generate Consul ACL tokens |

### Enable in values.yaml

```yaml
plugins:
  community:
    enabled: true
    auth:
      aws:   { enabled: true, version: v0.1.1 }
      azure: { enabled: true, version: v0.23.0 }
      gcp:   { enabled: true, version: v0.22.0 }
      github:{ enabled: true, version: v0.0.1 }
    secrets:
      aws:   { enabled: true, version: v0.2.0 }
      azure: { enabled: true, version: v0.23.0 }
      gcp:   { enabled: true, version: v0.23.0 }
      gcpkms:{ enabled: true, version: v0.21.0 }
      nomad: { enabled: true, version: v0.1.5 }
      consul:{ enabled: true, version: v0.1.0 }
```

An init container downloads the plugin tarballs from GitHub Releases, extracts them to `/vault/plugins/`, and makes them available to OpenBao at startup.

### Register & Enable After Init

```bash
./scripts/register-plugins.sh --namespace openbao

# Selective registration
./scripts/register-plugins.sh --namespace openbao \
  --auth-plugins aws,azure \
  --secrets-plugins aws,consul
```

## Configuration: Terraform-Driven, No Hardcoded Values

The chart defaults are intentionally empty — no hardcoded regions, KMS keys, or IRSA roles.
All environment-specific values should be injected by Terraform or your config management.

### Recommended: Terraform injects KMS + IRSA

```hcl
module "openbao" {
  source = "../../terraform"

  seal = {
    type         = "awskms"
    region       = "eu-west-1"
    kms_key_id   = aws_kms_key.openbao.key_id
    irsa_role_arn = aws_iam_role.openbao_irsa.arn
  }

  values = {
    seal = {
      awskms = {
        enabled     = true
        region      = "eu-west-1"
        kms_key_id  = "alias/openbao-unseal"
        irsaRoleArn = "arn:aws:iam::123456789012:role/openbao-kms"
      }
    }
  }
}
```

### Helm only (manual)

```bash
# IRSA approach
helm install openbao ./helm/openbao \
  --set seal.awskms.enabled=true \
  --set seal.awskms.region=eu-west-1 \
  --set seal.awskms.kms_key_id=alias/openbao-unseal \
  --set seal.awskms.irsaRoleArn=arn:aws:iam::123456789012:role/openbao-kms

# IAM User approach (via K8s secret)
helm install openbao ./helm/openbao \
  --set seal.awskms.enabled=true \
  --set seal.awskms.region=eu-west-1 \
  --set seal.awskms.kms_key_id=alias/openbao-unseal \
  --set 'seal.extraEnvironmentVars[0].name=AWS_ACCESS_KEY_ID' \
  --set 'seal.extraEnvironmentVars[0].valueFrom.secretKeyRef.name=openbao-aws-creds' \
  --set 'seal.extraEnvironmentVars[0].valueFrom.secretKeyRef.key=access-key-id' \
  --set 'seal.extraEnvironmentVars[1].name=AWS_SECRET_ACCESS_KEY' \
  --set 'seal.extraEnvironmentVars[1].valueFrom.secretKeyRef.name=openbao-aws-creds' \
  --set 'seal.extraEnvironmentVars[1].valueFrom.secretKeyRef.key=secret-access-key'
```

### IRSA (default)

When `seal.awskms.irsaRoleArn` is set, the chart adds `eks.amazonaws.com/role-arn` to the ServiceAccount.

```bash
helm install openbao ./helm/openbao \
  --set seal.awskms.enabled=true \
  --set seal.awskms.region=eu-west-1 \
  --set seal.awskms.kms_key_id=alias/openbao-unseal \
  --set seal.awskms.irsaRoleArn=arn:aws:iam::123456789012:role/openbao-kms
```

### IAM User (alternative to IRSA)

Replace IRSA with a Kubernetes secret containing IAM user credentials:

```bash
# Create the K8s secret with IAM user credentials
kubectl create secret generic openbao-aws-creds \
  --from-literal=access-key-id=AKIA... \
  --from-literal=secret-access-key=...

# Deploy with extraEnvironmentVars referencing the secret
helm install openbao ./helm/openbao \
  --set seal.awskms.enabled=true \
  --set seal.awskms.region=eu-west-1 \
  --set seal.awskms.kms_key_id=alias/openbao-unseal \
  --set 'seal.extraEnvironmentVars[0].name=AWS_ACCESS_KEY_ID' \
  --set 'seal.extraEnvironmentVars[0].valueFrom.secretKeyRef.name=openbao-aws-creds' \
  --set 'seal.extraEnvironmentVars[0].valueFrom.secretKeyRef.key=access-key-id' \
  --set 'seal.extraEnvironmentVars[1].name=AWS_SECRET_ACCESS_KEY' \
  --set 'seal.extraEnvironmentVars[1].valueFrom.secretKeyRef.name=openbao-aws-creds' \
  --set 'seal.extraEnvironmentVars[1].valueFrom.secretKeyRef.key=secret-access-key'
```

Or via the Terraform module (see `terraform/examples/complete/terraform.tfvars.example`):

```hcl
create_irsa_resources      = false
create_iam_user_k8s_secret = true
iam_user_access_key_id     = var.iam_user_access_key_id        # sensitive
iam_user_secret_access_key = var.iam_user_secret_access_key    # sensitive
seal = {
  type       = "awskms"
  region     = "eu-west-1"
  kms_key_id = aws_kms_key.existing.key_id
}
```

## Deployment Modes

| Mode         | Replicas | Storage  | HA  | Use Case              |
|--------------|----------|----------|-----|-----------------------|
| `dev`        | 1        | in-memory| No  | Local testing         |
| `standalone` | 1        | file     | No  | Dev/small workloads   |
| `ha`         | 3        | raft     | Yes | Production            |

## HA Raft Configuration

The HA mode generates dynamic `retry_join` blocks based on `server.ha.replicas`:

```hcl
storage "raft" {
  path = "/openbao/data"
  node_id = "NODE_ID_PLACEHOLDER"  # replaced with pod name at startup
  retry_join {
    leader_api_addr = "http://openbao-0.openbao-internal:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-1.openbao-internal:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-2.openbao-internal:8200"
  }
}
```

Two services are created:
- `<name>.<ns>.svc.cluster.local:8200` — client-facing ClusterIP
- `<name>-internal` — headless service for raft cluster communication

## Plugin System (All Methods)

| # | Method | Description |
|---|--------|-------------|
| 1 | **Community plugins** | Init container downloads from openbao/openbao-plugins releases |
| 2 | **ConfigMap** | `plugins.extra` values → init container copies to `/vault/plugins/` |
| 3 | **Sidecar image** | `plugins.image` + `plugins.sidecar` for custom plugin management |
| 4 | **Script** | `install-plugin.sh` for runtime upload, register, mount |
| 5 | **Terraform** | `openbao_plugin` + `openbao_mount` resources |

## Ingress

Defaults to external (internet-facing). Change to `internal` for corporate deployments.

### External (default for this chart)

```yaml
server:
  ingress:
    enabled: true
    ingressClassName: alb
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:...:certificate/..."
```

### Internal (corporate)

```yaml
server:
  ingress:
    enabled: true
    ingressClassName: alb          # or nginx
    annotations:
      alb.ingress.kubernetes.io/scheme: internal
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:...:certificate/..."
```

## Full Configuration Example

Values are injected from Terraform or your config — nothing is hardcoded.

```yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
  dataStorage:
    size: 10Gi
    storageClass: gp3              # set by Terraform (aws_ebs_volume)
  auditStorage:
    size: 10Gi
    storageClass: gp3
  ingress:
    enabled: true
    ingressClassName: alb          # external by default; change to internal for corporate

plugins:
  community:
    enabled: true
    auth:
      aws:   { enabled: true }
      azure: { enabled: true }
      gcp:   { enabled: true }
    secrets:
      aws:   { enabled: true }
      azure: { enabled: true }
      gcp:   { enabled: true }
      nomad: { enabled: true }

seal:
  awskms:
    enabled: true                  # set to true only when region + kms_key_id are provided
    region: ""                     # injected from Terraform (var.seal.region)
    kms_key_id: ""                 # injected from Terraform (aws_kms_key.openbao.key_id)
    irsaRoleArn: ""                # injected from Terraform (aws_iam_role.openbao_irsa.arn)

ui:
  enabled: true

injector:
  enabled: true
```

## License

MIT
