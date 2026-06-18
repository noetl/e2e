#!/usr/bin/env bash
# kind_validate_orchestrate_offserver.sh — worker-driven orchestrate topology
# (noetl/ai-meta#108 + #110 → the Server-Dissolution program noetl/ai-meta#107
# step 2).
#
# Proves the NoETL orchestrator drive runs OFF the server, on the system worker
# pool, as the `system/orchestrate` WASM plug-in — the default-on topology after
# server v3.28.0 (#108 (c)) + the shadow/wasmtime retirement (#110, server
# f3043c9). Where `kind_validate_fanout_reduce.sh` asserts the orchestrator's
# fan-in barrier is *correct*, this rig asserts *where it runs*: the server only
# schedules + applies, and the evaluate loop executes on the pool, writing zero
# `__orchestrate__` rows to noetl.event.
#
# It reuses the self-contained fan-out fixture (start ─┬─ normalize ─┐
#                                                      └─ enrich ────┴─ reduce ─ end),
# which drives several orchestrate rounds with a concurrent fan-out — enough to
# exercise the dispatch → off-server-evaluate → apply round trip multiple times.
#
# Assertions (all required for PASS):
#
#   1. Final execution status is COMPLETED — the worker-driven drive carried the
#      execution to a terminal state with no in-process evaluate.
#   2. ZERO `__orchestrate__` rows in noetl.event for this execution. This is the
#      scale-critical property: the meta-command's lifecycle is infrastructure,
#      not a workflow step, so it never bursts the event log (#108 slices 4b/5).
#   3. `__orchestrate__` rows EXIST in noetl.command for this execution — the
#      drive was dispatched as commands to the pool, not evaluated in-process.
#   4. Server /metrics: `noetl_orchestrate_drive_total{stage="dispatched"}` and
#      `{stage="applied"}` both advanced during the run (the server scheduled the
#      drive AND applied a worker-computed result — i.e. it ran off-server), with
#      no `decode_error`.
#   5. Server /metrics: `noetl_orchestrate_shadow_total` is ABSENT — the in-server
#      wasmtime shadow was retired in #110; its presence would mean a pre-#110
#      image is deployed.
#   6. (informational) System-pool isolation: the system-pool worker shows
#      orchestrate-plugin activity; the default (user) worker pool ran no
#      `__orchestrate__` meta-step.
#
# Preconditions: the kind server must run a post-#110 image (server f3043c9 /
# v3.28.0 or later) with the worker-driven drive ON — either the code default
# (no env) or `NOETL_ORCHESTRATE_PLUGIN_DRIVE=true`. A server built before #108
# (drive=false) will fail assertions 3-4; a pre-#110 image will fail assertion 5.
#
# Usage:
#
#   ./scripts/kind_validate_orchestrate_offserver.sh
#   ./scripts/kind_validate_orchestrate_offserver.sh --context kind-noetl
#   NOETL_SERVER_URL=http://localhost:18082 ./scripts/kind_validate_orchestrate_offserver.sh
#
# Exits 0 if PASS; 1 if any hard assertion fails (dumps server + both worker
# pools' logs on the unhappy path for diagnosis); 2 on a precondition error.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_DEPLOY="${NOETL_WORKER_DEPLOY:-noetl-worker-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-180}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
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

for sub in "register playbook" "exec" "status" "query"; do
  if ! noetl $sub --help >/dev/null 2>&1; then
    echo "kind-val: this rig needs the current noetl CLI surface" >&2
    echo "kind-val: missing subcommand: noetl $sub" >&2
    echo "kind-val: installed CLI: $(noetl --version 2>/dev/null || echo unknown)" >&2
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
# Helper: read one stage counter from the server's /metrics endpoint.
#   metrics_drive <stage>  -> integer (0 if the series is absent)
# ----------------------------------------------------------------------

fetch_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

metrics_drive() {
  local stage="$1" body="$2"
  printf '%s' "$body" | python3 -c '
import re, sys
stage = sys.argv[1]
total = 0
for line in sys.stdin:
    m = re.match(r"noetl_orchestrate_drive_total\{stage=\"([^\"]+)\"\}\s+([0-9.]+)", line)
    if m and m.group(1) == stage:
        total += int(float(m.group(2)))
print(total)
' "$stage"
}

metrics_has_shadow() {
  printf '%s' "$1" | grep -q "noetl_orchestrate_shadow_total" && echo yes || echo no
}

# ----------------------------------------------------------------------
# Snapshot drive metrics BEFORE the run so the deltas are attributable to
# this execution (the counters are process-cumulative across all runs).
# ----------------------------------------------------------------------

METRICS_BEFORE="$(fetch_metrics)"
DISPATCHED_BEFORE="$(metrics_drive dispatched "$METRICS_BEFORE")"
APPLIED_BEFORE="$(metrics_drive applied "$METRICS_BEFORE")"
DECODE_ERR_BEFORE="$(metrics_drive decode_error "$METRICS_BEFORE")"
SHADOW_PRESENT="$(metrics_has_shadow "$METRICS_BEFORE")"
echo "kind-val: drive metrics before — dispatched=$DISPATCHED_BEFORE applied=$APPLIED_BEFORE decode_error=$DECODE_ERR_BEFORE shadow_series=$SHADOW_PRESENT"

# ----------------------------------------------------------------------
# Register + execute the fan-out fixture (drives several orchestrate rounds).
# ----------------------------------------------------------------------

echo
echo "================================================================"
echo "kind-val: register + execute fanout_reduce_phase6 (off-server drive)"
echo "================================================================"

noetl register playbook --file "$FIXTURE_PATH"

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

# Give the apply round-trip a moment to flush the final metric increment.
sleep 3
METRICS_AFTER="$(fetch_metrics)"
DISPATCHED_AFTER="$(metrics_drive dispatched "$METRICS_AFTER")"
APPLIED_AFTER="$(metrics_drive applied "$METRICS_AFTER")"
DECODE_ERR_AFTER="$(metrics_drive decode_error "$METRICS_AFTER")"

DISPATCHED_DELTA=$(( DISPATCHED_AFTER - DISPATCHED_BEFORE ))
APPLIED_DELTA=$(( APPLIED_AFTER - APPLIED_BEFORE ))
DECODE_ERR_DELTA=$(( DECODE_ERR_AFTER - DECODE_ERR_BEFORE ))
echo "kind-val: drive metrics delta — dispatched=+$DISPATCHED_DELTA applied=+$APPLIED_DELTA decode_error=+$DECODE_ERR_DELTA"

# ----------------------------------------------------------------------
# Count __orchestrate__ rows in the event log (must be 0) and the command
# queue (must be > 0) for this execution.
# ----------------------------------------------------------------------

count_rows() {
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'
}

ORCH_EVENT_ROWS="$(count_rows \
  "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $EXECUTION_ID AND node_name = '__orchestrate__'")"
ORCH_COMMAND_ROWS="$(count_rows \
  "SELECT COUNT(*) AS n FROM noetl.command WHERE execution_id = $EXECUTION_ID AND step_name = '__orchestrate__'")"
echo "kind-val: __orchestrate__ rows — noetl.event=$ORCH_EVENT_ROWS noetl.command=$ORCH_COMMAND_ROWS"

# ----------------------------------------------------------------------
# Assertions.
# ----------------------------------------------------------------------

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

# 1. Final status COMPLETED.
[[ "$FINAL_STATUS" == "COMPLETED" ]] \
  || fail "expected final status COMPLETED, got $FINAL_STATUS"

# 2. ZERO __orchestrate__ rows in noetl.event (the off-server topology's
#    scale-critical property — no event-log burst from the meta-command).
[[ "$ORCH_EVENT_ROWS" == "0" ]] \
  || fail "expected 0 __orchestrate__ rows in noetl.event, got $ORCH_EVENT_ROWS (event-log burst — drive not suppressing)"

# 3. __orchestrate__ commands EXIST (the drive was dispatched off-server).
[[ "${ORCH_COMMAND_ROWS:-0}" -ge 1 ]] \
  || fail "expected >=1 __orchestrate__ rows in noetl.command (off-server dispatch), got $ORCH_COMMAND_ROWS — is the drive ON? (NOETL_ORCHESTRATE_PLUGIN_DRIVE / pre-#108 image)"

# 4. The drive ran off-server: dispatched advanced AND applied advanced AND no
#    decode errors. `applied` advancing means the server applied a result the
#    WORKER computed — proof the evaluate ran on the pool, not in-process.
[[ "$DISPATCHED_DELTA" -ge 1 ]] \
  || fail "noetl_orchestrate_drive_total{stage=dispatched} did not advance (+$DISPATCHED_DELTA)"
[[ "$APPLIED_DELTA" -ge 1 ]] \
  || fail "noetl_orchestrate_drive_total{stage=applied} did not advance (+$APPLIED_DELTA) — server never applied a worker-computed result"
[[ "$DECODE_ERR_DELTA" -eq 0 ]] \
  || fail "noetl_orchestrate_drive_total{stage=decode_error} advanced (+$DECODE_ERR_DELTA) — worker results failed to decode"

# 5. Shadow metric retired (#110). Its presence means a pre-#110 image.
[[ "$SHADOW_PRESENT" == "no" ]] \
  || fail "noetl_orchestrate_shadow_total present on /metrics — server is a pre-#110 image (shadow not retired)"

# 6. (informational) system-pool isolation — which pool ran the meta-step.
echo
echo "kind-val: --- system-pool isolation (informational) ---"
SYS_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=400 2>/dev/null \
  | grep -c -E "orchestrate|__orchestrate__|run_state" || true)"
USER_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_WORKER_DEPLOY" --tail=400 2>/dev/null \
  | grep -c -E "__orchestrate__" || true)"
echo "kind-val: system-pool worker orchestrate log hits=$SYS_HITS ; default-pool __orchestrate__ hits=$USER_HITS"
if [[ "${USER_HITS:-0}" -gt 0 ]]; then
  echo "kind-val: NOTE — default (user) pool logged __orchestrate__ activity; expected the system pool to own the drive." >&2
fi

# ----------------------------------------------------------------------
# Report.
# ----------------------------------------------------------------------

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — worker-driven orchestrate topology green"
  echo "  - final_status=COMPLETED"
  echo "  - __orchestrate__ in noetl.event = 0 (no event-log burst)"
  echo "  - __orchestrate__ in noetl.command = $ORCH_COMMAND_ROWS (off-server dispatch)"
  echo "  - drive metric: dispatched +$DISPATCHED_DELTA / applied +$APPLIED_DELTA / decode_error +$DECODE_ERR_DELTA"
  echo "  - noetl_orchestrate_shadow_total absent (#110 retirement confirmed)"
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo
echo "kind-val: system-pool worker logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
echo
echo "kind-val: default-pool worker logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_WORKER_DEPLOY" --tail=80 || true
exit 1
