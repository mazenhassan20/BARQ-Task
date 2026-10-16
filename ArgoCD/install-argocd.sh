#!/usr/bin/env bash
# Install Argo CD (non-HA, pinned) on the AWS kubeadm cluster, pinned to the control-plane node.
set -euo pipefail
ARGO_VERSION=v3.5.4

# Everything Argo CD runs is pinned to master-node and tolerates its control-plane taint.
PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"master-node"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Server-side apply: the Argo CRDs are too large for client-side apply annotations.
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"

# Single-user lab: drop SSO and notifications.
kubectl -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0

# Pin every Argo CD workload to the control plane right away.
for d in $(kubectl -n argocd get deployment -o name); do
  kubectl -n argocd patch "$d" --type merge -p "$PATCH"
done
kubectl -n argocd patch statefulset argocd-application-controller --type merge -p "$PATCH"

kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

echo
echo "Where the pods run (all must be master-node):"
kubectl -n argocd get pods -o wide
echo
echo "Admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo
echo "UI: run   kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "    then open https://localhost:8080   (user: admin)"
echo "Then:  kubectl apply -f barq-app.yaml"
