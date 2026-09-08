# Troubleshooting journal

# Troubleshooting Journal

## 1. NGINX 502 Bad Gateway & App Routing
* **Symptoms:** Accessing the environment returned `502 Bad Gateway`. NGINX logs showed `Connection refused` to upstream servers.
* **Hypotheses:** NGINX is pointing to the wrong internal ports, or the Flask apps are not binding to external interfaces.
* **Commands/Results:** Checked `docker-compose.yml` and `nginx.conf`. Discovered `app-01` upstream was mapped to `8081` instead of `8080`. Also, the Flask app was binding to `127.0.0.1`, refusing connections from the NGINX container.
* **Failed Attempts:** Tried hitting `127.0.0.1:8080` directly from the host while NGINX was still mapped incorrectly (mapped host port 8080 to container port 81).
* **Fix & Retest:** 
  - Changed `APP_HOST` to `0.0.0.0` in `docker-compose.yml`.
  - Updated `nginx.conf` upstream to point to `app-01:8080` and `app-02:8080`.
  - Updated NGINX exposed ports to `"8080:80"`.
  - *Retest Evidence:* `curl http://127.0.0.1:8080/` returned 200 OK with the welcome message.

## 2. Windows Host Port Conflict (8080)
* **Symptoms:** `docker compose up` failed with `bind: An attempt was made to access a socket in a way forbidden by its access permissions` for port 8080.
* **Hypotheses:** Port 8080 is either reserved by Windows Hyper-V (`winnat`) or another host process is listening on it.
* **Commands/Results:** Ran `netstat -tulpn | grep 8080` in WSL which showed a Java process (PID 622) listening on it. Later, `netstat -ano | findstr :8080` in Windows PowerShell showed PID 6328 listening.
* **Fix & Retest:** 
  - Killed the offending Java process using `taskkill /PID 6328 /F` from an Administrator PowerShell.
  - *Retest Evidence:* `docker compose up -d` successfully bound NGINX to 8080.

## 3. Database Connectivity & 503 Errors
* **Symptoms:** `curl http://127.0.0.1:8080/ready` returned `503` with Postgres and Redis showing as `unavailable`. Log analysis showed `TimeoutError` for Redis and `InvalidPassword` for PostgreSQL.
* **Hypotheses:** The connection strings in the environment variables are incorrect, pointing to the wrong hostnames, ports, or using wrong credentials.
* **Commands/Results:** Investigated `config/app.env`. Found that `DATABASE_URL` used port `5433` (instead of 5432) and a typo in the password (ended in `d` instead of `c`). `REDIS_URL` used port `6380` (instead of 6379).
* **Fix & Retest:** 
  - Fixed `config/app.env` to:
    `DATABASE_URL=postgresql://barq_app:BarqLabOnly_7qN2vK8c@postgres:5432/barq_tasks`
    `REDIS_URL=redis://redis:6379/0`
  - Added proper `depends_on: condition: service_healthy` in compose.
  - *Retest Evidence:* `curl http://127.0.0.1:8080/ready` returned `{"dependencies":{"postgres":"ready","redis":"ready"},"status":"ready"}`.

## 4. Container Security (Root User Risk)
* **Symptoms:** Code review of the `Dockerfile` revealed `USER root` at the end of the file.
* **Hypotheses:** The container runs as the privileged root user, violating security best practices.
* **Fix & Retest:** 
  - Changed `USER root` to `USER app` in the `Dockerfile`.
  - Added `--chown=app:app` to the `COPY config/app.env /srv/app.env` instruction so the non-root user can read the config.
  - *Retest Evidence:* Container built successfully and application started without permission denied errors.

## 5. Database Persistence
* **Symptoms:** Data would be lost on container restart. PostgreSQL was using a `tmpfs` mount, and Redis persistence was disabled.
* **Fix & Retest:** 
  - Removed `tmpfs` from postgres in `docker-compose.yml`.
  - Mapped `postgres-data` volume to `/var/lib/postgresql/data` (was incorrectly mapped to `/backup`).
  - Added `--appendonly yes` to the Redis command to enable AOF persistence.