# Aetherion

A small web service deployed via GitOps to Kubernetes. Infra is provisioned with Terraform on AWS EKS, monitored via Prometheus and Grafana, logs shipped to Loki, RBAC scoped to the service namespace, and policy enforcment handled by Kyverno.

## Project layout

```
aetherion/
├── app/                         Flask web service (Python)
├── terraform/                   EKS cluster and VPC via terraform-aws-modules
├── k8s/
│   ├── base/                    Core workload manifests (managed by ArgoCD)
│   ├── rbac/                    ServiceAccount, Role, RoleBinding
│   ├── network/                 NetworkPolicy
│   └── policies/                Kyverno ClusterPolicies
├── gitops/
│   └── argocd/                  ArgoCD Application definition
├── monitoring/
│   ├── prometheus/              kube-prometheus-stack values + ServiceMonitor
│   ├── grafana/                 Dashboard ConfigMap
│   └── loki/                    loki-stack values
└── scripts/
    └── bootstrap.sh             Full setup in one shot
```

## Prerequisites

- AWS account with IAM permisions to create EKS, VPC, and IAM resources
- `terraform` >= 1.5
- `kubectl`
- `helm` >= 3.12
- `docker` (if building the image locally)
- `argocd` CLI (optional, for manual syncs)
- A container registry (ECR recomended, but any OCI-compatible registry works)

## Setup

### 1. Provision the cluster

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

After apply, configure kubectl. The exact command is in terraform's output:

```bash
terraform output -raw configure_kubectl | bash
```

Or run it directly:

```bash
aws eks update-kubeconfig --region us-east-1 --name aetherion-cluster
```

### 2. Build and push the app image

```bash
cd app
docker build -t <your-registry>/aetherion:1.0.0 .
docker push <your-registry>/aetherion:1.0.0
```

Update the `image:` field in `k8s/base/deployment.yaml` to match before ArgoCD syncs.

### 3. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for it to come up:

```bash
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s
```

Update the `repoURL` in `gitops/argocd/application.yaml` to point to your fork, then register the app:

```bash
kubectl apply -f gitops/argocd/application.yaml
```

ArgoCD will sync `k8s/base` to the cluster on every commit to `main`.

### 4. Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace
```

Apply the policies:

```bash
kubectl apply -f k8s/policies/
```

All four policies start in `Audit` mode, meaning violations are recorded but not blocked. Change `validationFailureAction` to `Enforce` in each policy file once your workload is confirmed compliant.

### 5. Install monitoring

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f monitoring/prometheus/values.yaml

helm upgrade --install loki grafana/loki-stack \
    -n monitoring \
    -f monitoring/loki/values.yaml
```

Apply the ServiceMonitor so Prometheus picks up the app's `/metrics` endpoint:

```bash
kubectl apply -f monitoring/prometheus/servicemonitor.yaml
```

Load the Grafana dashboard:

```bash
kubectl apply -f monitoring/grafana/dashboard.yaml
```

### 6. Apply RBAC and network policies

These are already included in the kustomization, so ArgoCD will apply them on sync. To apply manually:

```bash
kubectl apply -f k8s/rbac/
kubectl apply -f k8s/network/
```

### Automated bootstrap

The above steps are wrapped in a single script. Set `REGISTRY` before running if you want the image built and pushed automatically:

```bash
export REGISTRY=<your-registry>
export AWS_REGION=us-east-1
bash scripts/bootstrap.sh
```

## Accessing things

Get the ArgoCD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
```

Port-forward ArgoCD:

```bash
kubectl port-forward svc/argocd-server 8080:443 -n argocd
```

Port-forward Grafana (default creds: `admin` / `change-me-in-production`):

```bash
kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring
```

Port-forward the app directly:

```bash
kubectl port-forward svc/aetherion 8080:80 -n aetherion
```

Endpoints exposed by the app:

| Path | Purpose |
|------|---------|
| `/health` | liveness probe |
| `/ready` | readiness probe |
| `/api/status` | service status |
| `/metrics` | Prometheus metrics |

## How GitOps works

ArgoCD watches the `k8s/base` path in this repository. Any merge to `main` that changes manifests in that path triggers an automatic sync. `selfHeal: true` means ArgoCD will revert manual cluster changes back to what the repo says. To trigger a sync manually:

```bash
argocd app sync aetherion
```

## Remote state for Terraform

The S3 backend is preconfigured but commented out in `terraform/providers.tf`. To enable it, create the S3 bucket and DynamoDB table first, uncomment the `backend "s3"` block, then run `terraform init` again to migrate local state.

## Notes

- Change the Grafana admin password in `monitoring/prometheus/values.yaml` before deploying to a real enviroment.
- The network policy allows ingress to the app only from `ingress-nginx` and Prometheus. Adjust the `namespaceSelector` labels if your ingress controller lives in a diferent namespace.
- Kyverno policies target only the `aetherion` namespace by default. Extend the `namespaces` list to enforce acros more namespaces.
- `automountServiceAccountToken: false` is set on both the ServiceAccount and the Deployment to limit what the app can do inside the cluster.
- The Grafana dashboard ConfigMap carries the label `grafana_dashboard: "1"` which the Grafana sidecar watches. New dashboards added with that label will be picked up automaticly without restarting Grafana.
