#!/usr/bin/env bash
# Manual deploy for the BARQ app. Run from the repo root on the control-plane node.
# Requires: kubectl configured for the cluster, and a local .env file (see .env.example).
# Usage:  ./deploy.sh              # secret + all manifests + wait for rollout
#         ./deploy.sh --secret-only  # only (re)create the Secret
set -euo pipefail
NS=barq-project

[[ -f .env ]] || { echo "ERROR: .env not found in $(pwd). Copy .env.example to .env first."; exit 1; }

kubectl apply -f k8s/00-namespace.yaml

# Secret built from .env. The file stays out of git, so only this script ever creates it.
kubectl -n "$NS" create secret generic barq-secret --from-env-file=.env \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "${1:-}" == "--secret-only" ]]; then
  echo "Secret applied."
  exit 0
fi

kubectl apply -k k8s/

kubectl -n "$NS" wait --for=condition=complete job/db-init --timeout=120s
kubectl -n "$NS" rollout status deployment/redis --timeout=180s
kubectl -n "$NS" rollout status deployment/barq-app --timeout=180s
kubectl -n "$NS" rollout status deployment/nginx --timeout=120s
kubectl -n "$NS" get pods,svc,pvc -o wide
