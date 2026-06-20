#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-aetherion-cluster}"
REGION="${AWS_REGION:-us-east-1}"
REGISTRY="${REGISTRY:-}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date +%T)] $*"; }

require_cmd() {
    command -v "$1" &>/dev/null || { echo "required command not found: $1"; exit 1; }
}

require_cmd terraform
require_cmd kubectl
require_cmd helm
require_cmd aws

cd "$ROOT_DIR"

# provision infra
log "Provisioning EKS cluster via Terraform..."
cd terraform
terraform init -upgrade
terraform apply -auto-approve
cd "$ROOT_DIR"

#configure kubeconfig
log "Configuring kubectl..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

#build and push the app image if REGISTRY is set
if [[ -n "$REGISTRY" ]]; then
    log "Building and pushing app image to $REGISTRY..."
    cd app
    docker build -t "${REGISTRY}/aetherion:${IMAGE_TAG}" .
    docker push "${REGISTRY}/aetherion:${IMAGE_TAG}"
    cd "$ROOT_DIR"
    # patch the deployment image reference
    sed -i "s|your-registry/aetherion:1.0.0|${REGISTRY}/aetherion:${IMAGE_TAG}|g" \
        k8s/base/deployment.yaml
fi

#install ArgoCD
log "Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=180s \
    deployment/argocd-server -n argocd

#install Kyverno
log "Installing Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno \
    -n kyverno --create-namespace --wait

#install monitoring
log "Installing kube-prometheus-stack..."
helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install kube-prom \
    prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f monitoring/prometheus/values.yaml \
    --wait

log "Installing Loki stack..."
helm upgrade --install loki grafana/loki-stack \
    -n monitoring \
    -f monitoring/loki/values.yaml \
    --wait

#apply policies, RBAC, network, monitoring objects
log "Applying Kyverno policies..."
kubectl apply -f k8s/policies/

log "Applying RBAC..."
kubectl apply -f k8s/rbac/

log "Applying network policies..."
kubectl apply -f k8s/network/

log "Applying ServiceMonitor and Grafana dashboard..."
kubectl apply -f monitoring/prometheus/servicemonitor.yaml
kubectl apply -f monitoring/grafana/dashboard.yaml

#register the ArgoCD application
log "Registering ArgoCD application..."
kubectl apply -f gitops/argocd/application.yaml

log ""
log "Bootstrap complete."
log ""
log "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
echo ""
log ""
log "Access Grafana:"
log "  kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring"
log "  Credentials: admin / change-me-in-production"
log ""
log "Access ArgoCD UI:"
log "  kubectl port-forward svc/argocd-server 8080:443 -n argocd"
