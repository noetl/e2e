# Rust-stack regression runner

`rust_regression_run.sh` is a lightweight regression gate for the **Rust
control plane** (`noetl/server` + `noetl/worker`). It registers + executes a
curated set of fixture playbooks against a running server's HTTP API and prints
a pass/fail matrix; the exit code is the count of non-`COMPLETED` fixtures
(`0` = all green).

It exists alongside the Python-era `fixtures/REGRESSION_TESTING.md` framework
(`master_regression_test.yaml` + pytest), which assumes Python-engine semantics.
This runner drives `/api/execute` directly, so it works against the Rust stack
and points easily at kind or prod.

## Prod-scoped validator (`prod_regression_validate.py`)

`prod_regression_validate.py` is the hardened variant for running against a
**live production** server under the CQRS gate-ON cutover (`PUBLISH_ONLY=true`
+ `STATE_BUILDER=offserver`), where test data is NOT cleanable (no DELETE API,
long retention, shared DB). Differences from the bash runner:

- **Tenant isolation** — registers each fixture under a `prod-e2e-<ts>/`
  catalog-path prefix (rewrites `metadata.path` + any sub-playbook step
  `path`) so every row a run creates is identifiable for operator cleanup.
- **Gate-ON proof per execution** — verifies, directly from the DB via
  `noetl query`, the sole-writer (event rows == distinct ids, 0 `catalog_id=0`,
  0 `__orchestrate__` event rows, ≥1 `__orchestrate__` command) + clean-chain
  (roots=1 / terminals=1 / dangling=0 / head-walk == rows) invariants, plus
  the never-scan invariant (worker
  `noetl_worker_state_builder_event_scans_total` delta 0) and materializer lag
  from `/metrics`.
- **Materialization-aware** — waits for the system-pool materializer to project
  the terminal event before asserting (status flips from in-memory drive state
  a moment before the rows land under PUBLISH_ONLY).

```bash
# port-forward the prod server + system-pool /metrics first, then:
scripts/prod_regression_validate.py --base http://localhost:18082 \
    --prefix prod-e2e-$(date +%Y%m%d-%H%M) --set smoke
scripts/prod_regression_validate.py --base http://localhost:18082 \
    --prefix prod-e2e-$(date +%Y%m%d-%H%M) --set core
```

The `smoke`/`core` sets are credential-free / in-cluster-only fixtures. Fixtures
needing external creds/services (pagination test-server, external HTTP egress,
`pg_local`/`pg_noetl_k8s` unreachable from prod, auth0/amadeus/openai/IB/
snowflake) and the heavy/OOM/burst fixtures are deliberately excluded — see the
script's `SKIP_NOTES`. First validated against live prod 2026-06-20 (server
v3.39.1 / worker v5.40.2): 28/30 executions PASS, the 2 non-PASS being
pg-credential-unreachable env differences (clean `playbook.failed` terminal +
single-root chain — the failure path is gate-ON-correct), not cutover bugs.

## Usage

```bash
# port-forward the Rust server first, e.g. kind:
kubectl --context kind-noetl -n noetl port-forward svc/noetl-server-rust 18082:8082 &

# run the curated green 'core' set (exit 0 when all pass)
scripts/rust_regression_run.sh http://localhost:18082 core

# run an arbitrary newline list of fixture yaml paths
scripts/rust_regression_run.sh http://localhost:18082 my-list.txt
```

## Batched runner

`rust_regression_batched.sh <list> [context] [chunk]` wraps the runner and
**restarts the port-forward per chunk**, so long full-suite sweeps don't fail
when a single `kubectl port-forward` drops (the cause of mass `REG_FAIL` on
150-fixture runs). Aggregates a final tally to `/tmp/batched_results.txt`.

```bash
scripts/rust_regression_batched.sh /tmp/mylist.txt kind-noetl 12
```

## The `core` set

**64 Rust-convention fixtures** — no external cloud APIs/creds, no Python-era
`libs:`/`context.get()`/`data:`-body. All verified green against the Rust
control plane on kind (2026-06-14). Coverage: basic python + args + large
results, loops + iteration isolation, control-flow routing,
vars/templating/transient, retry (python/http/duckdb), fanout/parallelism,
sub-playbook composition, output selection, pagination (8 patterns), duckdb,
http, storage tiers, **and the full postgres-backed batch** (batch execution,
save-storage, psycopg, auth schema, etc.).

### The kind credential-store fix that unlocked the postgres batch

Postgres fixtures were originally flaky — intermittent `Decryption failed`.
Root cause: the kind `noetl-secret` never defined `NOETL_ENCRYPTION_KEY`, so the
server fell back to a **random default key regenerated on every restart**
(`NOETL_ALLOW_INSECURE_DEFAULT_KEY=true`); credentials encrypted before a
restart couldn't decrypt after. Fixed in `noetl/ops`
`ci/manifests/noetl/secret.yaml` (stable dev key) + re-registering credentials
— a postgres fixture went from flaky to consistent green and the suite green
count jumped 40 → 65.

This is the **regression baseline**: grow it by migrating more fixtures to Rust
conventions (tracked in noetl/ai-meta#98).

### Migration patterns (Rust engine vs the Python era)

The same class of fixes done for `auth0_login` (noetl/e2e#51) applies across the
suite:

- **Entry step must be named `start`** — the Rust engine requires it
  (`Workflow must have a step named 'start'`). Rename the entry step and any
  `{{ <old_name> }}` result references. (Migrated `widget_all_types`,
  `pft_queue_db_maintenance` this way.)
- **`libs:` → explicit `import`** in python tool code.
- **`context.get()` → `input:` binding + `args.get()`**.
- **http body `data:` → `json:`**.
- **`python` tool `source.type: inline` → `code:`**.

### Not in `core` (need resources or unsupported kinds)

External-resource fixtures (GCS / OpenAI / external HTTP fetch / IB / local
script files) and ones using tool kinds not ported to Rust (e.g. `kind: agent`
in `spike_e2e_test`) are excluded — they need creds/resources or engine work,
not just convention migration. See noetl/ai-meta#98 for the backlog.

## The `integration` set

```bash
scripts/rust_regression_run.sh http://localhost:18082 integration
```

**12 external-service fixtures** that need **real credentials** and have
**side effects / cost** — NOT part of the exit-0 `core` gate; run deliberately.
Verified green on kind 2026-06-14 with real creds registered (local
`/credentials` dir + GCP Secret Manager, project `noetl-demo-19700101`).

| Fixtures | Credential | Side effect on run |
| --- | --- | --- |
| `amadeus_ai_*` (×4) | Amadeus test API (Secret Manager) | read-only GET — safe |
| `ops/*_ai_*` (×3) | OpenAI/Anthropic (Secret Manager via google-oauth) | **$ per call** |
| `weather_control_flow`, `tooling_non_blocking` | open-meteo / mixed | external HTTP |
| `ibkr_gateway_{verify,maintain}` | `ib_gateway` | brokerage gateway (no-op without a running gateway) |

Register creds first: external-service cred JSONs from the local `credentials`
dir (NOT the `pg_*` ones — those point at prod) + OpenAI/Amadeus from Secret
Manager.

### Known external failures (not in `integration`)

- **Snowflake** (`snowflake_postgres`, `http_to_databases`) — the Rust worker's
  credential resolver doesn't yet handle the `snowflake` credential type
  (`unsupported type 'snowflake'`); tracked + fixed separately.
- **IB trading endpoints** (`gateway_test`, `ibkr/api`, `ibkr/history`) — need a
  live IB gateway; fail on connection in kind.
- `cache_simple` — `malformed tool config` (convention); `spike_e2e_test` —
  `kind: agent` unsupported in the Rust engine.
- `matrixcare_snowflake_prod` fixtures are **deliberately excluded** (prod
  Snowflake).

## Quarantined & known-skip fixtures

Fixtures reconciled during the 2026-07-09 drift sweep. Each carries a banner
comment at the top of its YAML with the same reason.

### Fixed + verified green (2026-07-09 sweep)

- `fixtures/playbooks/data_transfer/http_to_postgres_transfer/http_to_postgres_transfer.yaml`
  — **added to `core`.** Was failing at `transfer_http_to_pg` with
  `Target connection string required`; fixed in noetl-tools 3.19.2
  (noetl/tools#83 — http→postgres assembles the target DSN from alias-resolved
  fields). The `create_table` columns were widened `INTEGER`→`BIGINT` to match
  the tool's i64 integer binding (int4-coercion tool gap tracked in
  noetl/ai-meta#183). Verified green on kind (worker `v5.72.1-transfer3192`):
  100 rows transferred.
- `fixtures/playbooks/batch_execution/multi_playbook_batch/multi_playbook_batch.yaml`
  — **verified green, run on demand (NOT in the `core` gate).** `store_results`
  was rewritten from an unsupported `kind: duckdb` Postgres-ATTACH to a direct
  `kind: postgres` INSERT. It is a composition fixture: it dispatches three
  sub-playbooks (`http_to_postgres_simple`, `control_flow_workbook`,
  `duckdb_gcs_workload_identity/workload_identity`) that must be **pre-registered**,
  and the last needs the **GCS workload-identity bridge** (integration-tier), so
  it's kept out of the self-contained exit-0 `core` gate. Register the three
  sub-playbooks first, then execute `batch_execution/multi_playbook_batch`.

None of the entries below are in `core` / `integration` — do not add them back
without clearing the blocker.

### Quarantined (retired capability — will not run)

| Fixture | Reason |
| --- | --- |
| `fixtures/playbooks/spike/spike_e2e_test.yaml` | Uses `tool: agent` + `framework: noetl` (step `trigger_failure`). `kind: agent` is **not** a Rust `ToolDefinition` variant — there is no `agent.rs`. The NoETL-as-AI-OS agent-framework spike (auto-dispatch-on-failure, self-troubleshoot agent, Ollama triage bridge) was never ported to the Rust engine. Kept in-tree as documentation of the retired capability, not as a runnable test. Revive only if the agent framework is ported. |

### Un-skipped 2026-08-05 — `container_postgres_init`

Runnable. It was the only fixture exercising `kind: container` end-to-end with
`env:` and cross-step data dependencies, and it stayed skipped through two
distinct blockers:

1. **The image never loaded on podman.** `kind load docker-image` looks the image
   up by the exact name; podman qualifies a locally-built `noetl/...` as
   `docker.io/noetl/...`, so the load failed seconds after the build succeeded.
   podman is this project's runtime — `noetl-dev` has no docker — so nobody
   following the setup could build it (noetl/e2e#91).
2. **The DAG did not gate on container completion**
   ([noetl/ai-meta#186](https://github.com/noetl/ai-meta/issues/186) Bug 1).
   Fixed in server **v3.64.1**; see that issue for the root cause.

**Requirements to run it:**

- server **>= 3.64.1** — earlier builds dispatch every container step at once.
- A completion path: either the external `noetl-k8s-watcher`, or
  `NOETL_CONTAINER_COMPLETION_POLL=true` on the worker. ⚠ The flag accepts only
  `1`/`true`/`yes`/`on`; a cadence-looking value such as `2` silently means OFF
  and the execution parks forever (worker warns as of noetl/worker#231).

Verified on kind with released multi-arch images (server 3.64.1 / worker 5.97.0):
Jobs created at +0s / +7s / +15s, each after its predecessor completed, and a
deliberate container failure produced `FAILED` rather than `COMPLETED`.

### Known-skip (blocked on a missing dependency — DSL modernized, not yet runnable)

DSL modernized to current Rust syntax so they no longer carry stale drift, but
left out of the suite pending the dependency. One follow-up issue each.

| Fixture | Blocker | Follow-up |
| --- | --- | --- |
| `fixtures/playbooks/tradedb/tradedb_create_db.yaml` | DDL lives in absent private IQT submodule (`./submodules/IQT/scripts/tradedb/create_tradedb.sql`). DSL modernized: `script:{uri,source:{type:file}}` + `with:` → inline `command:` (placeholder body). | noetl/ai-meta#181 |
| `fixtures/playbooks/tradedb/tradedb_bootstrap.yaml` | DDL + dictionaries SQL in absent private IQT submodule. DSL modernized as above (two steps). | noetl/ai-meta#182 |
