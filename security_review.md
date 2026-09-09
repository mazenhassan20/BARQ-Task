# Security Review

## Implemented Fixes (Current State)
1. **Root User Operations:**
   - *Risk:* Running containers as `root` allows potential escapes to impact the host.
   - *Fix Implemented:* Changed the `Dockerfile` to use a non-root `app` user (UID 10001).
2. **Exposed Database Ports:**
   - *Risk:* Mapping ports `15432` and `16379` to the host exposed databases to potential direct attacks.
   - *Fix Implemented:* Removed port mappings for Postgres and Redis.
3. **Hardcoded Secrets in Compose:**
   - *Risk:* Storing passwords directly in `docker-compose.yml` leaks credentials into version control.
   - *Fix Implemented:* Extracted the Postgres password into a git-ignored `.env` file and provided a safe `.env.example`.
4. **Internal Network Segmentation:**
   - *Risk:* A compromised NGINX container could interact directly with the databases.
   - *Fix Implemented:* Created an `internal: true` backend network. NGINX only exists on the frontend network.

## Production Improvement Plans (Future State)
5. **Secrets Management:**
   - *Risk:* Currently, secrets are injected as plain environment variables, which can be viewed via `docker inspect`.
   - *Improvement:* In production, use Docker Swarm Secrets, HashiCorp Vault, or AWS Secrets Manager to inject credentials at runtime without exposing them to the daemon.
6. **Container Images & Vulnerabilities:**
   - *Risk:* Base images (even slim ones) may contain known CVEs over time.
   - *Improvement:* The CI pipeline currently runs Trivy as a report-only tool (exit-code 0). In production, this must be flipped to `exit-code 1` to strictly block vulnerable builds.
7. **Availability & Single Points of Failure (SPOF):**
   - *Risk:* NGINX, PostgreSQL, and Redis are running as single instances. If the node hosting Postgres crashes, the system goes down.
   - *Improvement:* Deploy PostgreSQL in a Highly Available (HA) cluster (e.g., using Patroni), use Redis Sentinel/Cluster, and run multiple NGINX ingress controllers.
8. **Backup and Logging Risks:**
   - *Risk:* Backups currently reside on the same local filesystem. Logs are only captured in Docker's local JSON-file driver.
   - *Improvement:* Push PostgreSQL dumps automatically to off-site object storage (e.g., AWS S3). Centralize logs using an ELK stack or Grafana Loki to prevent log loss upon container termination.
