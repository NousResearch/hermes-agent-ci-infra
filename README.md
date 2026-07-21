# hermes-agent-ci-infra

Infrastructure as code for the GKE-based GitHub Actions self-hosted runners
that power CI for [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).

## Architecture

```
GKE cluster (gha-runners, us-central1)
├── default-pool (e2-standard-2, 1-3 nodes)
│   └── ARC controller, cert-manager, cache server
├── spot-runners pool (e2-standard-4, 0-20 nodes, spot)
│   └── ephemeral runner pods (one per job, scale to zero when idle)
│
├── arc-systems namespace
│   ├── ARC controller (operator)
│   └── listener pod (watches GitHub Actions queue)
├── arc-runners namespace
│   ├── runner pods (forked image, dind, CUSTOM_ACTIONS_RESULTS_URL)
│   └── cache server (GCS-backed, drop-in actions/cache replacement)
│
└── GCS bucket: hermes-agent-github-actions-gha-cache
```

## Cost

When idle: ~$25/mo (one e2-standard-2 for the controller + control plane).
Per-job: spot e2-standard-4 compute seconds (~$0.06/hr spot rate).
Cache storage: GCS standard tier, ~$0.020/GB/mo (cache evicts after 7 days).

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm 3.8+](https://helm.sh/docs/intro/install/)
- [terraform](https://developer.hashicorp.com/terraform/downloads)
- A GCP project with billing enabled
- A GitHub PAT with `repo` scope, SSO-authorized for your org

## Setup

### 1. Authenticate with GCP

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project hermes-agent-github-actions
gcloud auth application-default set-quota-project hermes-agent-github-actions
```

### 2. Deploy everything

```bash
./scripts/deploy.sh
```

The script runs in order:
1. **Terraform** — creates GKE cluster, node pools, GCS bucket, IAM service account
2. **cert-manager** — required by ARC for webhook TLS
3. **ARC controller** — the Kubernetes operator that manages runner pods
4. **Secrets** — creates k8s secrets for the GitHub PAT and GCS SA key
5. **Cache server** — falcondev-oss/github-actions-cache-server with GCS backend
6. **Runner scale set** — the actual runner pods (scales 0→30)

The script is idempotent — safe to re-run for updates.

### 3. Use the runners

In any workflow in NousResearch/hermes-agent:

```yaml
jobs:
  test:
    runs-on: arc-runner-set
```

## Repo structure

```
hermes-agent-ci-infra/
├── terraform/
│   ├── main.tf                  # GKE cluster, node pools, GCS bucket, IAM
│   ├── backend.tf               # State backend config (local by default)
│   ├── terraform.tfvars.example  # Copy to terraform.tfvars and customize
│   └── .gitignore
├── helm/
│   ├── arc-runner-set-values.yaml     # Runner scale set (dind, forked image, cache URL)
│   └── cache-server-values.yaml        # GCS-backed cache server
├── scripts/
│   └── deploy.sh                 # Full deploy script (terraform + helm)
└── README.md
```

## Components

### Terraform (`terraform/main.tf`)

| Resource | Description |
|---|---|
| `google_container_cluster.gha_runners` | GKE cluster (Standard mode, Workload Identity enabled) |
| `google_container_node_pool.default_pool` | e2-standard-2, 1-3 nodes (controller + system) |
| `google_container_node_pool.spot_runners` | e2-standard-4, 0-20 nodes, spot (runner pods) |
| `google_storage_bucket.cache` | GCS bucket for actions cache |
| `google_service_account.cache_server` | SA with storage.objectAdmin on the cache bucket |

### Helm charts (applied by deploy.sh)

| Chart | Namespace | Purpose |
|---|---|---|
| cert-manager (v1.15.1) | cert-manager | TLS for ARC webhooks |
| gha-runner-scale-set-controller (v0.14.2) | arc-systems | ARC operator |
| gha-runner-scale-set (v0.14.2) | arc-runners | Runner scale set (dind, 0-30 runners) |
| github-actions-cache-server (v1.1.0) | arc-runners | GCS-backed cache server |

### Runner image

Uses `ghcr.io/falcondev-oss/actions-runner:latest` — a fork of the official
GitHub Actions runner that patches the binary to accept `CUSTOM_ACTIONS_RESULTS_URL`.
This env var redirects all `actions/cache` traffic to our self-hosted cache server
instead of GitHub's CDN, keeping cache reads/writes inside the cluster network.

The deployable image is `nousresearch/nous-gke-runner:latest` on Docker Hub. It adds
`shellcheck`, compiler tools, `jq`, `zstd`, and Python development tools on top of
that fork. `.github/workflows/build-runner-image.yml` rebuilds and publishes both
`latest` and a commit-SHA tag whenever `runner/Dockerfile` changes on `main`.
Set the repository secret `DOCKERHUB_TOKEN` to a Docker Hub access token with
read/write access to `nousresearch/nous-gke-runner`. The workflow logs in as
`arinous`. Keep that Docker Hub repository
public so GKE runner pods can pull it without an image-pull secret.

The forked image auto-skips runner self-update while `CUSTOM_ACTIONS_RESULTS_URL`
is set. You must still update the image periodically (GitHub requires runners
to stay within ~30 days of the latest release).

## Operations

### Update runner config

```bash
# Edit helm/arc-runner-set-values.yaml, then:
helm upgrade arc-runner-set -n arc-runners \
  -f helm/arc-runner-set-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### Rotate the GitHub PAT

```bash
kubectl create secret generic arc-runner-github-secret \
  --namespace arc-runners \
  --from-literal=github_token='ghp_NEW_TOKEN' \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart the listener to pick up the new secret
kubectl rollout restart deployment -n arc-systems arc-gha-rs-controller
```

### Check cache server health

```bash
kubectl logs -n arc-runners deployment/gha-cache-server-github-actions-cache-server -f
kubectl get pods -n arc-runners -l app.kubernetes.io/name=github-actions-cache-server
```

### Tear down everything

```bash
cd terraform
terraform destroy
```

This removes the GKE cluster, GCS bucket, and IAM service account.
k8s resources are destroyed with the cluster.
