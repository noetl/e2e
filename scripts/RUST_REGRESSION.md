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

## The `core` set

Self-contained, Rust-convention fixtures — no external APIs, cloud creds, or
Python-era `libs:` / `context.get()` / `data:`-body blocks. Verified green
against the Rust control plane on kind (2026-06-14). Coverage: basic python,
loops, control-flow routing, fanout/parallelism, sub-playbook composition,
large-result extraction, output selection.

This is the **regression baseline**: grow it by migrating more fixtures to Rust
conventions (tracked in noetl/ai-meta#98). Known Python-era failures the broader
suite still has — `data:`→`json:` http bodies, `libs:`→explicit `import`,
`context.get()`→`input:`/`args`, `python` tool `source.type: inline` configs —
are the same class fixed for `auth0_login` (noetl/e2e#51).
