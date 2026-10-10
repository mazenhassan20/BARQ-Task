#!/usr/bin/env bash
# Install Argo CD (non-HA, pinned) on the cluster. Run from WSL with KUBECONFIG pointing at Azure.
set -euo pipefail
ARGO_VERSION=v3.5.4

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Server-side apply: the Argo CRDs are too large for client-side apply annotations.
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"

# Nodes have 4 GiB: drop what a single-user lab does not use (SSO and notifications).
kubectl -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0

kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

echo
echo "Admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo
echo "UI: run   kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "    then open https://localhost:8080   (user: admin)"
