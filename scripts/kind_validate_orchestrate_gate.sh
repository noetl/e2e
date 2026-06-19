#!/usr/bin/env bash
# kind_validate_orchestrate_gate.sh — the off-server drive UNDER the CQRS
# PUBLISH_ONLY gate (noetl/ai-meta#104 reconciliation; closes the last
# combination left unproven by noetl/ai-meta#103).
#
# Where `kind_validate_orchestrate_offserver.sh` proves the orchestrator drive
# runs off-server (gate-off), this rig proves the drive composes with the CQRS
# write-path gate: server `NOETL_EVENT_INGEST_PUBLISH_ONLY=true` (the server is
# no longer a `noetl.event` writer — every event is PUBLISHED to the
# `noetl_events` JetStream stream) AND `NOETL_ORCHESTRATE_PLUGIN_DRIVE=true` (the
# evaluate loop runs on the system worker pool). The materializer worker loop
# (`NOETL_MATERIALIZER_ENABLED=true`) is the sole `noetl.event` writer.
#
# #103 was only ever validated gate-on with the IN-PROCESS drive
# (`NOETL_ORCHESTRATE_PLUGIN_DRIVE=false`), because the off-server drive's state
# rebuild reads `noetl.event` — empty until the materializer projects it. This
# rig proves the two compose: the relocated trigger fires from the materializer's
# write endpoint AFTER the row lands, so the server rebuilds `WorkflowState` from
# committed state (read-your-writes) before bounding the off-server drive input.
#
# Assertions (all required for PASS):
#
#   1. Final execution status is COMPLETED — the off-server drive carried the run
#      to terminal under the gate, with read-your-writes consistency.
#   2. Server PUBLISHED this run's events instead of inserting them:
#      `noetl_event_ingest_published_total` advanced by >= the run's event count.
#      (The gate is doing its job — the chokepoint published, did not INSERT.)
#   3. Sole-writer, no-loss, no-double-write: the count of `noetl.event` rows for
#      this execution equals the number of DISTINCT event_ids (every published
#      event materialized exactly once — the materializer is the only writer and
#      the deferred ack lost nothing).
#   4. ZERO events with `catalog_id = 0` — the get_catalog_id `noetl.command`
#      fallback under the gate works (noetl/ai-meta#103 fix server#236); a 0 here
#      means the FK-violation drop path is back.
#   5. ZERO `__orchestrate__` rows in `noetl.event`; `__orchestrate__` rows EXIST
#      in `noetl.command` — the off-server topology holds under the gate.
#   6. Drive metric: `dispatched` and `applied` both advanced; `decode_error` and
#      `cold_rebuild_failed` did NOT — the server scheduled the drive and applied
#      a worker-computed result with no decode/recovery failure.
#   7. The materializer loop reported `duplicates=0` across the run window — no
#      double-write reached `events/project`.
#
# Preconditions:
#   - server: a v3.29.1+ image (the chokepoint + gate + get_catalog_id fallback)
#     with NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: a v5.34.0+ worker with NOETL_MATERIALIZER_ENABLED=true.
#   - a CLEAN cluster (purge `noetl_events`, truncate execution-state tables) so
#     the published-count delta is attributable. The rig snapshots metrics before
#     the run, but a flooded stream starves the fresh execution.
#
# Usage:
#   ./scripts/kind_validate_orchestrate_gate.sh
#   ./scripts/kind_validate_orchestrate_gate.sh --context kind-noetl
#
# Exits 0 if PASS; 1 if any hard assertion fails (dumps server + system-pool
# logs); 2 on a precondition error.

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
echo "kind-val: server=$NOETL_SERVER_URL (gate-on + off-server drive)"
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

# Precondition: the gate must actually be ON, else this rig is just the
# gate-off offserver rig in disguise.
GATE_ON="$("${KCTX[@]}" get deploy "$NOETL_SERVER_DEPLOY" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="NOETL_EVENT_INGEST_PUBLISH_ONLY")]}{.value}{end}' 2>/dev/null || true)"
DRIVE_ON="$("${KCTX[@]}" get deploy "$NOETL_SERVER_DEPLOY" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="NOETL_ORCHESTRATE_PLUGIN_DRIVE")]}{.value}{end}' 2>/dev/null || true)"
MAT_ON="$("${KCTX[@]}" get deploy "$NOETL_SYSTEM_POOL_DEPLOY" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="NOETL_MATERIALIZER_ENABLED")]}{.value}{end}' 2>/dev/null || true)"
echo "kind-val: env — PUBLISH_ONLY=$GATE_ON PLUGIN_DRIVE=$DRIVE_ON MATERIALIZER_ENABLED=$MAT_ON"
[[ "$GATE_ON" == "true" ]] \
  || { echo "kind-val: NOETL_EVENT_INGEST_PUBLISH_ONLY is not 'true' on the server — this rig requires the gate ON." >&2; exit 2; }
[[ "$DRIVE_ON" != "false" ]] \
  || { echo "kind-val: NOETL_ORCHESTRATE_PLUGIN_DRIVE=false — this rig requires the OFF-SERVER drive." >&2; exit 2; }
[[ "$MAT_ON" == "true" ]] \
  || { echo "kind-val: NOETL_MATERIALIZER_ENABLED is not 'true' on the system pool — no sole writer." >&2; exit 2; }

# ----------------------------------------------------------------------
# Metric helpers (mirrors kind_validate_orchestrate_offserver.sh).
# ----------------------------------------------------------------------

fetch_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

metrics_drive() {  # stage body -> int
  printf '%s' "$2" | python3 -c '
import re, sys
stage = sys.argv[1]; total = 0
for line in sys.stdin:
    m = re.match(r"noetl_orchestrate_drive_total\{stage=\"([^\"]+)\"\}\s+([0-9.]+)", line)
    if m and m.group(1) == stage:
        total += int(float(m.group(2)))
print(total)
' "$1"
}

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

# ----------------------------------------------------------------------
# Snapshot BEFORE.
# ----------------------------------------------------------------------

MB="$(fetch_metrics)"
DISPATCHED_BEFORE="$(metrics_drive dispatched "$MB")"
APPLIED_BEFORE="$(metrics_drive applied "$MB")"
DECODE_ERR_BEFORE="$(metrics_drive decode_error "$MB")"
COLD_FAIL_BEFORE="$(metrics_drive cold_rebuild_failed "$MB")"
PUBLISHED_BEFORE="$(metrics_published_sum "$MB")"
echo "kind-val: before — dispatched=$DISPATCHED_BEFORE applied=$APPLIED_BEFORE decode_error=$DECODE_ERR_BEFORE cold_rebuild_failed=$COLD_FAIL_BEFORE published=$PUBLISHED_BEFORE"

# ----------------------------------------------------------------------
# Register + execute (drives several rounds with a concurrent fan-out).
# ----------------------------------------------------------------------

echo
echo "================================================================"
echo "kind-val: register + execute fanout_reduce_phase6 (gate-on, off-server drive)"
echo "================================================================"

noetl register playbook --file "$FIXTURE_PATH"
EXECUTION_ID="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
echo "kind-val: launched execution_id=$EXECUTION_ID"

DEADLINE=$(( SECONDS + TIMEOUT_SECS ))
FINAL_STATUS=""
while [[ $SECONDS -lt $DEADLINE ]]; do
  FINAL_STATUS="$(noetl status "$EXECUTION_ID" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
  case "$FINAL_STATUS" in COMPLETED|FAILED) break ;; esac
  sleep 2
done
echo "kind-val: execution_id=$EXECUTION_ID final_status=$FINAL_STATUS"

# Let the materializer flush the terminal events + the apply metric increment.
sleep 4
MA="$(fetch_metrics)"
DISPATCHED_DELTA=$(( $(metrics_drive dispatched "$MA") - DISPATCHED_BEFORE ))
APPLIED_DELTA=$(( $(metrics_drive applied "$MA") - APPLIED_BEFORE ))
DECODE_ERR_DELTA=$(( $(metrics_drive decode_error "$MA") - DECODE_ERR_BEFORE ))
COLD_FAIL_DELTA=$(( $(metrics_drive cold_rebuild_failed "$MA") - COLD_FAIL_BEFORE ))
PUBLISHED_DELTA=$(( $(metrics_published_sum "$MA") - PUBLISHED_BEFORE ))
echo "kind-val: delta — dispatched=+$DISPATCHED_DELTA applied=+$APPLIED_DELTA decode_error=+$DECODE_ERR_DELTA cold_rebuild_failed=+$COLD_FAIL_DELTA published=+$PUBLISHED_DELTA"

# ----------------------------------------------------------------------
# DB facts for this execution.
# ----------------------------------------------------------------------

EVENT_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $EXECUTION_ID")"
DISTINCT_IDS="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $EXECUTION_ID")"
CATALOG_ZERO="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $EXECUTION_ID AND catalog_id = 0")"
ORCH_EVENT_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $EXECUTION_ID AND node_name = '__orchestrate__'")"
ORCH_COMMAND_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.command WHERE execution_id = $EXECUTION_ID AND step_name = '__orchestrate__'")"
echo "kind-val: db — event_rows=$EVENT_ROWS distinct_ids=$DISTINCT_IDS catalog_zero=$CATALOG_ZERO orch_event=$ORCH_EVENT_ROWS orch_command=$ORCH_COMMAND_ROWS"

MAT_DUP_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=600 2>/dev/null \
  | grep -c -E "materializer cycle.*duplicates=[1-9]" || true)"
echo "kind-val: materializer cycles reporting duplicates>0 = $MAT_DUP_HITS (want 0)"

# ----------------------------------------------------------------------
# Assertions.
# ----------------------------------------------------------------------

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

# 1.
[[ "$FINAL_STATUS" == "COMPLETED" ]] \
  || fail "expected final status COMPLETED, got $FINAL_STATUS"

# 2. Gate is publishing, not inserting.
[[ "$PUBLISHED_DELTA" -ge "$EVENT_ROWS" && "$EVENT_ROWS" -gt 0 ]] \
  || fail "published delta (+$PUBLISHED_DELTA) < materialized rows ($EVENT_ROWS) — the gate is not publishing this run's events"

# 3. Sole-writer, no loss, no double-write.
[[ "$EVENT_ROWS" -gt 0 && "$EVENT_ROWS" == "$DISTINCT_IDS" ]] \
  || fail "noetl.event rows ($EVENT_ROWS) != distinct event_ids ($DISTINCT_IDS) — double-write or loss"

# 4. catalog_id fallback.
[[ "$CATALOG_ZERO" == "0" ]] \
  || fail "$CATALOG_ZERO events with catalog_id=0 — get_catalog_id command-fallback regressed (FK drop path)"

# 5. Off-server topology under the gate.
[[ "$ORCH_EVENT_ROWS" == "0" ]] \
  || fail "expected 0 __orchestrate__ rows in noetl.event, got $ORCH_EVENT_ROWS"
[[ "${ORCH_COMMAND_ROWS:-0}" -ge 1 ]] \
  || fail "expected >=1 __orchestrate__ rows in noetl.command (off-server dispatch), got $ORCH_COMMAND_ROWS"

# 6. Drive ran off-server, applied cleanly.
[[ "$DISPATCHED_DELTA" -ge 1 ]] || fail "drive dispatched did not advance (+$DISPATCHED_DELTA)"
[[ "$APPLIED_DELTA" -ge 1 ]]    || fail "drive applied did not advance (+$APPLIED_DELTA)"
[[ "$DECODE_ERR_DELTA" -eq 0 ]] || fail "drive decode_error advanced (+$DECODE_ERR_DELTA)"
[[ "$COLD_FAIL_DELTA" -eq 0 ]]  || fail "drive cold_rebuild_failed advanced (+$COLD_FAIL_DELTA)"

# 7. No double-write at the materializer.
[[ "${MAT_DUP_HITS:-0}" -eq 0 ]] \
  || fail "materializer reported duplicates>0 in $MAT_DUP_HITS cycle(s) — double-write reached events/project"

# ----------------------------------------------------------------------
# Report.
# ----------------------------------------------------------------------

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — off-server drive × PUBLISH_ONLY gate compose green"
  echo "  - final_status=COMPLETED (read-your-writes held)"
  echo "  - server PUBLISHED +$PUBLISHED_DELTA events (>= $EVENT_ROWS materialized) — not inserted"
  echo "  - materializer sole writer: $EVENT_ROWS rows == $DISTINCT_IDS distinct ids (no loss / no dup)"
  echo "  - catalog_id=0 rows: $CATALOG_ZERO ; materializer duplicate cycles: $MAT_DUP_HITS"
  echo "  - __orchestrate__ event=0 / command=$ORCH_COMMAND_ROWS (off-server under gate)"
  echo "  - drive: dispatched +$DISPATCHED_DELTA / applied +$APPLIED_DELTA / decode_error +$DECODE_ERR_DELTA / cold_rebuild_failed +$COLD_FAIL_DELTA"
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: system-pool logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
exit 1
