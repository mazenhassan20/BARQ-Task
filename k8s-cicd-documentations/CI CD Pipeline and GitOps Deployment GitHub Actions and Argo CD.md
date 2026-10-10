# CI/CD Pipeline and GitOps Deployment: GitHub Actions and Argo CD

## Overview

A push to `main` that changes application code now builds, scans and publishes a container image, records its tag in Git, and lets Argo CD roll it out to the Azure cluster with no manual commands. This was observed end to end for commit `e4d21a0`, which is running in the cluster as `sha-e4d21a0`.

The work builds on the two-node kubeadm cluster on Azure (control plane `master-node` 172.16.0.4, worker `worker-1` 172.16.0.5) and the BARQ deployment in namespace `barq`. The source repository is `mazenhassan20/BARQ-Task`. GitHub Actions is the CI system, GitHub Container Registry (GHCR) holds the images, and Argo CD v3.5.4 reconciles the cluster from the repository root.

&#91;embedded content: change flow · 7 steps, 1 decision\]

Image-affecting changes pass through the registry and a tag commit. Manifest-only changes skip that path and Argo CD picks them up straight from Git, without waiting for CI.

| Capability | Result observed | Figures |
| --- | --- | --- |
| CI gates the image | Run 21 passed all five jobs in 1 m 9 s | 1, 2 |
| Path filtering | Manifest-only commits: 3 of 5 checks passed. Application commit: 5 of 5 | 3 |
| Failure handling | Commit `f9080f4` stopped at 3 of 5 checks; `e4d21a0` fixed it and passed 5 of 5 | 2, 3 |
| Publish to GHCR | Tag `sha-e4d21a0` published next to the earlier `v1` | 4 |
| Tag promotion through Git | Bot commit `62bbc12` sets the new tag in `kustomization.yaml` | 3 |
| Argo CD sync | Application `barq` Synced and Healthy, auto-sync enabled | 5, 6, 7 |
| Rollout of the new image | Deployment `app` runs `ghcr.io/mazenhassan20/barq-app:sha-e4d21a0`, 3/3 ready | 8, 9 |
| Self-heal after manual scale | `app` read 2/2 right after scaling to 1; the intermediate state was not captured | 10 |

## CI Pipeline

One workflow, `.github/workflows/ci.yml`, runs five jobs and publishes an image only when image-affecting files changed on `main`. The original Compose-based job was kept as the integration gate; the Kubernetes-era jobs were added around it.

**Triggers.** Push to `main`, pull requests, and manual dispatch. Pushes and pull requests that touch only documentation (`**.md`, `docs/**`, `images/**`, common image extensions, `LICENSE`) are excluded with `paths-ignore`, so an exclusion list decides what is skipped and a new, unlisted file type starts CI by default.

| Job | What it does | Runs when |
| --- | --- | --- |
| `build-start-validate` | Copies `.env.example` to `.env`, validates and builds the Compose stack, starts it, runs `validate.py` against port 8090 (90 s timeout), prints logs on failure, always tears down | Every run |
| `static-checks` | Renders `kubectl kustomize .` and validates it with kubeconform (`-strict`, Kubernetes 1.31.0); `bash -n deploy.sh`; Trivy secret scan (fails on findings); Trivy config scan of `k8s/` (report only) | Every run |
| `changes` | Sets `image=true` when `app/`, `database/`, `nginx/`, `Dockerfile`, `requirements*.txt` or `.dockerignore` changed; always true on manual dispatch | Every run |
| `image` | Builds the image locally, reports HIGH and CRITICAL findings, fails on fixable CRITICAL findings, then logs in to GHCR and pushes on a push to `main` | The three jobs above passed and `image=true` |
| `deploy-tag` | Writes the new tag into `kustomization.yaml` and commits it as `github-actions[bot]` | `image` succeeded on a push to `main` |

**Controls built into the workflow**

- Every third-party action is pinned to a full commit SHA, with the release in a comment: checkout v7.0.1, setup-buildx v4.4.1, build-push v7.4.0, login v4.6.0, metadata v6.2.0, paths-filter v3.0.4, trivy-action v0.36.0.
- The default token permission is `contents: read`. `image` adds `packages: write` and `deploy-tag` adds `contents: write`, each on its own job only.
- Concurrency is grouped per ref. A newer pull-request run cancels the older one; runs on `main` are never cancelled, so a push to GHCR is not cut off halfway.
- kubeconform checks the rendered kustomize output, so it validates exactly what Argo CD will apply. A local run of this check on the delivered manifests reported 14 valid resources.
- The Compose job tests application behaviour. The Kubernetes manifests themselves are validated for schema only; probes, NetworkPolicies and the Secret are not exercised in CI.

## Image Publishing and Tag Promotion

Each image is tagged with the short commit SHA, and that tag reaches the cluster through a Git commit rather than a command.

- **Tag format.** `docker/metadata-action` produces `sha-<7 characters>` (`type=sha,prefix=sha-,format=short`). There is no `latest` tag, so every running version maps to one commit.
- **When it publishes.** Only on a push to `main`. Pull requests and manual runs still build and scan the image but do not log in to GHCR or push.
- **Registry access.** The workflow logs in with the built-in `GITHUB_TOKEN`. The package `ghcr.io/mazenhassan20/barq-app` is public, so the cluster pulls it without an image pull secret.
- **Promotion.** The repository root `kustomization.yaml` carries an `images:` entry for the package with a `newTag` value. The `deploy-tag` job checks the tag against `^sha-[0-9a-f]{7,}$`, replaces `newTag`, commits as `github-actions[bot]`, rebases on `main` and pushes. If the tag is unchanged it makes no commit.
- **No feedback loop.** Commits pushed with `GITHUB_TOKEN` do not start new workflow runs, and `kustomization.yaml` is not in the image filter, so a tag commit can never trigger another build.
- **Rollback path.** Reverting the tag commit, or setting `newTag` to an earlier SHA, makes Argo CD redeploy that version. This path was not exercised in the lab.

Observed chain for the application commit: `e4d21a0` produced the image `sha-e4d21a0`, and the bot commit `62bbc12` ("ci: deploy sha-e4d21a0") followed it on `main` (Figures 3 and 4).

## GitOps with Argo CD

Argo CD v3.5.4 watches `main` and keeps namespace `barq` identical to what the root `kustomization.yaml` renders.

- **Install.** `argocd/install.sh` applies the pinned non-HA manifest server-side into namespace `argocd`, then scales `argocd-dex-server` and `argocd-notifications-controller` to 0 replicas because SSO and notifications are unused and the nodes have 4 GiB of memory.
- **Access.** The UI is reached with `kubectl port-forward` to the `argocd-server` service. No NodePort or network security group rule was added for it.
- **Layout.** The root `kustomization.yaml` lists the six manifests under `k8s/`, generates the ConfigMaps `postgres-init` (from `database/init.sql`) and `nginx-conf` (from `k8s/nginx.k8s.conf`), and holds the image tag. It sits at the repository root because kustomize refuses to read files outside the directory that contains it.
- **Hashed ConfigMap names.** Generated names carry a content hash and kustomize rewrites the references in the Deployment and StatefulSet, so editing either source file rolls the pods that mount it.
- **Secret.** `barq-env` stays out of Git. It is created from `.env` with `./deploy.sh --secret-only`. Argo CD does not track it, so it is neither synced nor pruned.

| Application field | Value |
| --- | --- |
| Name, project | `barq`, `default` |
| Source | `https://github.com/mazenhassan20/BARQ-Task.git`, revision `main`, path `.` |
| Destination | In-cluster (`https://kubernetes.default.svc`), namespace `barq` |
| Sync policy | Automated with `selfHeal: true` and `prune: false` as delivered; option `ApplyOutOfSyncOnly=true` |

The message of commit `f9080f4` says pruning was switched on afterwards. The live value of `prune` is not part of the captured evidence.

## Deployment and Evidence

The figures follow the path of one application change: CI run, registry, Git, Argo CD, cluster. Captions state only what the screenshot shows.

### Pipeline and registry

&#91;image: Run 21 job graph\]

*Figure 1. CI run 21 (commit `e4d21a0`, branch `main`), attempt 3. All five jobs succeeded: build-start-validate 42 s, static-checks 19 s, changes 4 s, image 56 s, deploy-tag 6 s. Total 1 m 9 s.*

&#91;image: Workflow runs 16 to 21\]

*Figure 2. Workflow runs 16 to 21. Run 20 failed and run 21, the next commit, passed. Runs 16 to 19 finished in 31 to 41 s; runs 20 and 21, which changed application code, took 1 m 34 s and 1 m 9 s.*

&#91;image: Commits on main with check counts\]

*Figure 3. Commits on `main` on 10 October 2026. Manifest-only commits show 3 of 5 checks (3 of 4 before `deploy-tag` existed). `f9080f4` shows a failed check at 3 of 5. `e4d21a0` shows 5 of 5. `62bbc12` is the tag commit by `github-actions[bot]`. The merge of pull request 1 is marked Verified.*

&#91;image: GHCR package versions\]

*Figure 4. Package versions of `barq-app` in GHCR: tag `sha-e4d21a0`, the earlier tag `v1`, and two untagged versions published at the same time as `sha-e4d21a0`.*

### Argo CD and cluster

&#91;image: Argo CD application tile\]

*Figure 5. Argo CD applications view. `barq` is Healthy and Synced; repository `BARQ-Task`, target revision `main`, path `.`, destination in-cluster, namespace `barq`. Argo CD v3.5.4 is shown top left.*

&#91;image: Argo CD tree at 2 replicas\]

*Figure 6. Resource tree after the sync of `eb984d5` ("edit number of app replicas"): Synced, Healthy, auto sync enabled. The `app` ReplicaSet `app-5f5f84d48d` has 2 pods. Deployment `nginx` is at revision 2 with its first ReplicaSet kept at revision 1, and `postgres-0` is 11 minutes old.*

&#91;image: Argo CD tree at 3 replicas\]

*Figure 7. Resource tree later in the session: three pods on the same ReplicaSet `app-5f5f84d48d` (revision 1, the `v1` image). The replica count returned to 3 while the image did not change.*

&#91;image: Deployed image read from the cluster\]

*Figure 8. Image of Deployment `app` read from the cluster with `kubectl`: `ghcr.io/mazenhassan20/barq-app:sha-e4d21a0`.*

&#91;image: Cluster state after the rollout\]

*Figure 9. Cluster state after the rollout. Both nodes Ready on Kubernetes v1.31.14. `app` is 3/3 on ReplicaSet `app-6497c4cb9` (pods 7 minutes old). `nginx` and `postgres-0` are 49 minutes old, `redis-0` is 26 hours old with one restart 179 minutes before the capture. Both PVCs are Bound on `local-path`. Application `barq` is Synced and Healthy.*

&#91;image: Scale test\]

*Figure 10. Scale test. After `kubectl scale deployment app --replicas=1`, a watch shows 2/2 ready and 2 up to date, which matches the count Git declared after `eb984d5`. The intermediate 1/1 state was not captured.*

## Findings

Five observations in the evidence go beyond the successful path.

1. **Argo CD applied a commit whose CI run failed.** Commit `f9080f4` ("return replicas to 3, edit server.py …") shows a failed check (Figures 2 and 3). Afterwards the cluster shows three `app` pods on the original `v1` ReplicaSet (Figure 7). The replica change was applied while CI was red and before any new image existed, because Argo CD watches the repository, not the pipeline.
2. **The failed run stopped before promotion.** `f9080f4` changed application code, so the image stage ran. It passed 3 of 5 checks, which fits the three early jobs passing and the image job failing, and no tag commit followed it. The next commit, `e4d21a0` ("security: update Debian packages in app image"), passed 5 of 5. The log of the failing step was not captured, so the cause is not documented here.
3. **The first sync restarted nginx and postgres once.** Moving to generated ConfigMap names changed their pod templates. In Figure 6 `nginx` is at revision 2 and `postgres-0` is 11 minutes old; in Figure 9 both are 49 minutes old while `redis-0` is 26 hours old. Both PVCs stayed Bound, so the database volume was kept.
4. **Path filtering shows in timing and check counts.** Manifest-only commits finished in 31 to 41 s with 3 checks; application commits ran the image path and took 1 m 9 s to 1 m 34 s with 5 checks (Figures 2 and 3). The skipped jobs themselves were not screenshotted.
5. **Run 21 in Figure 1 is attempt 3.** The run page reads "Latest #3" and a re-run triggered earlier. The outcomes of attempts 1 and 2 were not captured; the figure shows the final, successful attempt.

## Appendix

Listings are the versions delivered for this lab. The repository copy is authoritative if the two differ.

### A. CI workflow (`.github/workflows/ci.yml`)

```yaml
name: CI

on:
  push:
    branches: [main]
    paths-ignore: &docs_only
      - '**.md'
      - 'docs/**'
      - 'images/**'
      - '**.png'
      - '**.jpg'
      - '**.jpeg'
      - '**.svg'
      - 'LICENSE'
  pull_request:
    paths-ignore: *docs_only
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  IMAGE: ghcr.io/mazenhassan20/barq-app

jobs:
  build-start-validate:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Prepare synthetic environment file
        run: cp .env.example .env
      - run: docker compose config -q
      - run: docker compose build
      - run: docker compose up -d
      - run: python3 validate.py --host 127.0.0.1 --port 8090 --timeout 90
      - name: Show compose state and logs on failure
        if: failure()
        run: |
          docker compose ps
          docker compose logs --no-color --tail=200
      - name: Tear down
        if: always()
        run: docker compose down -v

  static-checks:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Install kubeconform
        run: |
          curl -fsSL https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz \
            | tar -xz kubeconform
          sudo mv kubeconform /usr/local/bin/
      - name: Validate rendered Kubernetes manifests (kustomize build)
        run: kubectl kustomize . | kubeconform -strict -summary -kubernetes-version 1.31.0 -
      - name: Syntax-check deploy script
        run: bash -n deploy.sh
      - name: Trivy secret scan (fails on findings)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          scan-type: fs
          scan-ref: .
          scanners: secret
          exit-code: '1'
      - name: Trivy config scan of k8s manifests (report only)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          scan-type: config
          scan-ref: k8s
          format: table
          exit-code: '0'

  changes:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      pull-requests: read
    outputs:
      image: ${{ github.event_name == 'workflow_dispatch' || steps.filter.outputs.image == 'true' }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Detect changes that affect the image
        id: filter
        if: github.event_name != 'workflow_dispatch'
        uses: dorny/paths-filter@0e4a8c6effa4802afeda77dc8d303f8176d7dfad # v3.0.4
        with:
          filters: |
            image:
              - 'app/**'
              - 'database/**'
              - 'nginx/**'
              - 'Dockerfile'
              - 'requirements*.txt'
              - '.dockerignore'

  image:
    needs: [build-start-validate, static-checks, changes]
    if: needs.changes.outputs.image == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 15
    outputs:
      tag: ${{ steps.meta.outputs.version }}
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
      - name: Build image (local, for scanning)
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: .
          load: true
          push: false
          tags: barq-app:ci
      - name: Trivy image report (CRITICAL, HIGH)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: barq-app:ci
          format: table
          severity: CRITICAL,HIGH
          exit-code: '0'
          ignore-unfixed: true
      - name: Trivy gate (fail on fixable CRITICAL)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: barq-app:ci
          format: table
          severity: CRITICAL
          exit-code: '1'
          ignore-unfixed: true
      - name: Log in to GHCR
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Image tags
        id: meta
        uses: docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302 # v6.2.0
        with:
          images: ${{ env.IMAGE }}
          tags: type=sha,prefix=sha-,format=short
      - name: Push to GHCR (main only)
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

  deploy-tag:
    needs: image
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Bump image tag in kustomization.yaml
        env:
          TAG: ${{ needs.image.outputs.tag }}
        run: |
          [[ "$TAG" =~ ^sha-[0-9a-f]{7,}$ ]] || { echo "unexpected tag: $TAG"; exit 1; }
          sed -i "s|^\(\s*newTag:\).*|\1 ${TAG}|" kustomization.yaml
          git diff --quiet && { echo "tag already ${TAG}"; exit 0; }
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -am "ci: deploy ${TAG}"
          git pull --rebase origin main
          git push origin HEAD:main
```

### B. Root `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - k8s/00-namespace.yaml
  - k8s/10-postgres.yaml
  - k8s/20-redis.yaml
  - k8s/30-app.yaml
  - k8s/40-nginx.yaml
  - k8s/50-networkpolicies.yaml

configMapGenerator:
  - name: postgres-init
    namespace: barq
    files:
      - 01-init.sql=database/init.sql
  - name: nginx-conf
    namespace: barq
    files:
      - nginx.conf=k8s/nginx.k8s.conf

images:
  - name: ghcr.io/mazenhassan20/barq-app
    newTag: v1   # rewritten by the deploy-tag job
```

### C. Argo CD Application (`argocd/application.yaml`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: barq
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mazenhassan20/BARQ-Task.git
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: barq
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
```

### D. Argo CD installation (`argocd/install.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail
ARGO_VERSION=v3.5.4

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"

kubectl -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0

kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# UI: kubectl -n argocd port-forward svc/argocd-server 8080:443
```
