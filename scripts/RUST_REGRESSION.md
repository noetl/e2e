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
