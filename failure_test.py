#!/usr/bin/env python3
"""Failure / recovery test for one backend, driven entirely through NGINX.

Flow:
  1. Baseline traffic through NGINX — confirm the target backend is
     currently answering requests.
  2. `docker stop <target>`.
  3. Traffic during failure — confirm NGINX keeps serving 200s from the
     surviving backend(s) and count any errors while NGINX's passive
     health check (max_fails/fail_timeout in nginx.conf) marks the
     target down.
  4. `docker start <target>`, bounded wait for its Docker healthcheck to
     report healthy again.
  5. Traffic after recovery — prove the target backend is back in the
     NGINX rotation.

The target container is ALWAYS restarted at the end (success or
failure), so a failed run never leaves the environment degraded.

Exit code 0 = recovery proven. Exit code 1 = a check failed.
Exit code 2 = usage/environment error.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request


def http_json(url: str, timeout: float = 3.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            payload = resp.read()
            return resp.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        return exc.code, (json.loads(payload) if payload else {})
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        return None, {"error": str(exc)}


def docker(*args: str) -> str:
    proc = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        raise RuntimeError(f"docker {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def container_health(name: str) -> str:
    try:
        return docker("inspect", "--format", "{{.State.Health.Status}}", name)
    except RuntimeError:
        return "unknown"


def send_burst(base: str, count: int, delay: float = 0.15) -> dict:
    """Send `count` requests to /instance through NGINX. Returns a summary:
    status code counts and which instance_ids answered."""
    statuses: dict[int, int] = {}
    instances: dict[str, int] = {}
    for _ in range(count):
        status, payload = http_json(f"{base}/instance")
        key = status if status is not None else "no_response"
        statuses[key] = statuses.get(key, 0) + 1
        iid = payload.get("instance_id")
        if iid:
            instances[iid] = instances.get(iid, 0) + 1
        time.sleep(delay)
    return {"statuses": statuses, "instances": instances}


def wait_healthy(name: str, timeout: float, interval: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if container_health(name) == "healthy":
            return True
        time.sleep(interval)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Stop/restore one backend and verify recovery.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--target", default="app-01", help="Container name to stop")
    parser.add_argument("--requests", type=int, default=20, help="Requests per traffic sample")
    parser.add_argument("--recovery-timeout", type=float, default=30.0,
                         help="Bounded wait for the restarted container to report healthy")
    args = parser.parse_args()
    base = f"http://{args.host}:{args.port}"

    checks: list[tuple[str, bool, str]] = []

    def record(name: str, ok: bool, detail: str = ""):
        checks.append((name, ok, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))

    print(f"== Baseline: {args.requests} requests through NGINX ==")
    baseline = send_burst(base, args.requests)
    print(f"statuses={baseline['statuses']} instances={baseline['instances']}")
    record("Target backend answers before the failure", args.target in baseline["instances"],
           f"instances seen: {sorted(baseline['instances'])}")

    try:
        print(f"\n== Stopping {args.target} ==")
        docker("stop", args.target)

        print(f"== During failure: {args.requests} requests through NGINX ==")
        during = send_burst(base, args.requests)
        print(f"statuses={during['statuses']} instances={during['instances']}")
        errors = sum(n for code, n in during["statuses"].items()
                     if not isinstance(code, int) or code >= 500)
        record("NGINX keeps serving 2xx during the failure",
               during["statuses"].get(200, 0) > 0,
               f"200s={during['statuses'].get(200, 0)} errors={errors} of {args.requests}")
        record("Stopped backend drops out of rotation", args.target not in during["instances"],
               f"instances seen while stopped: {sorted(during['instances'])}")

    finally:
        print(f"\n== Restoring {args.target} ==")
        docker("start", args.target)
        healthy = wait_healthy(args.target, args.recovery_timeout, interval=1.0)
        record(f"{args.target} reports healthy again", healthy,
               f"waited up to {args.recovery_timeout:.0f}s")

    print(f"\n== After recovery: {args.requests} requests through NGINX ==")
    after = send_burst(base, args.requests)
    print(f"statuses={after['statuses']} instances={after['instances']}")
    record("Recovered backend serves requests again", args.target in after["instances"],
           f"instances seen after recovery: {sorted(after['instances'])}")

    passed = sum(1 for _, ok, _ in checks if ok)
    total = len(checks)
    print(f"\n== Summary: {passed}/{total} checks passed ==")
    if passed != total:
        for name, ok, detail in checks:
            if not ok:
                print(f"  - FAILED: {name}: {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())