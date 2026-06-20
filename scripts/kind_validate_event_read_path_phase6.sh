#!/usr/bin/env bash
# kind_validate_event_read_path_phase6.sh — the END-TO-END never-scan invariant
# under the Phase-6 audit-only event read path (noetl/ai-meta#115 Phase 6).
#
# Phase 4 removed the *drive*'s WorkflowState rebuild + noetl.event scan under
# NOETL_STATE_BUILDER=offserver (proven by kind_validate_state_builder_offserver).
# Phase 6 retires the REMAINING execution-lifecycle readers of noetl.event — the
# `WHERE execution_id = $1` replay class that runs OUTSIDE the drive:
#   - get_catalog_id (normalize_event_to_row — fires on EVERY event ingest),
#   - inherit_parent_trace (child/sub-playbook executions),
#   - the subscription dedup-audit catalog lookup,
#   - the container-callback existence + catalog reads.
# Under NOETL_EVENT_READ_PATH=audit_only each is served from the in-memory
# execute-time ExecDescriptor (catalog_id + routing seeded at playbook_started),
# so noetl.event becomes AUDIT-ONLY: still written by the materializer (#103),
# still read by operator/status/replay APIs — never scanned by the lifecycle.
#
# This rig proves, across linear / loop / fan-out topologies, gate-ON
# (PUBLISH_ONLY + off-server drive + materializer sole-writer) + audit_only:
#
#   1. NEVER-SCAN (ingest/callback/execute path) — the server's
#      noetl_event_hotpath_reads_total{outcome="scan"} delta is 0 across the
#      whole lifecycle (every hot-path event read was served from the
#      descriptor), while {outcome="served_descriptor"} advanced (the path was
#      exercised — the proof isn't vacuous).
#   2. NEVER-SCAN (drive path) — noetl_state_build_total delta 0 AND
#      noetl_state_build_event_scans_total delta 0 (Phase-4 stateless edge).
#      (1)+(2) == ZERO noetl.event scans anywhere on the hot path, end-to-end.
#   3. COMPLETE — every topology reaches COMPLETED (read-path correctness held).
#   4. SOLE-WRITER + lag-0 + bounded — per-exec event_rows==distinct_ids,
#      catalog_id=0 rows=0, __orchestrate__ event rows=0, materializer dup=0.
#   5. AUDIT STILL WORKS — noetl.event is audit-only, NOT gone: a direct
#      SELECT FROM noetl.event returns the run's rows, the status API returns
#      COMPLETED, and the replay API returns the event log.  Operators/tools
#      read the table; the hot path doesn't.
#
# The rig flips NOETL_EVENT_READ_PATH=audit_only (server) + NOETL_STATE_BUILDER=
# offserver (server + system pool) for its run and RESTORES the prior values on
# exit (trap), so it does not disturb other sessions' baseline.
#
# Preconditions (the same gate-ON stack the offserver rig needs), PLUS a server
# image carrying the Phase-6 flag (NOETL_EVENT_READ_PATH + the
# noetl_event_hotpath_reads_total metric):
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND
#     NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: NOETL_MATERIALIZER_ENABLED=true.
#   - a CLEAN cluster (purge noetl_events, truncate execution-state tables) — so
#     stray descriptor-cold reads from leftover executions don't add scans.
#
# Usage:
#   ./scripts/kind_validate_event_read_path_phase6.sh
#   ./scripts/kind_validate_event_read_path_phase6.sh --context kind-noetl
#   ./scripts/kind_validate_event_read_path_phase6.sh --no-restore   # leave audit_only on
#
# Exits 0 if PASS; 1 if any hard assertion fails (dumps logs); 2 on precondition.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-180}"
RESTORE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
    --no-restore) RESTORE=0; shift ;;
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

# Topologies — (fixture file : catalog path).  Linear, loop, fan-out cover the
# straight-line, loop-variable, and fan-in-barrier drive shapes.
FIX_LINEAR="$REPO_ROOT/fixtures/playbooks/simple_python.yaml:test/simple_python"
FIX_LOOP="$REPO_ROOT/fixtures/playbooks/loop_test.yaml:test/loop"
FIX_FANOUT="$REPO_ROOT/fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml:tests/fixtures/fanout_reduce_phase6"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: server=$NOETL_SERVER_URL (gate-ON + offserver + audit_only event read path)"

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done
for f in "$FIX_LINEAR" "$FIX_LOOP" "$FIX_FANOUT"; do
  [[ -f "${f%%:*}" ]] || { echo "kind-val: fixture not found: ${f%%:*}" >&2; exit 2; }
done

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

"${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1 \
  || { echo "kind-val: $NOETL_SERVER_DEPLOY not found in $NAMESPACE." >&2; exit 2; }
curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1 \
  || { echo "kind-val: server not reachable at $NOETL_SERVER_URL — start a port-forward." >&2; exit 2; }

get_env() {  # deploy name -> value (empty if unset)
  "${KCTX[@]}" get deploy "$1" \
    -o jsonpath="{range .spec.template.spec.containers[0].env[?(@.name==\"$2\")]}{.value}{end}" 2>/dev/null || true
}

GATE_ON="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_EVENT_INGEST_PUBLISH_ONLY)"
DRIVE_ON="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_ORCHESTRATE_PLUGIN_DRIVE)"
MAT_ON="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_MATERIALIZER_ENABLED)"
echo "kind-val: env — PUBLISH_ONLY=$GATE_ON PLUGIN_DRIVE=$DRIVE_ON MATERIALIZER_ENABLED=$MAT_ON"
[[ "$GATE_ON" == "true" ]] || { echo "kind-val: PUBLISH_ONLY not true — this rig requires the gate ON." >&2; exit 2; }
[[ "$DRIVE_ON" != "false" ]] || { echo "kind-val: PLUGIN_DRIVE=false — this rig requires the off-server drive." >&2; exit 2; }
[[ "$MAT_ON" == "true" ]] || { echo "kind-val: MATERIALIZER_ENABLED not true — no sole writer." >&2; exit 2; }

# Record originals + restore on exit.
ORIG_ERP="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_EVENT_READ_PATH)"
ORIG_SB="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_STATE_BUILDER)"
ORIG_SB_SRV="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_STATE_BUILDER)"
ORIG_SM="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_STATE_BUILD_MODE)"
cleanup() {
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline (EVENT_READ_PATH=${ORIG_ERP:-event_scan}, STATE_BUILDER pool=${ORIG_SB:-server}/server=${ORIG_SB_SRV:-server}, STATE_BUILD_MODE=${ORIG_SM:-event_scan})"
    "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" "NOETL_STATE_BUILDER=${ORIG_SB:-server}" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
      "NOETL_EVENT_READ_PATH=${ORIG_ERP:-event_scan}" \
      "NOETL_STATE_BUILDER=${ORIG_SB_SRV:-server}" \
      "NOETL_STATE_BUILD_MODE=${ORIG_SM:-event_scan}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "kind-val: setting NOETL_EVENT_READ_PATH=audit_only + NOETL_STATE_BUILDER=offserver (server + system pool) + NOETL_STATE_BUILD_MODE=chain_walk (server fallback)"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_STATE_BUILDER=offserver >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
  NOETL_EVENT_READ_PATH=audit_only \
  NOETL_STATE_BUILDER=offserver \
  NOETL_STATE_BUILD_MODE=chain_walk >/dev/null
"${KCTX[@]}" rollout status deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --timeout=120s >/dev/null
"${KCTX[@]}" rollout status deploy/"$NOETL_SERVER_DEPLOY" --timeout=120s >/dev/null
hdl=$(( SECONDS + 60 ))
until curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1; do
  [[ $SECONDS -lt $hdl ]] || { echo "kind-val: server health not ready after rollout" >&2; break; }
  sleep 2
done
sleep 8  # let the authoritative WAL drain warm its index off the retained stream

# ----------------------------------------------------------------------
# Metric + DB helpers.
# ----------------------------------------------------------------------
fetch_server_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

metric_label() {  # body metric label_value -> int (sum of matching {…="value"…} samples)
  printf '%s' "$1" | python3 -c '
import re, sys
metric, lab = sys.argv[1], sys.argv[2]; total = 0
pat = re.compile(r"^%s\{[^}]*\b\w+=\"%s\"[^}]*\}\s+([0-9.]+)" % (re.escape(metric), re.escape(lab)))
for line in sys.stdin:
    m = pat.match(line)
    if m: total += int(float(m.group(1)))
print(total)
' "$2" "$3"
}

metric_simple() {  # body metric -> int (sum across all label sets / bare)
  printf '%s' "$1" | python3 -c '
import re, sys; metric = sys.argv[1]; total = 0
pat = re.compile(r"^%s(\{[^}]*\})?\s+([0-9.]+)" % re.escape(metric))
for line in sys.stdin:
    m = pat.match(line)
    if m: total += int(float(m.group(2)))
print(total)
' "$2"
}

count_rows() {
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'
}

# Runs one execution leg.  Sets globals LEG_EID + LEG_STATUS.
run_leg() {  # fixture_file catalog_path label
  noetl register playbook --file "$1" >/dev/null
  LEG_EID="$(noetl exec "$2" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: $3 leg launched execution_id=$LEG_EID"
  local deadline=$(( SECONDS + TIMEOUT_SECS ))
  LEG_STATUS=""
  while [[ $SECONDS -lt $deadline ]]; do
    LEG_STATUS="$(noetl status "$LEG_EID" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
    case "$LEG_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 2
  done
  sleep 4  # let the materializer flush terminal events
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

assert_sole_writer() {  # execution_id label
  local eid="$1" lbl="$2"
  local rows distinct cat0 orch_ev
  rows="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  distinct="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  cat0="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND catalog_id = 0")"
  orch_ev="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND node_name = '__orchestrate__'")"
  echo "kind-val: $lbl db — event_rows=$rows distinct=$distinct catalog0=$cat0 orch_event=$orch_ev"
  [[ "$rows" -gt 0 && "$rows" == "$distinct" ]] || fail "$lbl event rows ($rows) != distinct ids ($distinct) — double-write/loss"
  [[ "$cat0" == "0" ]] || fail "$lbl $cat0 events with catalog_id=0"
  [[ "$orch_ev" == "0" ]] || fail "$lbl expected 0 __orchestrate__ event rows, got $orch_ev"
  LAST_ROWS="$rows"
}

# ======================================================================
# Run the three topologies under audit_only, measuring the hot-path read
# deltas across the WHOLE batch.
# ======================================================================
SM_BEFORE="$(fetch_server_metrics)"
HP_SCAN_BEFORE="$(metric_label "$SM_BEFORE" noetl_event_hotpath_reads_total scan)"
HP_DESC_BEFORE="$(metric_label "$SM_BEFORE" noetl_event_hotpath_reads_total served_descriptor)"
SB_BUILD_BEFORE="$(metric_simple "$SM_BEFORE" noetl_state_build_total)"
SB_SCAN_BEFORE="$(metric_simple "$SM_BEFORE" noetl_state_build_event_scans_total)"

echo
echo "================================================================"
echo "kind-val: LEG 1 — linear (simple_python)"
echo "================================================================"
run_leg "${FIX_LINEAR%%:*}" "${FIX_LINEAR##*:}" linear
LIN_EID="$LEG_EID"; LIN_STATUS="$LEG_STATUS"
[[ "$LIN_STATUS" == "COMPLETED" ]] || fail "linear leg did not COMPLETE (got $LIN_STATUS)"
assert_sole_writer "$LIN_EID" linear

echo
echo "================================================================"
echo "kind-val: LEG 2 — loop (loop_test)"
echo "================================================================"
run_leg "${FIX_LOOP%%:*}" "${FIX_LOOP##*:}" loop
LOOP_EID="$LEG_EID"; LOOP_STATUS="$LEG_STATUS"
[[ "$LOOP_STATUS" == "COMPLETED" ]] || fail "loop leg did not COMPLETE (got $LOOP_STATUS)"
assert_sole_writer "$LOOP_EID" loop

echo
echo "================================================================"
echo "kind-val: LEG 3 — fan-out + reduce (fanout_reduce_phase6)"
echo "================================================================"
run_leg "${FIX_FANOUT%%:*}" "${FIX_FANOUT##*:}" fanout
FO_EID="$LEG_EID"; FO_STATUS="$LEG_STATUS"
[[ "$FO_STATUS" == "COMPLETED" ]] || fail "fan-out leg did not COMPLETE (got $FO_STATUS)"
assert_sole_writer "$FO_EID" fanout

# ======================================================================
# Hot-path read deltas across the batch.
# ======================================================================
SM_AFTER="$(fetch_server_metrics)"
HP_SCAN_D=$(( $(metric_label "$SM_AFTER" noetl_event_hotpath_reads_total scan) - HP_SCAN_BEFORE ))
HP_DESC_D=$(( $(metric_label "$SM_AFTER" noetl_event_hotpath_reads_total served_descriptor) - HP_DESC_BEFORE ))
SB_BUILD_D=$(( $(metric_simple "$SM_AFTER" noetl_state_build_total) - SB_BUILD_BEFORE ))
SB_SCAN_D=$(( $(metric_simple "$SM_AFTER" noetl_state_build_event_scans_total) - SB_SCAN_BEFORE ))
echo
echo "kind-val: hot-path reads — served_descriptor=+$HP_DESC_D scan=+$HP_SCAN_D (want scan 0, descriptor >=1)"
echo "kind-val: drive path — state_build_total=+$SB_BUILD_D state_build_event_scans=+$SB_SCAN_D (want both 0)"

# ======================================================================
# AUDIT STILL WORKS — noetl.event is audit-only, not gone.
# ======================================================================
echo
echo "kind-val: audit check — noetl.event readable by operator/status/replay APIs"
AUDIT_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $FO_EID")"
AUDIT_STATUS="$(noetl status "$FO_EID" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
REPLAY_N="$(curl -fsS "$NOETL_SERVER_URL/api/executions/$FO_EID/replay" 2>/dev/null \
  | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
ev=d.get("events", d if isinstance(d, list) else [])
print(len(ev) if isinstance(ev, list) else 0)' || echo 0)"
echo "kind-val: audit — direct noetl.event rows=$AUDIT_ROWS, status API=$AUDIT_STATUS, replay events=$REPLAY_N"

# ======================================================================
# Materializer duplicates (sole-writer health) over the whole batch.
# ======================================================================
MAT_DUP_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=1200 2>/dev/null | grep -c -E "materializer cycle.*duplicates=[1-9]" || true)"

# ======================================================================
# Assertions.
# ======================================================================
# 1. NEVER-SCAN on the ingest/callback/execute path.
[[ "$HP_SCAN_D" -eq 0 ]] || fail "hot-path event SCANS advanced (+$HP_SCAN_D) — a lifecycle reader scanned noetl.event instead of the descriptor"
[[ "$HP_DESC_D" -ge 1 ]] || fail "hot-path descriptor reads did not advance (+$HP_DESC_D) — the audit_only path was not exercised (vacuous proof)"
# 2. NEVER-SCAN on the drive path (Phase-4 stateless edge).
[[ "$SB_BUILD_D" -eq 0 ]] || fail "drive state_build_total advanced (+$SB_BUILD_D) — the drive rebuilt WorkflowState (not a stateless edge)"
[[ "$SB_SCAN_D" -eq 0 ]]  || fail "drive state_build_event_scans advanced (+$SB_SCAN_D) — the drive scanned noetl.event"
# 5. AUDIT STILL WORKS.
[[ "$AUDIT_ROWS" -gt 0 ]]        || fail "noetl.event has 0 rows for $FO_EID — audit log empty (the table must stay audit-readable)"
[[ "$AUDIT_STATUS" == "COMPLETED" ]] || fail "status API did not return COMPLETED for $FO_EID (got $AUDIT_STATUS)"
[[ "$REPLAY_N" -ge 1 ]]         || fail "replay API returned 0 events for $FO_EID — replay against noetl.event broken"
# 4. sole-writer health (per-leg asserted above) — materializer dup over batch.
[[ "${MAT_DUP_HITS:-0}" -eq 0 ]] || fail "materializer reported duplicates>0 in $MAT_DUP_HITS cycle(s)"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — END-TO-END never-scan invariant under audit_only + offserver"
  echo "  1. ingest/callback/execute path scan-free: hotpath scan +$HP_SCAN_D (served_descriptor +$HP_DESC_D)"
  echo "  2. drive path scan-free: state_build_total +$SB_BUILD_D, state_build_event_scans +$SB_SCAN_D"
  echo "     => ZERO noetl.event scans anywhere on the hot path, end-to-end"
  echo "  3. COMPLETE: linear/loop/fanout all COMPLETED"
  echo "  4. sole-writer + lag-0 + bounded (per leg), materializer dup=$MAT_DUP_HITS"
  echo "  5. AUDIT STILL WORKS: noetl.event rows=$AUDIT_ROWS, status=$AUDIT_STATUS, replay events=$REPLAY_N"
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: system-pool logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
exit 1
