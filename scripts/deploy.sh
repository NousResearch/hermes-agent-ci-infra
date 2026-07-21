#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Deploy / update the GKE-based GitHub Actions self-hosted runner infrastructure
#
# Prerequisites:
#   - gcloud (authenticated: gcloud auth login + gcloud auth application-default login)
#   - kubectl
#   - helm 3.8+
#   - terraform
#
# Usage:
#   ./deploy.sh                    # full deploy
#   ./deploy.sh --terraform-only   # just apply GCP infra
#   ./deploy.sh --helm-only        # just apply k8s resources
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="hermes-agent-github-actions"
REGION="us-central1"
CLUSTER_NAME="gha-runners"

# Parse args
TF_ONLY=false
HELM_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --terraform-only) TF_ONLY=true ;;
    --helm-only)      HELM_ONLY=true ;;
  esac
done

# ─── Phase 1: Terraform (GCP infra) ──────────────────────────────────────────

if [ "$HELM_ONLY" = false ]; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  Phase 1: Terraform — GCP infrastructure             ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  cd "$SCRIPT_DIR/../terraform"

  terraform init
  terraform plan -out=tfplan
  terraform apply tfplan

  echo ""
  echo "✓ Terraform apply complete"
  echo ""
fi

# ─── Get cluster credentials ─────────────────────────────────────────────────

echo "Getting cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  --project "$PROJECT_ID"
echo ""

# ─── Phase 2: cert-manager ───────────────────────────────────────────────────

if [ "$TF_ONLY" = false ]; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  Phase 2: cert-manager                              ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.1/cert-manager.yaml

  kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s
  kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s
  kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=120s

  echo ""
  echo "✓ cert-manager ready"
  echo ""
fi

# ─── Phase 3: ARC controller ─────────────────────────────────────────────────

if [ "$TF_ONLY" = false ]; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  Phase 3: ARC controller                            ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  helm upgrade --install arc \
    --namespace arc-systems \
    --create-namespace \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=gha-runner-scale-set-controller \
    -n arc-systems --timeout=120s 2>/dev/null || true

  echo ""
  echo "✓ ARC controller deployed"
  echo ""
fi

# ─── Phase 4: GitHub secret + cache SA key ───────────────────────────────────

if [ "$TF_ONLY" = false ]; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  Phase 4: Kubernetes secrets                        ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  # Create arc-runners namespace if it doesn't exist
  kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

  # GitHub PAT secret — interactive, only create if missing
  if ! kubectl get secret arc-runner-github-secret -n arc-runners &>/dev/null; then
    echo "GitHub PAT secret not found. Creating..."
    echo "Enter your GitHub PAT (input hidden):"
    read -s GITHUB_PAT
    kubectl create secret generic arc-runner-github-secret \
      --namespace arc-runners \
      --from-literal=github_token="$GITHUB_PAT"
    echo "✓ GitHub PAT secret created"
  else
    echo "✓ GitHub PAT secret already exists"
  fi

  # GCS cache SA key — generate from the Terraform-created SA
  if ! kubectl get secret gcs-cache-sa-key -n arc-runners &>/dev/null; then
    echo "GCS cache SA key secret not found. Creating..."
    gcloud iam service-accounts keys create /tmp/gha-cache-sa-key.json \
      --iam-account "gha-cache-server@${PROJECT_ID}.iam.gserviceaccount.com" \
      --project "$PROJECT_ID"

    kubectl create secret generic gcs-cache-sa-key \
      --namespace arc-runners \
      --from-file=service-account-key=/tmp/gha-cache-sa-key.json

    rm -f /tmp/gha-cache-sa-key.json
    echo "✓ GCS cache SA key secret created"
  else
    echo "✓ GCS cache SA key secret already exists"
  fi

  echo ""
fi

# ─── Phase 5: Cache server ────────────────────────────────────────────────────

if [ "$TF_ONLY" = false ]; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  Phase 5: GHA Cache Server                          ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  helm upgrade --install gha-cache-server \
    --namespace arc-runners \
    -f "$SCRIPT_DIR/../helm/cache-server-values.yaml" \
    oci://ghcr.io/falcondev-oss/charts/github-actions-cache-server

  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=github-actions-cache-server \
    -n arc-runners --timeout=120s 2>/dev/null || true

  echo ""
  echo "✓ Cache server deployed"
  echo ""
fi

# ─── Phase 6: Runner scale sets ───────────────────────────────────────────────

if [ "$TF_ONLY" = false ]; then
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  Phase 6: ARC runner scale sets                     ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  helm upgrade --install arc-runner-set \
    --namespace arc-runners \
    -f "$SCRIPT_DIR/../helm/arc-runner-set-values.yaml" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

  helm upgrade --install arc-runner-arm64 \
    --namespace arc-runners \
    -f "$SCRIPT_DIR/../helm/arc-runner-arm64-values.yaml" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

  echo ""
  echo "✓ amd64 and ARM64 runner scale sets deployed"
  echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Deploy complete!                                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Cluster:    $CLUSTER_NAME ($REGION)"
echo "Project:    $PROJECT_ID"
echo "Runners:    arc-runner-set (amd64, scales 0→30)"
echo "            arc-runner-arm64 (ARM64, scales 0→6)"
echo "Cache:      GCS-backed cache server"
echo ""
echo "Verify:"
echo "  kubectl get pods -n arc-systems"
echo "  kubectl get pods -n arc-runners"
echo ""
echo "Use in workflows:"
echo "  runs-on: arc-runner-set"
echo "  # ARM64 jobs: runs-on: arc-runner-arm64"
