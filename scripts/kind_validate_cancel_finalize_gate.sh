#!/usr/bin/env bash
# kind_validate_cancel_finalize_gate.sh — the ExecutionService cancel + finalize
# endpoints UNDER the CQRS write-path chokepoint (noetl/ai-meta#103 2d-3, the
# final flip blocker).
#
# The 2d-3 cutover routed the 13 server-originated event producers through the
# `emit_event` chokepoint, but the two ExecutionService terminal writers —
# `POST /api/executions/{id}/cancel` (writes `playbook_cancelled`) and
# `POST /api/executions/{id}/finalize` (writes `playbook_completed` /
# `playbook_failed`) — were staged because they lacked `AppState`. This rig
# proves they now honour `NOETL_EVENT_INGEST_PUBLISH_ONLY` like every other
# producer: gate-off they INSERT synchronously (byte-identical columns); gate-on
# they PUBLISH to `noetl_events` and the materializer is the sole `noetl.event`
# writer — no terminal event stranded.
#
# DUAL MODE — the rig auto-detects the server's gate from its deployment env and
# runs the matching assertions:
#
#   gate-OFF (NOETL_EVENT_INGEST_PUBLISH_ONLY != "true"):
#     - cancel/finalize rows appear in noetl.event SYNCHRONOUSLY (server is the
#       writer); `noetl_event_ingest_published_total` does NOT advance (nothing
#       is published).
#     - column byte-identity: node_id == node_name == 'playbook'; the finalize
#       FAILED row carries the exact `error` string.
#
#   gate-ON (NOETL_EVENT_INGEST_PUBLISH_ONLY == "true", materializer on):
#     - `noetl_event_ingest_published_total` advances across the cancel +
#       finalize writes — the chokepoint published, did not INSERT.
#     - the `playbook_cancelled` / `playbook_failed` rows still land in
#       noetl.event (materialized by the system pool, the sole writer) — no loss.
#     - the execution reaches the correct TERMINAL state (CANCELLED / FAILED) —
#       the relocated trigger drove it from the materialized row.
#     - no double-write: per-execution noetl.event rows == distinct event_ids;
#       zero catalog_id=0 rows (the get_catalog_id / resolve_catalog_id command
#       fallback held — noetl.event is empty under the gate for a fresh exec).
#
# Preconditions (gate-ON):
#   - server: a v3.29.3+ image (cancel/finalize routed through the chokepoint)
#     with NOETL_EVENT_INGEST_PUBLISH_ONLY=true.
#   - system pool: a v5.34.0+ worker with NOETL_MATERIALIZER_ENABLED=true.
#   - a CLEAN cluster (purge `noetl_events`, no stuck execs flooding the stream)
#     so the published-count delta is attributable.
#
# Usage:
#   ./scripts/kind_validate_cancel_finalize_gate.sh
#   ./scripts/kind_validate_cancel_finalize_gate.sh --context kind-noetl
#
# Exits 0 if PASS; 1 if any hard assertion fails (dumps server + system-pool
# logs); 2 on a precondition error.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-180}"
FINALIZE_ERROR="kind-val forced finalize (noetl/ai-meta#103 2d-3)"

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

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE server=$NOETL_SERVER_URL"
echo "kind-val: fixture=$FIXTURE_PATH"

# ----------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "kind-val: required command not in PATH: $cmd" >&2
    exit 2
  }
done

for sub in "register playbook" "exec" "status" "query"; do
  if ! noetl $sub --help >/dev/null 2>&1; then
    echo "kind-val: this rig needs the current noetl CLI surface (missing: noetl $sub)" >&2
    exit 2
  fi
done

[[ -f "$FIXTURE_PATH" ]] || { echo "kind-val: fixture not found: $FIXTURE_PATH" >&2; exit 2; }

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

"${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1 \
  || { echo "kind-val: $NOETL_SERVER_DEPLOY not found in $NAMESPACE." >&2; exit 2; }
curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1 \
  || { echo "kind-val: server not reachable at $NOETL_SERVER_URL — start a port-forward." >&2; exit 2; }

# Detect the gate from the server deployment env — drives which assertions run.
GATE_ON="$("${KCTX[@]}" get deploy "$NOETL_SERVER_DEPLOY" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="NOETL_EVENT_INGEST_PUBLISH_ONLY")]}{.value}{end}' 2>/dev/null || true)"
MAT_ON="$("${KCTX[@]}" get deploy "$NOETL_SYSTEM_POOL_DEPLOY" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="NOETL_MATERIALIZER_ENABLED")]}{.value}{end}' 2>/dev/null || true)"

MODE="gate-off"
[[ "$GATE_ON" == "true" ]] && MODE="gate-on"
echo "kind-val: env — PUBLISH_ONLY=$GATE_ON MATERIALIZER_ENABLED=$MAT_ON → MODE=$MODE"

if [[ "$MODE" == "gate-on" ]]; then
  [[ "$MAT_ON" == "true" ]] \
    || { echo "kind-val: gate ON but NOETL_MATERIALIZER_ENABLED is not 'true' on the system pool — no sole writer." >&2; exit 2; }
fi

# ----------------------------------------------------------------------
# Helpers (mirror kind_validate_orchestrate_gate.sh).
# ----------------------------------------------------------------------

fetch_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

metrics_published_sum() {  # body -> int (sum across all event_type labels)
  printf '%s' "$1" | python3 -c '
import re, sys; total = 0
for line in sys.stdin:
    m = re.match(r"noetl_event_ingest_published_total\{.*\}\s+([0-9.]+)", line)
    if m: total += int(float(m.group(1)))
print(total)
'
}

count_rows() {  # sql -> first row "n" column
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'
}

str_field() {  # sql -> first row "v" column (string), empty if none
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("v", "") if d else "")'
}

launch_running_exec() {  # -> prints execution_id; waits until it has progressed
  local eid
  eid="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  # Wait until the execution is actually moving (a command exists), so the
  # cancel/finalize lands on a live RUNNING execution, not a not-yet-dispatched
  # one.  noetl.command is synchronous in both modes, so this is gate-agnostic.
  local d=$(( SECONDS + 40 ))
  while [[ $SECONDS -lt $d ]]; do
    local cmds
    cmds="$(count_rows "SELECT COUNT(*) AS n FROM noetl.command WHERE execution_id = $eid")"
    [[ "${cmds:-0}" -ge 1 ]] && break
    sleep 1
  done
  printf '%s' "$eid"
}

wait_for_status() {  # execution_id wanted -> 0 if reached, prints final
  local eid="$1" wanted="$2" final="" d=$(( SECONDS + TIMEOUT_SECS ))
  while [[ $SECONDS -lt $d ]]; do
    final="$(noetl status "$eid" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
    [[ "$final" == "$wanted" ]] && { printf '%s' "$final"; return 0; }
    # Terminal-but-wrong also stops the wait (e.g. natural COMPLETED beat us).
    case "$final" in COMPLETED|FAILED|CANCELLED) printf '%s' "$final"; return 1 ;; esac
    sleep 2
  done
  printf '%s' "$final"; return 1
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

# ----------------------------------------------------------------------
# Sub-test 1: CANCEL under the gate.
# ----------------------------------------------------------------------

echo
echo "================================================================"
echo "kind-val: [1/2] cancel under $MODE"
echo "================================================================"

noetl register playbook --file "$FIXTURE_PATH" >/dev/null

PUB_BEFORE_CANCEL="$(metrics_published_sum "$(fetch_metrics)")"
CANCEL_EID="$(launch_running_exec)"
echo "kind-val: cancel target execution_id=$CANCEL_EID (published_before=$PUB_BEFORE_CANCEL)"

curl -fsS -X POST "$NOETL_SERVER_URL/api/executions/$CANCEL_EID/cancel" >/dev/null \
  || fail "POST /cancel returned non-2xx for $CANCEL_EID"

CANCEL_FINAL="$(wait_for_status "$CANCEL_EID" CANCELLED || true)"
echo "kind-val: cancel final_status=$CANCEL_FINAL"
sleep 4  # let the materializer flush under the gate

PUB_AFTER_CANCEL="$(metrics_published_sum "$(fetch_metrics)")"
CANCEL_PUB_DELTA=$(( PUB_AFTER_CANCEL - PUB_BEFORE_CANCEL ))

CANCEL_EVENT_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $CANCEL_EID AND event_type IN ('playbook_cancelled','playbook.cancelled')")"
CANCEL_NODE_OK="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $CANCEL_EID AND event_type IN ('playbook_cancelled','playbook.cancelled') AND node_id = 'playbook' AND node_name = 'playbook' AND status = 'CANCELLED'")"
echo "kind-val: cancel — published_delta=+$CANCEL_PUB_DELTA cancelled_rows=$CANCEL_EVENT_ROWS node_id/name_ok=$CANCEL_NODE_OK final=$CANCEL_FINAL"

# Common assertions (both modes): the cancellation event landed with the right
# columns and the execution is CANCELLED.
[[ "$CANCEL_EVENT_ROWS" -ge 1 ]] \
  || fail "no playbook_cancelled row in noetl.event for $CANCEL_EID — cancel event stranded/lost"
[[ "$CANCEL_NODE_OK" -ge 1 ]] \
  || fail "playbook_cancelled row columns not byte-identical (node_id/node_name='playbook', status='CANCELLED')"
[[ "$CANCEL_FINAL" == "CANCELLED" ]] \
  || fail "execution $CANCEL_EID did not reach CANCELLED (got '$CANCEL_FINAL')"

# ----------------------------------------------------------------------
# Sub-test 2: FINALIZE (FAILED, with an error string) under the gate.
# ----------------------------------------------------------------------

echo
echo "================================================================"
echo "kind-val: [2/2] finalize FAILED under $MODE"
echo "================================================================"

PUB_BEFORE_FIN="$(metrics_published_sum "$(fetch_metrics)")"
FIN_EID="$(launch_running_exec)"
echo "kind-val: finalize target execution_id=$FIN_EID (published_before=$PUB_BEFORE_FIN)"

curl -fsS -X POST "$NOETL_SERVER_URL/api/executions/$FIN_EID/finalize" \
  -H 'Content-Type: application/json' \
  -d "{\"status\":\"FAILED\",\"error\":\"$FINALIZE_ERROR\"}" >/dev/null \
  || fail "POST /finalize returned non-2xx for $FIN_EID"

FIN_FINAL="$(wait_for_status "$FIN_EID" FAILED || true)"
echo "kind-val: finalize final_status=$FIN_FINAL"
sleep 4  # let the materializer flush under the gate

PUB_AFTER_FIN="$(metrics_published_sum "$(fetch_metrics)")"
FIN_PUB_DELTA=$(( PUB_AFTER_FIN - PUB_BEFORE_FIN ))

FIN_EVENT_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $FIN_EID AND event_type IN ('playbook_failed','playbook.failed')")"
FIN_ERR="$(str_field "SELECT error AS v FROM noetl.event WHERE execution_id = $FIN_EID AND event_type IN ('playbook_failed','playbook.failed') LIMIT 1")"
FIN_NODE_OK="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $FIN_EID AND event_type IN ('playbook_failed','playbook.failed') AND node_id = 'playbook' AND node_name = 'playbook' AND status = 'FAILED'")"
echo "kind-val: finalize — published_delta=+$FIN_PUB_DELTA failed_rows=$FIN_EVENT_ROWS node_ok=$FIN_NODE_OK error='$FIN_ERR' final=$FIN_FINAL"

[[ "$FIN_EVENT_ROWS" -ge 1 ]] \
  || fail "no playbook_failed row in noetl.event for $FIN_EID — finalize event stranded/lost"
[[ "$FIN_NODE_OK" -ge 1 ]] \
  || fail "playbook_failed row columns not byte-identical (node_id/node_name='playbook', status='FAILED')"
[[ "$FIN_ERR" == "$FINALIZE_ERROR" ]] \
  || fail "finalize error column not preserved: got '$FIN_ERR' want '$FINALIZE_ERROR'"
[[ "$FIN_FINAL" == "FAILED" ]] \
  || fail "execution $FIN_EID did not reach FAILED (got '$FIN_FINAL')"

# ----------------------------------------------------------------------
# Mode-specific assertions: publish-vs-insert + sole-writer integrity.
# ----------------------------------------------------------------------

echo
echo "kind-val: mode-specific assertions ($MODE)"

for eid in "$CANCEL_EID" "$FIN_EID"; do
  ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  DISTINCT="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  CZERO="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND catalog_id = 0")"
  echo "kind-val: exec $eid — rows=$ROWS distinct_ids=$DISTINCT catalog_zero=$CZERO"
  [[ "$ROWS" -gt 0 && "$ROWS" == "$DISTINCT" ]] \
    || fail "exec $eid: noetl.event rows ($ROWS) != distinct ids ($DISTINCT) — double-write or loss"
  [[ "$CZERO" == "0" ]] \
    || fail "exec $eid: $CZERO events with catalog_id=0 — resolve_catalog_id command fallback regressed"
done

TOTAL_PUB_DELTA=$(( CANCEL_PUB_DELTA + FIN_PUB_DELTA ))
if [[ "$MODE" == "gate-on" ]]; then
  # The chokepoint published these (and every other) event; the cancel +
  # finalize terminal writes are included in the delta.
  [[ "$TOTAL_PUB_DELTA" -ge 2 ]] \
    || fail "gate-on: published delta (+$TOTAL_PUB_DELTA) < 2 — cancel/finalize not published through the chokepoint"
  echo "kind-val: gate-on — cancel+finalize PUBLISHED (delta +$TOTAL_PUB_DELTA), materialized by the system pool (sole writer)"
else
  # Gate-off: nothing is ever published — the chokepoint INSERTs synchronously.
  [[ "$TOTAL_PUB_DELTA" -eq 0 ]] \
    || fail "gate-off: published delta advanced (+$TOTAL_PUB_DELTA) — expected synchronous INSERT, nothing published"
  echo "kind-val: gate-off — cancel+finalize INSERTed synchronously (published delta +0), columns byte-identical"
fi

# ----------------------------------------------------------------------
# Report.
# ----------------------------------------------------------------------

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — ExecutionService cancel + finalize honour the gate ($MODE)"
  echo "  - cancel  → CANCELLED, playbook_cancelled row (node_id/name='playbook')"
  echo "  - finalize→ FAILED,    playbook_failed row (error preserved)"
  if [[ "$MODE" == "gate-on" ]]; then
    echo "  - PUBLISHED through the chokepoint (delta +$TOTAL_PUB_DELTA); materializer sole writer; no loss/dup; 0 catalog_id=0"
  else
    echo "  - INSERTed synchronously (published +0); byte-identical columns; no loss/dup"
  fi
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: system-pool logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
exit 1
