#!/usr/bin/env python3
"""Contract check for the test-server fixture (fixtures/servers/paginated_api.py).

PFT must emulate the real API: one HTTP request returns one record.

* default: /api/v1/pft/batch/{data_type} answers 410 Gone, for both the
  comma-separated and the repeated-parameter form;
* /api/v1/pft/mds/details returns exactly one row;
* with PFT_BATCH_BENCHMARK=1 the opt-in benchmark batch handler is routed.

The same requests are made by the ops dev playbook's
verify_test_server_contract after every test-server deploy. Each mode imports
the app in a fresh subprocess (the flag is read at import time) and serves it
with uvicorn on a free loopback port. Needs only fastapi + uvicorn, the
test-server image's own dependencies.
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "fixtures" / "servers" / "paginated_api.py"

COMMA = "/api/v1/pft/batch/assessments?patientIds=1,2&pageSize=1"
REPEATED = "/api/v1/pft/batch/assessments?patientIds=1&patientIds=2&pageSize=1&patientsPerFacility=1000"
MDS = "/api/v1/pft/mds/details?assessmentId=MDS-contract-check"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def get(base: str, path: str):
    try:
        with urllib.request.urlopen(base + path, timeout=10) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, None


def serve(env_extra: dict):
    port = free_port()
    env = dict(os.environ, **env_extra)
    env.setdefault("PFT_BATCH_BENCHMARK", "")
    code = (
        "import importlib.util, sys, uvicorn;"
        f"spec = importlib.util.spec_from_file_location('paginated_api', {str(SERVER)!r});"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m);"
        f"uvicorn.run(m.app, host='127.0.0.1', port={port}, log_level='warning')"
    )
    proc = subprocess.Popen([sys.executable, "-c", code], env=env)
    base = f"http://127.0.0.1:{port}"
    deadline = time.time() + 30
    while time.time() < deadline:
        if proc.poll() is not None:
            raise SystemExit(f"test-server exited early with {proc.returncode}")
        try:
            if get(base, "/health")[0] == 200:
                return proc, base
        except OSError:
            pass
        time.sleep(0.2)
    proc.kill()
    raise SystemExit("test-server did not become healthy in 30s")


def check(failures: list, cond: bool, msg: str):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)


def main() -> int:
    failures: list = []

    proc, base = serve({})
    try:
        for label, path in (("comma-separated", COMMA), ("repeated-param", REPEATED)):
            status, _ = get(base, path)
            check(failures, status == 410, f"default: {label} batch request -> {status} (want 410)")
        status, body = get(base, MDS)
        check(failures, status == 200 and (body or {}).get("rowCount") == 1,
              f"default: single MDS detail -> {status}, rowCount={(body or {}).get('rowCount')} (want 200, 1)")
    finally:
        proc.terminate(); proc.wait(10)

    proc, base = serve({"PFT_BATCH_BENCHMARK": "1"})
    try:
        status, body = get(base, COMMA)
        check(failures, status == 200 and (body or {}).get("patientCount") == 2,
              f"PFT_BATCH_BENCHMARK=1: comma-separated batch -> {status}, "
              f"patientCount={(body or {}).get('patientCount')} (want 200, 2)")
    finally:
        proc.terminate(); proc.wait(10)

    print(f"test-server contract: {4 - len(failures)}/4 checks ok")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
