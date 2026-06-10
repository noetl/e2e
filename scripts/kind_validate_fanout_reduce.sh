#!/usr/bin/env bash
# kind_validate_fanout_reduce.sh — Phase D R4 kind-val
# (noetl/ai-meta#49 Phase D R4 → noetl/e2e#31).
#
# End-to-end kind-val rig that proves the orchestrator's fan-in /
# reduce barrier (server#143 + server#145, v2.49.0 → v2.50.0)
# actually gates dispatch until both upstream branches finish:
#
#     start ──┬─ normalize_customer ─┐
#             │                      ├─ reduce_customer ─ end
#             └─ enrich_customer ────┘
#
# Pre-PR the orchestrator dispatched `reduce_customer` on the FIRST
# completing upstream — never seeing the other branch's result.
# This rig asserts the barrier prevented double dispatch + ordered
# the reduce step after both upstreams.
#
# Assertions (all required for PASS):
#
#   1. Final execution status is COMPLETED.
#   2. Event log contains EXACTLY ONE `step.enter` for
#      `reduce_customer` (the barrier worked — no double dispatch
#      on first-upstream-done).
#   3. The `reduce_customer.command.completed` event arrives AFTER
#      both branches' `command.completed` events (the orchestrator
#      waited for both upstreams; the timestamps prove it).
#
# Usage:
#
#   ./scripts/kind_validate_fanout_reduce.sh
#   ./scripts/kind_validate_fanout_reduce.sh --context kind-noetl
#   NOETL_KIND_CONTEXT=kind-foo ./scripts/kind_validate_fanout_reduce.sh
#
# Exits 0 if PASS; 1 if any assertion fails (dumps server +
# worker logs on the unhappy path for diagnosis).

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_DEPLOY="${NOETL_WORKER_DEPLOY:-noetl-worker-rust}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_FANOUT_TIMEOUT_SECS:-180}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)        KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --server-url)     NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)        TIMEOUT_SECS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'
      exit 0
      ;;
    *)
      echo "kind-val: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_PATH="$REPO_ROOT/fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml"
PLAYBOOK_PATH="tests/fixtures/fanout_reduce_phase6"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: server=$NOETL_SERVER_URL"
echo "kind-val: fixture=$FIXTURE_PATH"

# ----------------------------------------------------------------------
# Preflight — required tooling + cluster + server reachable.
# ----------------------------------------------------------------------

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "kind-val: required command not in PATH: $cmd" >&2
    exit 2
  }
done

# CLI-surface guard.  This rig drives the current noetl command
# surface: `register playbook`, `exec`, `status`, `query`.  That
# surface is stable from CLI v2.17.0 through the v4.x line (the
# repos/cli submodule).  Older binaries exposed `noetl playbook
# register/execute` + `noetl execution status/events`, which were
# removed — fail fast with a clear message rather than aborting
# mid-run on `error: unrecognized subcommand`.
for sub in "register playbook" "exec" "status" "query"; do
  if ! noetl $sub --help >/dev/null 2>&1; then
    echo "kind-val: this rig needs the current noetl CLI surface" >&2
    echo "kind-val: missing subcommand: noetl $sub" >&2
    echo "kind-val: installed CLI: $(noetl --version 2>/dev/null || echo unknown)" >&2
    echo "kind-val: expected surface — register playbook / exec / status / query (CLI >= v2.17.0)." >&2
    exit 2
  fi
done

if [[ ! -f "$FIXTURE_PATH" ]]; then
  echo "kind-val: fixture not found: $FIXTURE_PATH" >&2
  exit 2
fi

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

if ! "${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1; then
  echo "kind-val: $NOETL_SERVER_DEPLOY Deployment not found in namespace $NAMESPACE." >&2
  exit 2
fi

if ! curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "kind-val: server not reachable at $NOETL_SERVER_URL/api/health — start a port-forward first." >&2
  exit 2
fi

# ----------------------------------------------------------------------
# Register + execute the fixture.
# ----------------------------------------------------------------------

echo
echo "================================================================"
echo "kind-val: register + execute fanout_reduce_phase6"
echo "================================================================"

noetl register playbook --file "$FIXTURE_PATH"

# Exec by the catalog *path* (metadata.path), not the bare name —
# distributed runtime resolves the path against the catalog.
# `--json` emits a single JSON object: {"execution_id": ..., ...}.
EXECUTION_ID="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
echo "kind-val: launched execution_id=$EXECUTION_ID"

# ----------------------------------------------------------------------
# Wait for terminal status.
# ----------------------------------------------------------------------

DEADLINE=$(( SECONDS + TIMEOUT_SECS ))
FINAL_STATUS=""
while [[ $SECONDS -lt $DEADLINE ]]; do
  FINAL_STATUS="$(noetl status "$EXECUTION_ID" --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""))' || true)"
  case "$FINAL_STATUS" in
    COMPLETED|FAILED) break ;;
  esac
  sleep 2
done
echo "kind-val: execution_id=$EXECUTION_ID final_status=$FINAL_STATUS"

# ----------------------------------------------------------------------
# Pull the event log + run barrier assertions.
# ----------------------------------------------------------------------

# No CLI `events` verb today — pull the event log over the Postgres
# query API.  `noetl query` wraps the rows under `.result`; order by
# `event_id` (monotonic, commit-ordered) since `noetl.event` has no
# `timestamp` column.  The assertions below unwrap `.result`.
EVENTS_JSON="$(noetl query \
  "SELECT event_id, event_type, node_name, event_time FROM noetl.event WHERE execution_id = $EXECUTION_ID ORDER BY event_id" \
  --format json 2>/dev/null || echo '{"result": []}')"

OVERALL=0
fail() {
  echo "kind-val: FAIL — $1" >&2
  OVERALL=1
}

# Assertion 1: final status COMPLETED.
if [[ "$FINAL_STATUS" != "COMPLETED" ]]; then
  fail "expected final status COMPLETED, got $FINAL_STATUS"
fi

# Assertion 2: exactly one step.enter for reduce_customer.
REDUCE_ENTERS="$(printf '%s' "$EVENTS_JSON" | python3 -c '
import json, sys
events = json.loads(sys.stdin.read() or "{}").get("result", [])
count = sum(1 for e in events
            if e.get("event_type") == "step.enter"
            and e.get("node_name") == "reduce_customer")
print(count)
')"
if [[ "$REDUCE_ENTERS" != "1" ]]; then
  fail "expected exactly 1 step.enter for reduce_customer (barrier should prevent double-dispatch); got $REDUCE_ENTERS"
fi

# Assertion 3: reduce_customer.command.completed AFTER both branches'
# command.completed.  Compares `event_id` (monotonic, commit-ordered);
# reduce's last completion id must be strictly greater than the MAX of
# the branches'.
ORDER_OK="$(printf '%s' "$EVENTS_JSON" | python3 -c '
import json, sys
events = json.loads(sys.stdin.read() or "{}").get("result", [])

def latest_completion(name):
    ts = [e.get("event_id") for e in events
          if e.get("event_type") == "command.completed"
          and e.get("node_name") == name]
    return max(ts) if ts else None

a = latest_completion("normalize_customer")
b = latest_completion("enrich_customer")
r = latest_completion("reduce_customer")
if not a or not b or not r:
    print(f"MISSING (a={a!r} b={b!r} r={r!r})")
elif r > a and r > b:
    print("OK")
else:
    print(f"OUT-OF-ORDER (a={a} b={b} r={r})")
')"
if [[ "$ORDER_OK" != "OK" ]]; then
  fail "barrier ordering check: $ORDER_OK"
fi

# ----------------------------------------------------------------------
# Report.
# ----------------------------------------------------------------------

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — Phase D R4 fan-in / reduce barrier green"
  echo "  - final_status=COMPLETED"
  echo "  - exactly 1 step.enter for reduce_customer"
  echo "  - reduce_customer.command.completed AFTER both upstreams"
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo
echo "kind-val: worker logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_WORKER_DEPLOY" --tail=80 || true
exit 1
