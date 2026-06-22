---
id: local-kind
title: Local Kind Cluster
---

Use the local `kind-noetl` cluster for distributed e2e runs.

## Health Check

```bash
kubectl config current-context
kubectl get pods --all-namespaces
curl http://localhost:8082/health
```

The NoETL endpoint used by the fixture commands is usually `localhost:8082`.

## Redeploy

When refreshing NoETL images and Kubernetes resources, prefer the ops automation playbook from `repos/ops`:

```bash
cd ../ops
noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl
```

This keeps local validation aligned with project automation defaults.

## Topology Validation

`scripts/kind_validate_*.sh` are self-contained kind rigs that assert a
specific runtime property, not just a green playbook. Run them against a
port-mapped server (`localhost:8082`) on `kind-noetl`.

### Worker-driven orchestrate (server-as-API-only step 2)

`scripts/kind_validate_orchestrate_offserver.sh` proves the orchestrator
drive runs **off the server, on the system worker pool**, as the
`system/orchestrate` WASM plug-in — the default-on topology after server
v3.28.0 ([noetl/ai-meta#108](https://github.com/noetl/ai-meta/issues/108))
plus the in-server shadow / wasmtime retirement
([noetl/ai-meta#110](https://github.com/noetl/ai-meta/issues/110)). It runs
the self-contained fan-out fixture (several orchestrate rounds) and asserts:

- Final status `COMPLETED`.
- **Zero** `__orchestrate__` rows in `noetl.event` (no event-log burst — the
  scale-critical property of the off-server drive).
- `__orchestrate__` rows present in `noetl.command` (the drive was dispatched
  to the pool, not evaluated in-process).
- `noetl_orchestrate_drive_total{stage="dispatched"}` and `{stage="applied"}`
  both advanced with no `decode_error` — the server scheduled the drive and
  applied a **worker-computed** result, i.e. it ran off-server.
- `noetl_orchestrate_shadow_total` is absent — confirms a post-#110 image.

```bash
# requires a post-#110 server image with the drive ON (code default, or
# NOETL_ORCHESTRATE_PLUGIN_DRIVE=true) reachable at localhost:8082
scripts/kind_validate_orchestrate_offserver.sh --context kind-noetl
```

Exit `0` = PASS; `1` = a hard assertion failed (dumps server + both worker
pools' logs); `2` = precondition error (missing CLI / server unreachable).

### Off-server drive under the CQRS PUBLISH_ONLY gate

`scripts/kind_validate_orchestrate_gate.sh` proves the off-server drive
composes with the CQRS write-path gate — the combination
[noetl/ai-meta#103](https://github.com/noetl/ai-meta/issues/103) left
unproven (gate-on was only ever validated with the in-process drive) and
the [noetl/ai-meta#104](https://github.com/noetl/ai-meta/issues/104)
off-server-drive × gate reconciliation. It requires the server with
`NOETL_EVENT_INGEST_PUBLISH_ONLY=true` **and**
`NOETL_ORCHESTRATE_PLUGIN_DRIVE=true`, and the system pool with
`NOETL_MATERIALIZER_ENABLED=true` (the in-process materializer loop is the
sole `noetl.event` writer). On a **clean** cluster it runs the fan-out
fixture and asserts:

- Final status `COMPLETED` — read-your-writes held: the relocated trigger
  fires from the materializer's write endpoint *after* the row lands, so the
  server rebuilds `WorkflowState` from committed state before bounding the
  off-server drive input.
- The server **published** the run's events instead of inserting them
  (`noetl_event_ingest_published_total` advanced by ≥ the run's event count).
- Materializer is the **sole writer**, no loss / no double-write: the
  `noetl.event` row count equals the distinct-`event_id` count.
- Zero events with `catalog_id = 0` (the `get_catalog_id` `noetl.command`
  fallback under the gate works — server#236).
- Off-server topology under the gate: `0` `__orchestrate__` rows in
  `noetl.event`, `>0` in `noetl.command`.
- Drive metric: `dispatched` + `applied` advanced; `decode_error` and
  `cold_rebuild_failed` did not.
- The materializer reported `duplicates=0` across the run.

```bash
# clean the cluster first (truncate execution-state tables, purge noetl_events)
# then, with the gate + drive + materializer env on, reachable at localhost:8082:
scripts/kind_validate_orchestrate_gate.sh --context kind-noetl
```

Exit codes match the rig above.

### Canonical result-URI shadow accept (#104 Phase A)

`scripts/kind_validate_result_uri_accept.sh` proves
[noetl/ai-meta#104](https://github.com/noetl/ai-meta/issues/104) Phase A —
the server *accepts* the canonical logical result URI the worker stamps on
over-budget references (`reference.uri = noetl://<tenant>/<project>/results/
<eid>/<step>/<frame>/<row>/<attempt>`) without yet resolving by it (Phase C)
or writing the Feather tier (Phase B). It requires the same off-server gate
stack as the rig above, PLUS a server image carrying `NOETL_RESULT_URI_ACCEPT`
+ the `noetl_result_uri_accept_total` metric. On the embedded-NATS kind
topology it rolls the workers after each server env flip (so they
re-establish their `noetl_events` consumers against the fresh NATS) and runs
the over-budget producer `tests/large_result_extraction_test` twice:

- **Flag ON** (`NOETL_RESULT_URI_ACCEPT=true`) — the event carries a
  canonical `reference.uri`, `noetl_result_uri_accept_total{outcome="canonical"}`
  advances ≥1, `{outcome="malformed"}` stays 0, the execution `COMPLETED`,
  and the sole-writer invariants hold (per-exec `event_rows == distinct ids`,
  `catalog_id=0` rows 0, `__orchestrate__` rows 0, materializer `duplicates=0`).
- **Flag OFF** (`NOETL_RESULT_URI_ACCEPT=false`) — the same fixture still
  externalizes, the accept counter delta is `0` (true no-op), the execution
  still `COMPLETED`, and the invariants still hold — Phase A perturbs neither
  the drive nor the materialize path.

```bash
# with the gate + drive + materializer env on, reachable at localhost:8082,
# and a server image carrying the Phase-A flag:
scripts/kind_validate_result_uri_accept.sh --context kind-noetl
```

Exit codes match the rigs above.
