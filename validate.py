#!/usr/bin/env python3
"""Environment validation for the BARQ assessment stack.

Checks (in order), each bounded in time, PASS/FAIL per check:
  1. Public NGINX endpoint reachable and /ready becomes healthy (bounded wait)
  2. /            -> 200, has "message"
  3. /health       -> 200, status "alive"
  4. /instance     -> 200, backend identity header present
  5. /ready        -> 200, postgres + redis both "ready"
  6. /records      -> POST creates a record, GET lists it back
  7. /counter      -> Redis-backed counter increases monotonically
  8. Load balancing -> repeated requests through NGINX hit every running
     app-* container (discovered live via Docker, so it also works with
     2 or 3+ instances without editing this script)
  9. Network isolation:
       a. host cannot reach postgres (5432) / redis (6379) directly
       b. only the nginx container publishes a host port
       c. postgres/redis are not on the frontend network; nginx is not on backend

Exit code 0 = all checks PASS. Exit code 1 = at least one check FAILED.
Exit code 2 = usage/environment error (e.g. docker not available).

No third-party dependencies: only the Python standard library, so this
runs the same way locally and inside CI without an extra `pip install`.
"""
from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field


@dataclass
class Result:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class Report:
    results: list = field(default_factory=list)

    def add(self, name: str, ok: bool, detail: str = "") -> Result:
        r = Result(name, ok, detail)
        self.results.append(r)
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] {name}" + (f" — {detail}" if detail else ""))
        return r

    @property
    def all_ok(self) -> bool:
        return all(r.ok for r in self.results)


def http_json(url: str, method: str = "GET", body: dict | None = None, timeout: float = 3.0):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                  headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read()
            return resp.status, dict(resp.headers), (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        return exc.code, dict(exc.headers or {}), (json.loads(payload) if payload else {})


def wait_until(description: str, fn, timeout: float, interval: float, report: Report):
    """Poll fn() (returns (ok: bool, detail: str)) until it passes or the
    time budget runs out. This is the "bounded wait" the task asks for —
    never an infinite retry loop."""
    deadline = time.monotonic() + timeout
    last_detail = ""
    attempts = 0
    while time.monotonic() < deadline:
        attempts += 1
        try:
            ok, last_detail = fn()
        except Exception as exc:  # noqa: BLE001 - keep polling through transient errors
            ok, last_detail = False, f"{type(exc).__name__}: {exc}"
        if ok:
            report.add(description, True, f"ready after {attempts} attempt(s), {last_detail}")
            return True
        time.sleep(interval)
    report.add(description, False, f"timed out after {timeout:.0f}s ({attempts} attempts): {last_detail}")
    return False


def docker(*args: str) -> str:
    proc = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        raise RuntimeError(f"docker {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def discover_app_containers() -> list[str]:
    """Find every running container whose name starts with 'app-', so the
    same script keeps working when a 3rd instance is added live (Part 5)."""
    out = docker("ps", "--filter", "name=^app-", "--filter", "status=running",
                  "--format", "{{.Names}}")
    return sorted(n for n in out.splitlines() if n.strip())


def tcp_port_closed(host: str, port: int, timeout: float = 2.0) -> bool:
    """True if connecting to host:port is refused or times out (i.e. NOT
    reachable) — what we want for postgres/redis from the host."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return False  # connection succeeded -> port is open -> bad
    except (ConnectionRefusedError, socket.timeout, OSError):
        return True


def published_host_ports() -> dict:
    """Map container name -> published host ports, via `docker port`."""
    names = docker("ps", "--format", "{{.Names}}").splitlines()
    return {name: docker("port", name) for name in names}


def network_members(network: str) -> set:
    raw = docker("network", "inspect", network, "--format",
                  "{{range .Containers}}{{.Name}} {{end}}")
    return set(raw.split())


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the BARQ assessment environment.")
    parser.add_argument("--host", default="127.0.0.1", help="Host NGINX is published on")
    parser.add_argument("--port", type=int, default=8080, help="Public NGINX port")
    parser.add_argument("--timeout", type=float, default=90.0,
                         help="Bounded wait budget (seconds) for the stack to become ready")
    parser.add_argument("--interval", type=float, default=2.0, help="Poll interval (seconds)")
    parser.add_argument("--requests-per-check", type=int, default=20,
                         help="How many requests to send when checking load balancing")
    parser.add_argument("--skip-network-checks", action="store_true",
                         help="Skip docker-based network isolation checks (e.g. no docker CLI access)")
    args = parser.parse_args()

    base = f"http://{args.host}:{args.port}"
    report = Report()

    # 1. Bounded wait: NGINX + backends + postgres + redis all healthy via /ready
    def ready_probe():
        status, _, payload = http_json(f"{base}/ready")
        deps = payload.get("dependencies", {})
        ok = status == 200 and deps.get("postgres") == "ready" and deps.get("redis") == "ready"
        return ok, f"status={status} dependencies={deps}"

    if not wait_until("Stack becomes ready (/ready via NGINX)", ready_probe,
                       args.timeout, args.interval, report):
        print("\nStack never became ready within the time budget — stopping early.")
        print_summary(report)
        return 1

    # 2. /
    status, _, payload = http_json(f"{base}/")
    report.add("GET / returns app response", status == 200 and "message" in payload,
               f"status={status} body={payload}")

    # 3. /health
    status, _, payload = http_json(f"{base}/health")
    report.add("GET /health reports liveness", status == 200 and payload.get("status") == "alive",
               f"status={status} body={payload}")

    # 4. /instance
    status, headers, payload = http_json(f"{base}/instance")
    report.add("GET /instance returns backend identity",
               status == 200 and bool(payload.get("instance_id")) and "X-Instance-ID" in headers,
               f"status={status} instance_id={payload.get('instance_id')}")

    # 5. /ready details already proven above; assert it still holds
    status, _, payload = http_json(f"{base}/ready")
    deps = payload.get("dependencies", {})
    report.add("GET /ready: postgres + redis both ready",
               status == 200 and deps.get("postgres") == "ready" and deps.get("redis") == "ready",
               f"dependencies={deps}")

    # 6. /records create + list (real DB write + read, not a mock)
    marker = f"validate-run-{int(time.time())}"
    status, _, payload = http_json(f"{base}/records", method="POST", body={"title": marker})
    created_ok = status == 201 and payload.get("record", {}).get("title") == marker
    report.add("POST /records creates a record", created_ok, f"status={status} body={payload}")

    status, _, payload = http_json(f"{base}/records")
    titles = [r.get("title") for r in payload.get("records", [])]
    report.add("GET /records lists the new record", status == 200 and marker in titles,
               f"status={status} found={marker in titles} total_records={len(titles)}")

    # 7. /counter monotonic increase (real Redis INCR, not a mock)
    status1, _, payload1 = http_json(f"{base}/counter")
    status2, _, payload2 = http_json(f"{base}/counter")
    c1, c2 = payload1.get("counter"), payload2.get("counter")
    counter_ok = (status1 == 200 and status2 == 200
                  and isinstance(c1, int) and isinstance(c2, int) and c2 > c1)
    report.add("GET /counter increases monotonically", counter_ok, f"{c1} -> {c2}")

    # 8-9. Docker-dependent checks: load balancing + network isolation
    if not args.skip_network_checks:
        try:
            expected = set(discover_app_containers())
            seen = set()
            for _ in range(args.requests_per_check):
                _, _, payload = http_json(f"{base}/instance")
                iid = payload.get("instance_id")
                if iid:
                    seen.add(iid)
            report.add("NGINX load-balances across every running backend",
                       bool(expected) and expected == seen,
                       f"expected={sorted(expected)} seen={sorted(seen)} "
                       f"(sent {args.requests_per_check} requests)")
        except Exception as exc:  # noqa: BLE001
            report.add("NGINX load-balances across every running backend", False,
                       f"could not discover containers via docker: {exc}")

        report.add("Host cannot reach postgres:5432 directly",
                   tcp_port_closed(args.host, 5432), "expected connection refused/timeout")
        report.add("Host cannot reach redis:6379 directly",
                   tcp_port_closed(args.host, 6379), "expected connection refused/timeout")

        try:
            ports = published_host_ports()
            offenders = {name: mapping for name, mapping in ports.items()
                         if name != "nginx" and mapping}
            report.add("Only nginx publishes a host port", not offenders,
                       f"unexpected published ports: {offenders}" if offenders else
                       f"nginx -> {ports.get('nginx', '(none)')}")
        except Exception as exc:  # noqa: BLE001
            report.add("Only nginx publishes a host port", False, str(exc))

        try:
            backend_members = network_members("barq-assessment_backend")
            frontend_members = network_members("barq-assessment_frontend")
            isolation_ok = ("nginx" not in backend_members
                             and "postgres" not in frontend_members
                             and "redis" not in frontend_members)
            report.add("nginx cannot reach postgres/redis over the network", isolation_ok,
                       f"backend={sorted(backend_members)} frontend={sorted(frontend_members)}")
        except Exception as exc:  # noqa: BLE001
            report.add("nginx cannot reach postgres/redis over the network", False, str(exc))
    else:
        print("[SKIP] network isolation checks (--skip-network-checks)")

    print_summary(report)
    return 0 if report.all_ok else 1


def print_summary(report: Report) -> None:
    passed = sum(1 for r in report.results if r.ok)
    total = len(report.results)
    print(f"\n== Summary: {passed}/{total} checks passed ==")
    if passed != total:
        print("Failed checks:")
        for r in report.results:
            if not r.ok:
                print(f"  - {r.name}: {r.detail}")


if __name__ == "__main__":
    sys.exit(main())