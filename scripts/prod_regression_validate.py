#!/usr/bin/env python3
"""Prod-scoped Rust regression validator for the CQRS gate-ON cutover.

Companion to rust_regression_run.sh, hardened for running against a LIVE
production server where test data is NOT cleanable (no DELETE API, long
retention, shared DB). It:

  1. Registers each fixture under a dedicated ``prod-e2e-<ts>/`` catalog-path
     prefix (rewriting metadata.path + any sub-playbook step path) so every
     row this run creates is identifiable by the prefix for operator cleanup.
  2. Executes each fixture and polls to a terminal status.
  3. Proves, per execution, the gate-ON invariants directly from the DB
     (via ``noetl query``):
       - COMPLETED
       - sole-writer: event rows == distinct ids, 0 catalog_id=0 rows,
         0 __orchestrate__ event rows, >=1 __orchestrate__ command
       - clean chain: roots=1, terminals=1, dangling=0, head-walk == rows
     plus, from /metrics, the never-scan invariant (worker
     ``noetl_worker_state_builder_event_scans_total`` delta == 0) and the
     materializer lag gauge.

Verification is materialization-aware: under PUBLISH_ONLY the server flips
status from in-memory drive state a moment before the system-pool materializer
projects the rows to noetl.event, so verify() waits for the terminal event to
land before asserting.

Usage:
  scripts/prod_regression_validate.py --base http://localhost:18082 \
      --prefix prod-e2e-$(date +%Y%m%d-%H%M) --set smoke

  # explicit fixture list
  scripts/prod_regression_validate.py --base ... --prefix ... \
      fixtures/playbooks/hello_world/hello_world.yaml ...

Sets:
  smoke    credential-free, light: python / args / vars / loops / output / large-result
  core     smoke + control-flow / actions / fan-out-reduce / duckdb / http(in-cluster) /
           save-to-postgres / sub-playbook composition

NOT run against prod (need external creds/services or are heavy/OOM/burst —
see SKIP_NOTES): pagination/* (needs paginated-api.test-server.svc),
http_to_postgres_* (external egress + pg_local), save_simple/save_all/storage_tiers
(pg_local / #101 bloat), auth0/google_id_token/amadeus/openai/IB/snowflake
(external creds), server_oom_stress_*/heavy_payload_*/heavy_loop_aggregation/
lease_expiry (heavy/OOM/#101).

Requires the ``noetl`` Rust CLI on PATH (or NOETL_BIN) and a server + system-pool
/metrics port-forward for the never-scan/lag checks (optional; --no-metrics skips).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

NOETL = os.environ.get("NOETL_BIN") or shutil.which("noetl") or "noetl"

SMOKE = [
    "fixtures/playbooks/hello_world/hello_world.yaml",
    "fixtures/playbooks/simple_python.yaml",
    "fixtures/playbooks/test_args_passing.yaml",
    "fixtures/playbooks/vars_test/test_vars_simple.yaml",
    "fixtures/playbooks/loop_test.yaml",
    "fixtures/playbooks/test_output_select.yaml",
    "fixtures/playbooks/test_large_result_extraction.yaml",
]

CORE_EXTRA = [
    "fixtures/playbooks/control_flow_workbook/control_flow_workbook.yaml",
    "fixtures/playbooks/root_scripts/test_implicit_end_routing.yaml",
    "fixtures/playbooks/root_scripts/test_simple_loop.yaml",
    "fixtures/playbooks/test_loop_instance_isolation/playbook.yaml",
    "fixtures/playbooks/vars_test/test_vars_api.yaml",
    "fixtures/playbooks/vars_test/test_vars_block.yaml",
    "fixtures/playbooks/vars_test/test_transient.yaml",
    "fixtures/playbooks/test_end_with_action.yaml",
    "fixtures/playbooks/test_start_with_action.yaml",
    "fixtures/playbooks/actions_test.yaml",
    "fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml",
    "fixtures/playbooks/duckdb_test.yaml",
    "fixtures/playbooks/http_test.yaml",
    "fixtures/playbooks/json_serialization_save.yaml",
]

SKIP_NOTES = {
    "pagination/*": "needs paginated-api.test-server.svc (kind-only test server)",
    "http_to_postgres_*": "external jsonplaceholder egress + pg_local",
    "save_simple/save_all/storage_tiers": "pg_local; storage_tiers also #101 bloat",
    "auth0/google_id_token/amadeus/openai/IB/snowflake": "external creds/services",
    "server_oom_stress_*/heavy_payload_*/heavy_loop_aggregation/lease_expiry": "heavy/OOM/#101 — avoid against prod",
}


def http_post(base, path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def http_get(url, timeout=15):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode()


def nq(base_host, base_port, sql):
    p = subprocess.run([NOETL, "--host", base_host, "--port", base_port, "query", sql, "--format", "json"],
                       capture_output=True, text=True, timeout=60)
    try:
        return json.loads(p.stdout).get("result", [])
    except Exception:
        return []


def n1(h, p, sql):
    r = nq(h, p, sql)
    return int(r[0]["n"]) if r and r[0].get("n") is not None else 0


def metric(url, name, label=None):
    total = 0.0
    try:
        body = http_get(url)
    except Exception:
        return None
    for line in body.splitlines():
        if not line.startswith(name):
            continue
        rest = line[len(name):]
        if rest and rest[0] not in "{ ":
            continue
        if label and ('"%s"' % label) not in line:
            continue
        try:
            total += float(line.rsplit(None, 1)[1])
        except Exception:
            pass
    return total


def prefix_paths(content, prefix):
    import yaml
    doc = yaml.safe_load(content)
    doc["metadata"]["path"] = prefix + "/" + doc.get("metadata", {}).get("path", "")

    def walk(o):
        if isinstance(o, dict):
            if o.get("kind") == "playbook" and isinstance(o.get("path"), str):
                o["path"] = prefix + "/" + o["path"]
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(doc.get("workflow", []))
    return yaml.safe_dump(doc, sort_keys=False), doc["metadata"]["path"]


def verify(h, p, eid, wait=40):
    deadline = time.time() + wait
    prev, stable = -1, 0
    while time.time() < deadline:
        t = n1(h, p, "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = %s" % eid)
        term = n1(h, p, "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = %s AND event_type IN "
                  "('playbook.completed','playbook_completed','playbook.failed','playbook_failed',"
                  "'playbook.cancelled','playbook_cancelled')" % eid)
        if t > 0 and term >= 1 and t == prev:
            stable += 1
            if stable >= 2:
                break
        else:
            stable = 0
        prev = t
        time.sleep(2)
    q = lambda s: n1(h, p, s)
    total = q("SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = %s" % eid)
    distinct = q("SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = %s" % eid)
    cat0 = q("SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = %s AND catalog_id = 0" % eid)
    roots = q("SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = %s AND prev_event_id IS NULL" % eid)
    orch_ev = q("SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = %s AND node_name = '__orchestrate__'" % eid)
    orch_cmd = q("SELECT COUNT(*) AS n FROM noetl.command WHERE execution_id = %s AND step_name = '__orchestrate__'" % eid)
    term = q("SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = %s AND event_type IN "
             "('playbook.completed','playbook_completed','playbook.failed','playbook_failed',"
             "'playbook.cancelled','playbook_cancelled')" % eid)
    dang = q("SELECT COUNT(*) AS n FROM noetl.event e WHERE e.execution_id = %s AND e.prev_event_id IS NOT NULL "
             "AND NOT EXISTS (SELECT 1 FROM noetl.event p WHERE p.execution_id = %s AND p.event_id = e.prev_event_id)" % (eid, eid))
    walk = q("WITH RECURSIVE head AS (SELECT event_id, prev_event_id FROM noetl.event WHERE execution_id = %s "
             "AND event_id NOT IN (SELECT prev_event_id FROM noetl.event WHERE execution_id = %s AND prev_event_id IS NOT NULL)), "
             "walk AS (SELECT event_id, prev_event_id FROM head UNION SELECT e.event_id, e.prev_event_id FROM noetl.event e "
             "JOIN walk w ON e.execution_id = %s AND e.event_id = w.prev_event_id) SELECT COUNT(*) AS n FROM walk" % (eid, eid, eid))
    sole = total > 0 and total == distinct and cat0 == 0 and orch_ev == 0 and orch_cmd >= 1
    chain = roots == 1 and term == 1 and dang == 0 and walk == total
    return dict(total=total, distinct=distinct, cat0=cat0, roots=roots, terminals=term,
                dangling=dang, walk=walk, orch_ev=orch_ev, orch_cmd=orch_cmd, sole=sole, chain=chain)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:18082")
    ap.add_argument("--prefix", required=True, help="catalog-path tenant prefix, e.g. prod-e2e-20260620-1946")
    ap.add_argument("--set", dest="fset", default="smoke", choices=["smoke", "core"])
    ap.add_argument("--worker-metrics", default="http://localhost:19091/metrics")
    ap.add_argument("--no-metrics", action="store_true")
    ap.add_argument("fixtures", nargs="*")
    a = ap.parse_args()
    base = a.base.rstrip("/")
    host = base.split("//")[-1].split(":")[0]
    port = base.rsplit(":", 1)[-1]

    files = a.fixtures or (SMOKE if a.fset == "smoke" else SMOKE + CORE_EXTRA)
    w_scan0 = None if a.no_metrics else metric(a.worker_metrics, "noetl_worker_state_builder_event_scans_total")

    results = []
    for fx in files:
        try:
            content, new_path = prefix_paths(open(fx).read(), a.prefix)
            path = http_post(base, "/api/catalog/register", {"content": content}).get("path") or new_path
            eid = http_post(base, "/api/execute", {"path": path}).get("execution_id")
        except Exception as e:
            print("%-50s REG/EXEC_FAIL %s" % (fx.split("playbooks/")[-1], str(e)[:60]))
            results.append(dict(fx=fx, status="REG/EXEC_FAIL", verdict="FAIL"))
            continue
        st = "RUNNING"
        deadline = time.time() + 150
        while time.time() < deadline:
            try:
                st = json.loads(http_get("%s/api/executions/%s" % (base, eid), 10)).get("status", "?")
            except Exception:
                st = "?"
            if st in ("COMPLETED", "FAILED"):
                break
            time.sleep(3)
        v = verify(host, port, eid)
        ok = st == "COMPLETED" and v["sole"] and v["chain"]
        verdict = "PASS" if ok else "FAIL"
        results.append(dict(fx=fx, eid=str(eid), status=st, verdict=verdict, **v))
        lag = "" if a.no_metrics else (" lag=%g" % (metric(a.worker_metrics, "noetl_worker_nats_consumer_pending", "noetl_materializer") or 0))
        print("%-50s %-9s %-5s eid=%s rows=%d/%d roots=%d term=%d dang=%d walk=%d orch_ev=%d/cmd=%d%s" % (
            fx.split("playbooks/")[-1], st, verdict, eid, v["total"], v["distinct"], v["roots"],
            v["terminals"], v["dangling"], v["walk"], v["orch_ev"], v["orch_cmd"], lag))

    npass = sum(1 for r in results if r["verdict"] == "PASS")
    if not a.no_metrics:
        w_scan1 = metric(a.worker_metrics, "noetl_worker_state_builder_event_scans_total")
        if w_scan0 is not None and w_scan1 is not None:
            print("\nnever-scan: worker_state_builder_event_scans delta +%g (want 0)" % (w_scan1 - w_scan0))
    print("=== %d/%d PASS (prefix %s) ===" % (npass, len(results), a.prefix))
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
