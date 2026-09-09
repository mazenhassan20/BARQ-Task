<img src="assets/barq-logo.svg" alt="BARQ Systems" width="180">

# BARQ DevOps Assessment — Setup & Operations Guide

Flask API behind NGINX, backed by PostgreSQL and Redis, running as two load-balanced
instances (`app-01`, `app-02`) on isolated Docker networks.

## Prerequisites

- Linux or WSL2, Docker Engine with Compose v2, Python 3.12+.
- Ports 8080 (and 8090 during the live challenge) free on the host.

## 1. Setup

```bash
git clone https://github.com/mazenhassan20/BARQ-Task.git
cd BARQ-Task
cp .env.example .env
```

`.env` is git-ignored on purpose. It holds `POSTGRES_PASSWORD`, `DATABASE_URL` and
`REDIS_URL`, and is picked up automatically by Compose via `env_file: .env`.
`.env.example` ships a safe, synthetic lab password for CI and local setup — never
a real credential.

## 2. Build & start

```bash
docker compose build
docker compose up -d
docker compose ps            # all five containers should show "healthy"
```

## 3. Verify

```bash
curl http://127.0.0.1:8080/         # app response
curl http://127.0.0.1:8080/health   # process liveness
curl http://127.0.0.1:8080/ready    # postgres + redis readiness
curl http://127.0.0.1:8080/instance # which backend answered (X-Instance-ID header)
```

Or run the full automated check:

```bash
python3 validate.py --port 8080 --timeout 90
```

`validate.py` waits (with a bounded timeout, never indefinitely) for the stack to
become ready, exercises every required endpoint with real reads/writes, confirms
NGINX load-balances across both running backends, and checks that PostgreSQL and
Redis are unreachable from the host and from NGINX directly. It exits non-zero on
any failure, so it doubles as the CI gate.

## 4. Records and counter (real DB / cache operations)

```bash
curl -X POST http://127.0.0.1:8080/records \
     -H "Content-Type: application/json" \
     -d '{"title": "review service readiness"}'

curl http://127.0.0.1:8080/records
curl http://127.0.0.1:8080/counter
```

## 5. Failure and recovery test

```bash
python3 failure_test.py --port 8080 --target app-01
```

Stops `app-01`, sends traffic through NGINX to confirm `app-02` keeps serving,
restarts `app-01`, waits for its healthcheck, then confirms it's back in rotation.
The target container is always restarted at the end, even if a check fails.

## 6. Backup and restore

```bash
./backup.sh                      # dumps PostgreSQL to backups/<db>_<timestamp>.dump
./restore.sh --yes               # restores the newest dump, verifies row count after
```

Both run `pg_dump`/`pg_restore` inside the `postgres` container, so no PostgreSQL
client tools are needed on the host.

## 7. Persistence across container recreation

Proves a record survives the app and PostgreSQL containers being recreated,
without touching the named volume:

```bash
curl -X POST http://127.0.0.1:8080/records \
     -H "Content-Type: application/json" -d '{"title": "persistence-check"}'

docker compose stop app-01 app-02 postgres
docker compose rm -f app-01 app-02 postgres
docker compose up -d app-01 app-02 postgres

# wait for /ready, then:
curl http://127.0.0.1:8080/records   # "persistence-check" is still there
```

`docker compose rm` without `-v` never touches the `postgres-data` volume — only
the containers are recreated.

## 8. Stop / cleanup

```bash
docker compose down          # stop and remove containers, keep the volume
docker compose down -v       # also remove the postgres-data / redis-data volumes
```

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request: syntax check,
build, start, bounded wait for readiness, then `validate.py`. A separate job runs
a Trivy image scan (report-only for now — see `security_review.md`).

## Changes made live in the video demo

Two changes were made on camera during the Part 5 video, after the steps above were
already recorded working on the baseline setup:

- **Public port moved from 8080 to 8090.** `docker-compose.yml`'s nginx service now
  publishes `127.0.0.1:8090:80` instead of `8080`. Every `curl` command in this README
  used `8080` for the pre-video baseline — use `8090` against the current `main` branch.
- **A third backend, `app-03`, was added.** NGINX now load-balances across three
  instances instead of two. No script changes were needed for this: `validate.py`
  and `failure_test.py` discover running `app-*` containers via `docker ps` instead
  of a hardcoded list, so they picked up `app-03` automatically once it was started
  and reloaded into NGINX's upstream block.

Both changes are covered live in the video, committed with `git diff` shown on
screen, and indexed in `docs/EVIDENCE_INDEX.md` with their commit hashes and video
timestamps. This section is a documentation-only follow-up commit made after the
video to keep the README in sync with the final state.

## More detail

- `troubleshooting.md` — investigation journal for the issues found in the starter environment.
- `log_analysis.md` — access/error/application log analysis.
- `decisions.md` / `security_review.md` — design decisions and risk review.
- `AI_USAGE.md` — AI assistance disclosure.
- `Architecture_old.png` — Show the arch of the project before the video.
- `Architecture_new.png` — Show the arch of the project after the video.