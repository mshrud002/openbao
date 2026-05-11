# OpenBao Deployment Architecture

## 1. Deployment Pipeline (GitHub Actions → AWS EKS)

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

## 2. Kubernetes Resource Architecture

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

    SA -.->|"IRSA annotation<br/>eks.amazonaws.com/role-arn"| MAIN
    CM -.->|"openbao.hcl"| MAIN
```

## 3. Network Flow

```mermaid
flowchart LR
    USER["User<br/>HTTPS"] --> INGRESS["AWS ALB / NGINX<br/>Ingress"]
    INGRESS -->|"host: bao.example.com"| SVC["Service: openbao<br/>ClusterIP :8200"]
    SVC --> POD0["Pod: openbao-0<br/>:8200 API + UI"]
    SVC --> POD1["Pod: openbao-1<br/>:8200 API + UI"]
    SVC --> POD2["Pod: openbao-2<br/>:8200 API + UI"]

    SVC_INT["Service: openbao-internal<br/>(headless)"] -->|"Raft gossip<br/>:8201"| POD0
    SVC_INT -->|"Raft gossip<br/>:8201"| POD1
    SVC_INT -->|"Raft gossip<br/>:8201"| POD2

    POD0 -->|"retry_join"| POD1
    POD1 -->|"retry_join"| POD2
```

## 4. KMS Auto-Unseal (IRSA)

```mermaid
flowchart TD
    subgraph "AWS"
        KMS_KEY["AWS KMS Key"] -->|"kms:Decrypt<br/>kms:Encrypt"| IRSA_ROLE["IAM Role (IRSA)"]
    end

    subgraph "Kubernetes / EKS"
        SA["ServiceAccount<br/>openbao"] -->|"annotation:<br/>eks.amazonaws.com/role-arn"| IRSA_ROLE
        POD["OpenBao Pod"] -->|"mounts ServiceAccount"| SA
    end

    subgraph "OpenBao Process"
        CONFIG["openbao.hcl<br/>seal 'awskms' {<br/>  region<br/>  kms_key_id<br/>}"] -->|"reads seal stanza"| BAO_SERVER["bao server"]
        BAO_SERVER -->|"kms:Decrypt (root key)"| KMS_KEY
        BAO_SERVER -->|"auto-unsealed"| READY["Ready for traffic"]
    end

    POD --> CONFIG
```

## 5. Plugin System

```mermaid
flowchart TD
    subgraph "initContainers"
        COMMUNITY["plugin-download<br/>curlimages/curl"] -->|"curl GitHub releases"| ARCHIVES["openbao-plugins/releases"]
        ARCHIVES -->|"extract .tar.gz"| PLUGIN_DIR["/vault/plugins/<br/>(emptyDir)"]
        CONFIGMAP["plugin-copy<br/>(same image)"] -->|"copy from ConfigMap"| PLUGIN_DIR
        SIDECAR["plugin-image<br/>(custom image)"] -->|"copy from image"| PLUGIN_DIR
    end

    subgraph "Post-Deploy (init + unseal required)"
        PLUGIN_DIR --> REGISTER["scripts/register-plugins.sh<br/>or install-plugin.sh"]
        REGISTER -->|"bao plugin register<br/>-sha256=..."| PLUGIN_REG["Plugin Registered"]
        PLUGIN_REG -->|"bao auth enable /<br/>bao secrets enable"| PLUGIN_MOUNTED["Plugin Mounted & Active"]
    end
```

## 6. Init & Unseal Flow

```mermaid
flowchart TD
    DEPLOY["Helm install/upgrade done"] --> WAIT["kubectl wait<br/>pod openbao-0 Ready"]
    WAIT --> CHECK{"bao status<br/>already initialized?"}
    CHECK -->|"No"| INIT["bao operator init<br/>-key-shares=5 -key-threshold=3"]
    CHECK -->|"Yes"| DONE["Already initialized"]
    INIT --> KEYS["Save to:<br/>openbao-init-{ns}.json<br/>(5 unseal keys + root token)"]
    KEYS --> UNSEAL["For each pod (0..N):<br/>bao operator unseal <key> x3"]
    UNSEAL --> VERIFY["Verify: bao status<br/>.sealed = false"]
    VERIFY --> READY["OpenBao Ready"]
```

## 7. CI / Deploy / Release Trigger Map

```mermaid
flowchart TD
    subgraph "CI (On Push/PR to main)"
        CI_LINT["helm lint"] --> CI_TEMPLATE["helm template<br/>--kube-version 1.28.0"]
        CI_SHELLCHECK["shellcheck scripts/*.sh"]
        CI_TERRAFORM["terraform validate"]
    end

    subgraph "Deploy (workflow_dispatch)"
        EKS_OIDC["eks-oidc-auth.sh<br/>OIDC -> AWS -> EKS"] --> HELM_DEPLOY["helm install/upgrade"]
        HELM_DEPLOY --> INIT_UNSEAL["init-and-unseal.sh<br/>(optional)"]
        INIT_UNSEAL --> REGISTER_PLUGINS["register-plugins.sh<br/>(optional)"]
    end

    subgraph "Release (v* tag)"
        PACKAGE["helm package"] --> INDEX["helm repo index"]
        PACKAGE --> GH_RELEASE["GitHub Release"]
    end

    subgraph "Runtime"
        STS["StatefulSet"] -->|"auto-unseal via KMS"| READY_POD["Unsealed Pod"]
        CRON["CronJob (manual)<br/>backup-raft.sh"] --> SNAPSHOT["Raft Snapshot -> S3"]
    end
```
