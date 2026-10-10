#!/usr/bin/env bash
# Run from the repo root (barq-academy): ./deploy.sh
# Requires: kubectl pointing at the cluster, a local .env file, and the app image pushed.
set -euo pipefail
NS=barq

[[ -f .env ]] || { echo "ERROR: .env not found in $(pwd)"; exit 1; }

kubectl apply -f k8s/00-namespace.yaml

# Secret from .env (same file docker compose uses). Do not wrap values in quotes in .env.
kubectl -n "$NS" create secret generic barq-env --from-env-file=.env \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create configmap postgres-init --from-file=01-init.sql=database/init.sql \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create configmap nginx-conf --from-file=nginx.conf=k8s/nginx.k8s.conf \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/10-postgres.yaml -f k8s/20-redis.yaml
kubectl -n "$NS" rollout status statefulset/postgres --timeout=180s
kubectl -n "$NS" rollout status statefulset/redis --timeout=180s

kubectl apply -f k8s/30-app.yaml -f k8s/40-nginx.yaml -f k8s/50-networkpolicies.yaml
kubectl -n "$NS" rollout status deployment/app --timeout=180s
kubectl -n "$NS" rollout status deployment/nginx --timeout=120s

kubectl -n "$NS" get pods,svc,pvc -o wide
