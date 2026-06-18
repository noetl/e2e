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
