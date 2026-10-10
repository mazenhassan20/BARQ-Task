#!/usr/bin/env bash
# Bootstrap / manual deploy without Argo CD. Run from the repo root.
# Requires: kubectl pointing at the cluster and a local .env file.
# With Argo CD in place, only the Secret step below is still manual.
set -euo pipefail
NS=barq

[[ -f .env ]] || { echo "ERROR: .env not found in $(pwd)"; exit 1; }

kubectl apply -f k8s/00-namespace.yaml

# Secret from .env (same file docker compose uses). Do not wrap values in quotes in .env.
# It stays out of git, so Argo CD neither tracks nor prunes it.
kubectl -n "$NS" create secret generic barq-env --from-env-file=.env \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "${1:-}" == "--secret-only" ]]; then
  echo "Secret applied. Argo CD handles the rest."
  exit 0
fi

kubectl apply -k .
kubectl -n "$NS" rollout status statefulset/postgres --timeout=180s
kubectl -n "$NS" rollout status statefulset/redis --timeout=180s
kubectl -n "$NS" rollout status deployment/app --timeout=180s
kubectl -n "$NS" rollout status deployment/nginx --timeout=120s
kubectl -n "$NS" get pods,svc,pvc -o wide
