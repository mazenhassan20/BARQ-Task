# Architectural and Technical Decisions

## 1. Network Isolation (Frontend vs. Backend)
* **Decision:** Created two isolated Docker networks: `frontend` (bridge) and `backend` (internal).
* **Assumption/Context:** The assessment requires blocking direct NGINX access to PostgreSQL/Redis.
* **Trade-offs:** Increases Compose file complexity, but significantly improves security by ensuring only backend application containers can resolve and reach database ports. NGINX cannot route traffic to databases even if misconfigured.

## 2. Dynamic Container Discovery via Service Names
* **Decision:** Configured NGINX upstream and `app.env` to use Docker service names (`app-01`, `postgres`) instead of static IPs.
* **Alternative:** Hardcoding static IPs (e.g., `172.23.0.x`).
* **Trade-offs:** Avoids IP collisions and breaking configurations when containers restart or networks are recreated. It requires Docker's internal DNS to function correctly.

## 3. Database Persistence Implementation
* **Decision:** Used a named Docker volume (`postgres-data` mapped to `/var/lib/postgresql/data`) for Postgres and enabled `appendonly` mode with a volume for Redis.
* **Alternative:** Using bind mounts to the host filesystem.
* **Trade-offs:** Named volumes are fully managed by Docker, preventing host permission issues (especially on Windows/WSL environments), though they are slightly harder to browse directly from the host compared to bind mounts.

## 4. Validation Script Bounded Waits
* **Decision:** Implemented a bounded wait pattern in `validate.py` (polling `/instance` and `/ready` with a timeout budget of 90 seconds).
* **Alternative:** Using infinite `while True` loops or fixed `sleep(15)` delays.
* **Trade-offs:** Fixed delays are brittle (fail if startup takes 16 seconds), and infinite loops hang CI runners forever. The bounded wait adds script complexity but guarantees CI pipelines fail fast while tolerating variable startup times.

## 5. Non-Root Application Container
* **Decision:** Created a dedicated `app` user (UID 10001) in the Dockerfile and ran the application as this user, along with `chown` for the `app.env` file.
* **Alternative:** Running the Flask app as the default `root` user.
* **Trade-offs:** Adds extra steps to the Docker build process, but fundamentally limits the blast radius if the Python application is compromised, adhering to container security best practices.
